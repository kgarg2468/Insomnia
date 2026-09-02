import Foundation
import Observation

/// Everything the menu shows about the machine. Updated by AppServices on
/// each OS event; `refreshOnDemand()` fills the on-demand fields (watts,
/// SSID, browser flags) when the popover opens.
@MainActor
@Observable
final class SystemStatus {
    var lidClosed: Bool = false
    var batteryPercent: Int?
    var isCharging: Bool = false
    /// Signed watts (negative while discharging); only set by refreshOnDemand.
    var watts: Double?
    var thermalState: ProcessInfo.ThermalState = .nominal
    var wifiSSID: String?
    /// Length of the last Wi-Fi outage this session, in seconds.
    var lastGap: TimeInterval?
    var frozenCount: Int = 0
    var dockerPaused: Bool = false
    /// Display names of running Chromium browsers missing the two flags.
    var throttledBrowsers: [String] = []
    /// Full detail for the relaunch item (bundle id + name).
    var browsers: [BrowserStatus] = []

    @ObservationIgnored var refresher: (@MainActor () async -> Void)?

    /// Fire-and-forget refresh of watts, SSID, battery and browser flags.
    func refreshOnDemand() {
        guard let refresher else { return }
        Task { @MainActor in await refresher() }
    }
}

/// Owns and wires every system integration to the SessionManager.
/// Constructed by `SessionManager.live()`; started when a session starts (or
/// is found valid at reconcile) and stopped when it ends.
@MainActor
final class AppServices {
    let status = SystemStatus()
    let notifier: any Notifying

    private let paths: Paths
    private let audio: any AudioControlling
    private let freezer: any Freezing
    private let docker: DockerRule
    private let keychain: any KeychainStoring
    private let lid = LidObserver()
    private let power = PowerMonitor()
    private let browser: BrowserThrottle

    private weak var manager: SessionManager?
    private var lidActions: LidActions?
    private var floors: FloorRuleDriver?
    private var network: NetworkFailover?
    private var networkTask: Task<Void, Never>?
    private var lidTask: Task<Void, Never>?
    private var floorTask: Task<Void, Never>?
    private(set) var running = false

    init(
        paths: Paths,
        notifier: any Notifying,
        audio: any AudioControlling,
        processControl: any ProcessSignaling,
        keychain: any KeychainStoring = KeychainStore()
    ) {
        self.paths = paths
        self.notifier = notifier
        self.audio = audio
        self.freezer = Freezer(control: processControl)
        self.docker = DockerRule(freezer: freezer)
        self.keychain = keychain
        self.browser = BrowserThrottle()
        status.refresher = { [weak self] in await self?.refreshOnDemand() }
    }

    /// Called by SessionManager once a session is active.
    func start(for manager: SessionManager) {
        guard !running else { return }
        running = true
        self.manager = manager
        let config = manager.config
        status.lastGap = nil

        (notifier as? Notifier)?.requestAuthorizationIfNeeded()
        AppNap.disable(for: config.agentList)

        lidActions = LidActions(manager: manager, freezer: freezer, docker: docker, audio: audio)
        floors = FloorRuleDriver(manager: manager, notifier: notifier)

        lid.onChange = { [weak self] closed in self?.lidChanged(closed) }
        lid.start()
        status.lidClosed = lid.isClosed

        power.onChange = { [weak self] in self?.powerChanged() }
        power.start()
        syncPower()
        // Apply the floors once: the battery may already be below one.
        powerChanged()

        let net = NetworkFailover(paths: paths, keychain: keychain, notifier: notifier) { [weak manager] in
            manager?.config ?? Config()
        }
        net.onRecovered = { [weak self] gap in self?.status.lastGap = gap }
        network = net
        networkTask = Task { [weak self, weak net] in
            guard let self, let net else { return }
            await net.start()
            if Task.isCancelled || !self.running || self.network !== net {
                net.stop()
            }
        }

        Task { await self.refreshBrowsers() }
        syncState()
    }

    func stop() {
        guard running else { return }
        running = false
        lid.stop()
        lid.onChange = nil
        power.stop()
        power.onChange = nil
        networkTask?.cancel()
        networkTask = nil
        network?.stop()
        network = nil
        lidActions = nil
        floors = nil
        syncState()
    }

    /// One-shot launch diagnostics. This does not start any observer or retry
    /// timer, so system integrations remain active only during a session.
    func logStartupSnapshot() {
        if let closed = LidObserver.readClamshellState() {
            status.lidClosed = closed
            Log.info("startup lid state \(closed ? "closed" : "open")")
        } else {
            Log.info("startup lid state unavailable")
        }

        power.refreshBattery()
        syncPower()
        Log.info("startup battery percent \(status.batteryPercent.map(String.init) ?? "unavailable")")
        Log.info("startup thermal state \(PowerMonitor.name(status.thermalState))")

        Task { [weak self] in
            guard let self else { return }
            self.status.wifiSSID = await self.currentSSID()
        }
    }

    /// Watts + SSID + battery + browser flags; the popover calls this.
    func refreshOnDemand() async {
        status.watts = instantWatts()
        power.refreshBattery()
        syncPower()
        if let now = LidObserver.readClamshellState() { status.lidClosed = now }
        status.wifiSSID = await currentSSID()
        await refreshBrowsers()
        syncState()
    }

    /// Instant battery power, read only when requested by the UI.
    func instantWatts() -> Double? {
        power.instantWatts()
    }

    /// Quit and relaunch a Chromium browser with both anti-throttle flags.
    func relaunchUnthrottled(_ bundleId: String) async {
        await browser.relaunchUnthrottled(bundleId: bundleId)
        try? await Task.sleep(for: .seconds(2))
        await refreshBrowsers()
    }

    // MARK: Private

    private func lidChanged(_ closed: Bool) {
        status.lidClosed = closed
        guard let actions = lidActions else { return }
        let previous = lidTask
        lidTask = Task { @MainActor in
            await previous?.value
            if closed { await actions.onClose() } else { await actions.onOpen() }
            self.syncState()
        }
    }

    private func powerChanged() {
        syncPower()
        guard let floors else { return }
        let percent = power.percent
        let charging = power.isCharging
        let thermal = power.thermalState
        let previous = floorTask
        floorTask = Task { @MainActor in
            await previous?.value
            await floors.run(percent: percent, isCharging: charging, thermal: thermal)
            self.syncState()
        }
    }

    private func syncPower() {
        status.batteryPercent = power.percent
        status.isCharging = power.isCharging
        status.thermalState = power.thermalState
    }

    private func syncState() {
        let s = manager?.state ?? .clean
        status.frozenCount = s.frozenPids.count
        status.dockerPaused = s.dockerFrozen
    }

    private func refreshBrowsers() async {
        let config = manager?.config ?? Config()
        let statuses = await browser.scan(config: config)
        status.browsers = statuses
        status.throttledBrowsers = browser.throttledBrowsers
    }

    private func currentSSID() async -> String? {
        if let network { return await network.currentSSID() }
        let probe = NetworkFailover(paths: paths, keychain: keychain, notifier: notifier) { Config() }
        return await probe.currentSSID()
    }
}
