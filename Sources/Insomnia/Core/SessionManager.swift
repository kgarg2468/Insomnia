import Foundation
import Observation

enum EndReason: String, Sendable {
    case timer
    case user
    case quit
    case batteryFloor
    case thermalCritical
    case backstop
}

/// Owns the session lifecycle: start / extend / end / reconcile.
///
/// Journal-first: every mutation is written to session.json / state.json
/// *before* the matching side effect, and undo always reads state.json from
/// disk, never memory (spec section 8 invariants).
@MainActor
@Observable
final class SessionManager {
    private(set) var session: Session?
    private(set) var state: RuntimeState
    var config: Config
    /// Minute-granularity remaining time for the popover ("2h 14m").
    private(set) var remainingText: String = ""
    /// Live `H:MM:SS` countdown for the status item, updated at 1 Hz.
    private(set) var countdownText: String = ""
    /// Last failure worth showing in the menu; cleared on the next success.
    private(set) var lastError: String?

    var isActive: Bool { session != nil }

    /// Fire date of the single deadline timer, exposed for tests and the menu.
    private(set) var scheduledDeadline: Date?

    let store: Store
    let paths: Paths
    private let sleepGuard: any SleepGuarding
    private let processControl: any ProcessSignaling
    private let backstop: any BackstopScheduling
    private let audio: any AudioControlling
    private let notifier: any Notifying
    private let clamshell: @Sendable () -> Bool?
    private let clock: @Sendable () -> Date

    /// System integrations (lid, battery, network, ...). Set by `live()`;
    /// nil in tests. Started after a session starts, stopped when it ends.
    @ObservationIgnored var services: AppServices?

    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var countdownPaused = false

    init(
        paths: Paths,
        sleepGuard: any SleepGuarding,
        processControl: any ProcessSignaling,
        backstop: any BackstopScheduling,
        audio: any AudioControlling = NoopAudioControl(),
        notifier: any Notifying = RecordingNotifier(),
        clamshell: @escaping @Sendable () -> Bool? = { LidObserver.readClamshellState() },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.sleepGuard = sleepGuard
        self.processControl = processControl
        self.backstop = backstop
        self.audio = audio
        self.notifier = notifier
        self.clamshell = clamshell
        self.clock = clock

        try? paths.createDirectories()
        let loadedState = (try? store.loadState()) ?? nil
        self.state = loadedState ?? .clean
        if let c = (try? store.loadConfig()) ?? nil {
            self.config = c
        } else {
            self.config = Config()
            try? store.saveConfig(self.config)
        }
    }

    /// Production wiring.
    static func live(paths: Paths = .fromEnvironment()) -> SessionManager {
        let notifier = Notifier()
        let audio = CoreAudioControl()
        let processControl = SignalProcessControl()
        let m = SessionManager(
            paths: paths,
            sleepGuard: PmsetSleepGuard(),
            processControl: processControl,
            backstop: LaunchdBackstop(paths: paths),
            audio: audio,
            notifier: notifier
        )
        let services = AppServices(paths: paths, notifier: notifier, audio: audio, processControl: processControl)
        m.services = services
        services.logStartupSnapshot()
        return m
    }

    // MARK: Start / extend / end

