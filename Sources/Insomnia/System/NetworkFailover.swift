import Foundation
import Network
import Security

// MARK: - Pure state machine (spec section 7)

/// Drives hotspot failover from three events. No clocks, no timers, no I/O:
/// the driver owns those and feeds `Date`s in.
struct FailoverMachine: Sendable, Equatable {
    enum Output: Sendable, Equatable {
        case joinHotspot
        case scheduleRetry(after: TimeInterval)
        case recovered(start: Date, gap: TimeInterval)
    }

    /// Seconds the path must stay unsatisfied before the first join.
    static let initialDelay: TimeInterval = 5
    /// Delays after each join attempt: 5, 10, 20, 30, 30, 30, ...
    static let backoff: [TimeInterval] = [5, 10, 20, 30]

    private(set) var outageStart: Date?
    private(set) var joins: Int = 0
    private(set) var nextAttemptAt: Date?

    var inOutage: Bool { outageStart != nil }

    static func delay(afterJoin n: Int) -> TimeInterval {
        backoff[min(max(n - 1, 0), backoff.count - 1)]
    }

    mutating func pathUnsatisfied(at now: Date) -> [Output] {
        guard outageStart == nil else { return [] }
        outageStart = now
        joins = 0
        nextAttemptAt = now.addingTimeInterval(Self.initialDelay)
        return [.scheduleRetry(after: Self.initialDelay)]
    }

    mutating func pathSatisfied(at now: Date) -> [Output] {
        guard let start = outageStart else { return [] }
        outageStart = nil
        joins = 0
        nextAttemptAt = nil
        return [.recovered(start: start, gap: max(0, now.timeIntervalSince(start)))]
    }

    mutating func timerFired(at now: Date) -> [Output] {
        guard outageStart != nil, let due = nextAttemptAt, now >= due else { return [] }
        joins += 1
        let delay = Self.delay(afterJoin: joins)
        nextAttemptAt = now.addingTimeInterval(delay)
        return [.joinHotspot, .scheduleRetry(after: delay)]
    }

    /// One handoffs.log line per outage.
    static func logLine(start: Date, end: Date, gap: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        return "\(f.string(from: end)) outage start=\(f.string(from: start)) end=\(f.string(from: end)) gap=\(Int(gap.rounded()))s"
    }

    /// "2m 10s", "45s", "1h 2m 3s".
    static func humanGap(_ gap: TimeInterval) -> String {
        let total = Int(gap.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }
}

// MARK: - networksetup parsing

enum HardwarePortsParser {
    /// Device name of the Wi-Fi port in `networksetup -listallhardwareports`
    /// output, e.g. "en0".
    static func wifiInterface(from output: String) -> String? {
        var currentIsWifi = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let name = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
                currentIsWifi = name == "Wi-Fi" || name == "AirPort" || name.lowercased().contains("wi-fi")
            } else if line.hasPrefix("Device:"), currentIsWifi {
                let dev = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { return dev }
            }
        }
        return nil
    }

    /// SSID from `networksetup -getairportnetwork en0`
    /// ("Current Wi-Fi Network: Foo"), nil when not associated.
    static func ssid(fromGetAirportNetwork output: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(of: "Current Wi-Fi Network:") else { return nil }
        let ssid = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return ssid.isEmpty ? nil : ssid
    }
}

// MARK: - Keychain

protocol KeychainStoring: Sendable {
    func get(service: String, account: String) throws -> String?
    func set(service: String, account: String, value: String) throws
}

struct KeychainError: Error, LocalizedError, Sendable {
    let status: OSStatus
    var errorDescription: String? {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain: \(msg)"
    }
}

/// Login keychain generic password, service `insomnia-hotspot`, account = SSID.
struct KeychainStore: KeychainStoring {
    static let service = "insomnia-hotspot"

    func get(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func set(service: String, account: String, value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

final class FakeKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func get(service: String, account: String) throws -> String? { lock.withLock { items["\(service)/\(account)"] } }
    func set(service: String, account: String, value: String) throws { lock.withLock { items["\(service)/\(account)"] = value } }
}

// MARK: - Driver

/// NWPathMonitor on Wi-Fi, one retry timer that exists only during an
/// outage, `networksetup` for the join, handoffs.log, tmux nudge and a
/// notification on recovery. Active only while a session is active.
@MainActor
final class NetworkFailover {
    static let networksetup = "/usr/sbin/networksetup"

    /// Called after every recovery with the gap length.
    var onRecovered: ((TimeInterval) -> Void)?

    private(set) var machine = FailoverMachine()
    private(set) var wifiInterface: String?
    private(set) var lastGap: TimeInterval?

    private let paths: Paths
    private let keychain: any KeychainStoring
    private let nudge: TmuxNudge
    private let notifier: any Notifying
    private let configProvider: @MainActor () -> Config
    private let clock: @Sendable () -> Date

    private var monitor: NWPathMonitor?
    private var retryTimer: Timer?
    private var generation = 0

    init(
        paths: Paths,
        keychain: any KeychainStoring = KeychainStore(),
        nudge: TmuxNudge = TmuxNudge(),
        notifier: any Notifying,
        clock: @escaping @Sendable () -> Date = { Date() },
        config: @escaping @MainActor () -> Config
    ) {
        self.paths = paths
        self.keychain = keychain
        self.nudge = nudge
        self.notifier = notifier
        self.clock = clock
        self.configProvider = config
    }

    func start() async {
        guard monitor == nil else { return }
        await resolveInterface()
        guard !Task.isCancelled else { return }
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        m.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.handlePath(satisfied: satisfied) }
        }
        m.start(queue: .main)
        monitor = m
        Log.info("network failover started (wifi \(wifiInterface ?? "unresolved"))")
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        cancelTimer()
        machine = FailoverMachine()
    }