    /// Start a session of `duration` seconds (clamped to `config.maxDuration`).
    /// Ignored if a session is already active; use `extend`.
    ///
    /// Ordering: session.json, then state.json, then `pmset disablesleep 1`.
    /// If pmset fails the journal is rolled back so nothing is left on disk.
    func start(duration: TimeInterval) async {
        guard session == nil else {
            Log.info("start ignored: session already active")
            return
        }
        let now = clock()
        let new = SessionMath.newSession(now: now, duration: duration, maxDuration: config.maxDuration)

        do {
            try store.saveSession(new)
            var s = state
            s.sleepDisabledByUs = true
            try persistState(s)
        } catch {
            fail("could not write session: \(error.localizedDescription)")
            try? store.deleteSession()
            return
        }

        // The backstop is armed before sleep is disabled, so a crash at any
        // later point already has a launchd job waiting at the deadline.
        // RunAtLoad fires backstop.sh immediately; the session on disk is
        // valid, so that run is a no-op.
        do {
            try await backstop.schedule(endsAt: new.endsAt)
        } catch {
            rollBackStart()
            fail("could not arm backstop: \(error.localizedDescription)")
            return
        }

        do {
            try await sleepGuard.setSleepDisabled(true)
        } catch {
            // Roll back the journal: no session may exist if sleep is not disabled.
            rollBackStart()
            try? await backstop.clear()
            fail("could not disable sleep: \(error.localizedDescription)")
            return
        }

        session = new
        lastError = nil
        Log.info("session started until \(iso(new.endsAt)) (\(Int(duration))s requested)")
        await armDeadline(new.endsAt)
        // App Nap defaults and every observer live in AppServices.
        services?.start(for: self)
        // PR3: schedule "5 minutes left" notification.
    }

    func extend(by extra: TimeInterval) async {
        guard let current = session else { return }
        let updated = SessionMath.extended(current, by: extra, now: clock(), maxDuration: config.maxDuration)
        // Move the backstop first; if launchd rejects it the old deadline stays.
        do {
            try await backstop.schedule(endsAt: updated.endsAt)
        } catch {
            fail("could not move backstop: \(error.localizedDescription)")
            return
        }
        do {
            try store.saveSession(updated)
        } catch {
            fail("could not write session: \(error.localizedDescription)")
            return
        }
        session = updated
        lastError = nil
        Log.info("session extended by \(Int(extra))s until \(iso(updated.endsAt))")
        await armDeadline(updated.endsAt)
    }

    /// Full session end: delete the session file first (so a crash here leaves
    /// a clean "no session" for reconcile/backstop), then undo RuntimeState
    /// from disk, then clear the backstop trigger.
    func end(reason: EndReason) async {
        let had = session != nil
        Log.info("session end (\(reason.rawValue))")
        stopTimers()
        session = nil
        scheduledDeadline = nil
        remainingText = ""
        countdownText = ""
        do {
            try store.deleteSession()
        } catch {
            Log.error("could not delete session.json: \(error.localizedDescription)")
        }
        await restoreAll()
        do {
            try await backstop.clear()
        } catch {
            Log.error("backstop clear failed: \(error.localizedDescription)")
        }
        // App Nap defaults are intentionally left set (spec: open decisions).
        services?.stop()
        notifier.post(title: Self.endTitle(reason, had: had), body: endBody(reason))
    }

    // MARK: Journal hooks for LidActions / FloorRules

    /// Persist a state mutation (journal first) and keep the in-memory copy
    /// in sync. Throws if state.json cannot be written; callers must then
    /// skip the side effect.
    func journal(_ mutate: (inout RuntimeState) -> Void) throws {
        var s = state
        mutate(&s)
        try persistState(s)
    }