    /// Current SSID via `networksetup -getairportnetwork`; nil when unknown.
    func currentSSID() async -> String? {
        if wifiInterface == nil { await resolveInterface() }
        guard let iface = wifiInterface else { return nil }
        do {
            let r = try await Shell.run(Self.networksetup, ["-getairportnetwork", iface], timeout: 5)
            return HardwarePortsParser.ssid(fromGetAirportNetwork: r.stdout)
        } catch {
            Log.error("getairportnetwork failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Private

    private func resolveInterface() async {
        guard wifiInterface == nil else { return }
        do {
            let r = try await Shell.run(Self.networksetup, ["-listallhardwareports"], timeout: 5)
            wifiInterface = HardwarePortsParser.wifiInterface(from: r.stdout)
            if wifiInterface == nil {
                Log.error("could not find a Wi-Fi port in networksetup -listallhardwareports")
            } else {
                Log.info("wifi interface \(wifiInterface!)")
            }
        } catch {
            Log.error("listallhardwareports failed: \(error.localizedDescription)")
        }
    }

    private func handlePath(satisfied: Bool) {
        Task { await process(satisfied: satisfied) }
    }

    /// Feed one path update through the machine and apply its outputs.
    /// Public so tests can drive the driver without an NWPathMonitor.
    func simulate(satisfied: Bool) async {
        await process(satisfied: satisfied)
    }

    private func process(satisfied: Bool) async {
        let now = clock()
        let outputs = satisfied ? machine.pathSatisfied(at: now) : machine.pathUnsatisfied(at: now)
        if outputs.isEmpty { return }
        if !satisfied { Log.info("wifi path unsatisfied") }
        await apply(outputs)
    }

    private func fireTimer() {
        retryTimer = nil
        let outputs = machine.timerFired(at: clock())
        Task { await apply(outputs) }
    }

    private func apply(_ outputs: [FailoverMachine.Output]) async {
        for o in outputs {
            switch o {
            case let .scheduleRetry(after):
                schedule(after: after)
            case .joinHotspot:
                await joinHotspot()
            case let .recovered(start, gap):
                cancelTimer()
                await recovered(start: start, gap: gap)
            }
        }
    }

    private func schedule(after: TimeInterval) {
        cancelTimer()
        generation += 1
        let gen = generation
        let t = Timer(timeInterval: after, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.fireTimer()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    private func cancelTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
        generation += 1
    }

    private func joinHotspot() async {
        let config = configProvider()
        let ssid = config.hotspotSSID.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty else {
            Log.info("hotspot join skipped: no hotspotSSID configured")
            return
        }
        guard let iface = wifiInterface else {
            Log.error("hotspot join skipped: no Wi-Fi interface")
            return
        }
        let password: String
        do {
            guard let p = try keychain.get(service: KeychainStore.service, account: ssid) else {
                Log.error("hotspot join skipped: no Keychain item \(KeychainStore.service)/\(ssid)")
                return
            }
            password = p
        } catch {
            Log.error("hotspot join skipped: \(error.localizedDescription)")
            return
        }
        Log.info("joining hotspot \(ssid) on \(iface) (attempt \(machine.joins))")
        do {
            let r = try await Shell.run(Self.networksetup, ["-setairportnetwork", iface, ssid, password], timeout: 30)
            let msg = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !r.succeeded || msg.lowercased().contains("error") || msg.lowercased().contains("failed") {
                Log.error("setairportnetwork: \(msg.isEmpty ? "status \(r.status)" : msg)")
            }
        } catch {
            Log.error("setairportnetwork failed: \(error.localizedDescription)")
        }
    }

    private func recovered(start: Date, gap: TimeInterval) async {
        let end = clock()
        lastGap = gap
        let line = FailoverMachine.logLine(start: start, end: end, gap: gap)
        appendHandoff(line)
        Log.info("wifi path satisfied after \(FailoverMachine.humanGap(gap))")
        let config = configProvider()
        if gap >= config.nudgeThreshold {
            let count = await nudge.nudge(targets: config.tmuxTargets)
            let panes = count == 1 ? "1 tmux pane" : "\(count) tmux panes"
            notifier.post(
                title: "Network recovered",
                body: "Network was down \(FailoverMachine.humanGap(gap)). Nudged \(panes). Check GUI agents."
            )
        }
        onRecovered?(gap)
    }

    private func appendHandoff(_ line: String) {
        do {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let url = paths.handoffsLog
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            Log.error("handoffs.log append failed: \(error.localizedDescription)")
        }
    }
}