    /// Low Power Mode with journaling: the flag is written before `pmset -b
    /// lowpowermode 1` and cleared only after `... 0` succeeds. Returns true
    /// when the mode was actually changed.
    @discardableResult
    func setLowPower(_ on: Bool) async -> Bool {
        if on {
            guard !state.lowPowerSetByUs else { return false }
            do {
                try journal { $0.lowPowerSetByUs = true }
            } catch {
                Log.error("could not journal low power mode: \(error.localizedDescription)")
                return false
            }
            do {
                try await sleepGuard.setLowPowerMode(true)
                Log.info("low power mode on")
                return true
            } catch {
                Log.error("could not enable low power mode: \(error.localizedDescription)")
                try? journal { $0.lowPowerSetByUs = false }
                return false
            }
        } else {
            guard state.lowPowerSetByUs else { return false }
            do {
                try await sleepGuard.setLowPowerMode(false)
                try? journal { $0.lowPowerSetByUs = false }
                Log.info("low power mode off")
                return true
            } catch {
                Log.error("could not disable low power mode: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Undo every lid-close action recorded on disk: resume frozen pids,
    /// clear the Docker marker, restore volume and mute. Used by lid open,
    /// reconcile (lid open) and the full restore.
    func undoLidActions() async {
        var s: RuntimeState
        do {
            s = try store.loadState() ?? .clean
        } catch {
            Log.error("state.json unreadable (\(error.localizedDescription)); assuming in-memory state")
            s = state
        }
        undoLidActions(in: &s)
        state = s
    }

    // MARK: Restore

    /// Undo every RuntimeState entry, reading state.json from disk. Each undo
    /// is persisted as soon as it succeeds so a crash mid-way loses nothing.
    /// Failures are logged and the entry is left set so the next reconcile or
    /// the backstop retries it.
    func restoreAll() async {
        var s: RuntimeState
        do {
            s = try store.loadState() ?? .clean
        } catch {
            Log.error("state.json unreadable (\(error.localizedDescription)); assuming in-memory state")
            s = state
        }

        if s.sleepDisabledByUs {
            do {
                try await sleepGuard.setSleepDisabled(false)
                s.sleepDisabledByUs = false
                try? persistState(s)
                Log.info("sleep restored")
            } catch {
                Log.error("could not restore sleep: \(error.localizedDescription)")
                lastError = "could not restore sleep: \(error.localizedDescription)"
            }
        }

        if s.lowPowerSetByUs {
            do {
                try await sleepGuard.setLowPowerMode(false)
                s.lowPowerSetByUs = false
                try? persistState(s)
                Log.info("low power mode cleared")
            } catch {
                Log.error("could not clear low power mode: \(error.localizedDescription)")
            }
        }

        undoLidActions(in: &s)
        state = s
    }

    /// Shared body of `undoLidActions()` and `restoreAll()`; each entry is
    /// persisted as soon as it is undone.
    private func undoLidActions(in s: inout RuntimeState) {
        if !s.frozenPids.isEmpty {
            processControl.resume(pids: s.frozenPids)
            Log.info("resumed \(s.frozenPids.count) frozen pid(s)")
            s.frozenPids = []
            // Docker Desktop is frozen via its pids too; the flag is only a marker.
            s.dockerFrozen = false
            try? persistState(s)
        } else if s.dockerFrozen {
            s.dockerFrozen = false
            try? persistState(s)
        }

        if s.savedOutputVolume != nil || s.savedMuted != nil {
            do {
                let current = try audio.read()
                try audio.apply(volume: s.savedOutputVolume ?? current.volume, muted: s.savedMuted ?? current.muted)
                Log.info("audio restored (volume \(s.savedOutputVolume ?? current.volume), muted \(s.savedMuted ?? current.muted))")
                s.savedOutputVolume = nil
                s.savedMuted = nil
                try? persistState(s)
            } catch {
                Log.error("could not restore audio: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Reconcile (spec section 8)

    func reconcile() async {
        let now = clock()
        var onDisk: Session?
        do {
            onDisk = try store.loadSession()
        } catch {
            Log.error("session.json unreadable (\(error.localizedDescription)); treating as expired")
            onDisk = nil
        }

        if let s = onDisk, !s.isExpired(at: now) {
            // Step 2: valid session. Re-apply disablesleep (idempotent), rearm timers.
            session = s
            var st = state
            if !st.sleepDisabledByUs {
                st.sleepDisabledByUs = true
                try? persistState(st)
            }
            do {
                try await sleepGuard.setSleepDisabled(true)
                lastError = nil
            } catch {
                fail("could not re-apply sleep guard: \(error.localizedDescription)")
            }
            Log.info("reconcile: session valid until \(iso(s.endsAt))")
            do {
                try await backstop.schedule(endsAt: s.endsAt)
            } catch {
                fail("could not re-arm backstop: \(error.localizedDescription)")
            }
            // Lid-close actions still on disk are undone only if the lid is
            // open now. Closed (or unknown): they are already journaled and
            // will be undone on the next lid open or at session end.
            let lidClosed = clamshell()
            if lidClosed == false {
                undoLidActions(in: &st)
                state = st
            } else if st.frozenPids.isEmpty == false || st.savedOutputVolume != nil {
                Log.info("reconcile: lid \(lidClosed == nil ? "unknown" : "closed"), keeping lid-close actions")
            }
            await armDeadline(s.endsAt)
            services?.start(for: self)
            return
        }

        // Step 1: missing or expired -> full end.
        if onDisk != nil {
            Log.info("reconcile: session expired, restoring")
            await end(reason: .timer)
        } else if state.isDirty {
            Log.info("reconcile: no session but dirty state, restoring")
            await end(reason: .backstop)
        } else {
            Log.info("reconcile: no session, nothing to restore")
        }

        // Step 3: SleepDisabled set with no session -> clear it.
        do {
            if try await sleepGuard.isSleepDisabled() {
                Log.info("reconcile: pmset reports SleepDisabled with no session, clearing")
                try await sleepGuard.setSleepDisabled(false)
            }
        } catch {
            Log.error("reconcile: sleep check failed: \(error.localizedDescription)")
        }
    }

    // MARK: Countdown (1 Hz redraw)

    /// Stop the countdown redraw. The lid observer calls this on lid close,
    /// which is what keeps a 1 Hz timer from costing battery in the bag.
    func pauseCountdown() {
        countdownPaused = true
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Restart the countdown redraw. The lid observer calls this on lid open.
    func resumeCountdown() {
        countdownPaused = false
        refreshCountdown()
        armCountdownTimer()
    }

    /// Recompute `remainingText` and `countdownText` from the injected clock.
    /// Each is only assigned when it changes, so observers are not woken every
    /// second for the minute-granularity text.
    func refreshCountdown() {
        guard let s = session else {
            remainingText = ""
            countdownText = ""
            return
        }
        let remaining = s.remaining(at: clock())
        let minute = SessionMath.formatRemaining(remaining)
        if remainingText != minute { remainingText = minute }
        let second = SessionMath.formatCountdown(remaining: remaining, shape: s.countdownShape)
        if countdownText != second { countdownText = second }
    }

    // MARK: Private

    /// Undo the journal written at the top of `start`.
    private func rollBackStart() {
        var s = state
        s.sleepDisabledByUs = false
        try? persistState(s)
        try? store.deleteSession()
    }

    /// In-process timers only; the launchd backstop is scheduled by callers
    /// before this runs.
    private func armDeadline(_ endsAt: Date) async {
        deadlineTimer?.invalidate()
        scheduledDeadline = endsAt
        // One timer at the deadline. Fire dates in the past fire immediately.
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.session, s.isExpired(at: self.clock()) else { return }
                await self.end(reason: .timer)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer

        refreshCountdown()
        if !countdownPaused { armCountdownTimer() }
    }

    /// 1 Hz redraw aligned to whole wall-clock seconds so the digits change
    /// in step with the menu bar clock. `pauseCountdown()` stops it entirely
    /// while the lid is closed.
    private func armCountdownTimer() {
        countdownTimer?.invalidate()
        let first = SessionMath.nextSecondBoundary(after: clock())
        let timer = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCountdown() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopTimers() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func persistState(_ s: RuntimeState) throws {
        try store.saveState(s)
        state = s
    }

    private func fail(_ message: String) {
        lastError = message
        Log.error(message)
    }

    private func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private static func endTitle(_ reason: EndReason, had: Bool) -> String {
        switch reason {
        case .backstop: "Sleep restored"
        default: had ? "Session ended" : "Session restored"
        }
    }

    private func endBody(_ reason: EndReason) -> String {
        switch reason {
        case .timer: "Time is up. Sleep is back to normal."
        case .user: "Ended by you. Sleep is back to normal."
        case .quit: "Insomnia quit. Sleep is back to normal."
        case .batteryFloor: "Battery fell below \(config.endFloor)%. Sleep is back to normal."
        case .thermalCritical: "Thermal state is critical. Sleep is back to normal."
        case .backstop: "A previous session left changes behind; everything has been undone."
        }
    }
}
