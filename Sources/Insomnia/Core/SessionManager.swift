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
    private(set) var remainingText: String = ""
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
    private let clock: @Sendable () -> Date

    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var countdownPaused = false

    init(
        paths: Paths,
        sleepGuard: any SleepGuarding,
        processControl: any ProcessSignaling,
        backstop: any BackstopScheduling,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.sleepGuard = sleepGuard
        self.processControl = processControl
        self.backstop = backstop
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
        SessionManager(
            paths: paths,
            sleepGuard: PmsetSleepGuard(),
            processControl: SignalProcessControl(),
            backstop: LaunchdBackstop(paths: paths)
        )
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

        do {
            try await sleepGuard.setSleepDisabled(true)
        } catch {
            // Roll back the journal: no session may exist if sleep is not disabled.
            var s = state
            s.sleepDisabledByUs = false
            try? persistState(s)
            try? store.deleteSession()
            fail("could not disable sleep: \(error.localizedDescription)")
            return
        }

        session = new
        lastError = nil
        Log.info("session started until \(iso(new.endsAt)) (\(Int(duration))s requested)")
        await armDeadline(new.endsAt)
        // PR2: set NSAppSleepDisabled for config.agentList; start lid/battery/thermal/network observers.
        // PR3: schedule "5 minutes left" notification.
    }

    func extend(by extra: TimeInterval) async {
        guard let current = session else { return }
        let updated = SessionMath.extended(current, by: extra, now: clock(), maxDuration: config.maxDuration)
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
        // PR2: stop observers; restore App Nap is intentionally left set (spec: open decisions).
        // PR3: post "session ended (reason)" notification.
        _ = had
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

        if !s.frozenPids.isEmpty {
            processControl.resume(pids: s.frozenPids)
            Log.info("resumed \(s.frozenPids.count) frozen pid(s)")
            s.frozenPids = []
            // PR2: Docker Desktop is frozen via its pids too; the flag is only a marker.
            s.dockerFrozen = false
            try? persistState(s)
        } else if s.dockerFrozen {
            s.dockerFrozen = false
            try? persistState(s)
        }

        // PR2: AudioControl restores savedOutputVolume / savedMuted and clears them.
        // Until then they are preserved on disk, never dropped.
        state = s
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
            // PR2: gate on lid state; only undo lid-close actions when the lid is open.
            // Here we assume open (the app only launches at login) and resume any
            // pids a crashed run left stopped.
            if !st.frozenPids.isEmpty {
                processControl.resume(pids: st.frozenPids)
                st.frozenPids = []
                st.dockerFrozen = false
                try? persistState(st)
                Log.info("reconcile: resumed frozen pids")
            }
            await armDeadline(s.endsAt)
            // PR2: resume observers.
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

    // MARK: Countdown (60 s redraw)

    /// Stop the minute redraw. PR2's lid observer calls this on lid close.
    func pauseCountdown() {
        countdownPaused = true
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Restart the minute redraw. PR2's lid observer calls this on lid open.
    func resumeCountdown() {
        countdownPaused = false
        refreshCountdown()
        armCountdownTimer()
    }

    /// Recompute `remainingText` from the injected clock.
    func refreshCountdown() {
        guard let s = session else {
            remainingText = ""
            return
        }
        remainingText = SessionMath.formatRemaining(s.remaining(at: clock()))
    }

    // MARK: Private

    private func armDeadline(_ endsAt: Date) async {
        do {
            try await backstop.schedule(endsAt: endsAt)
        } catch {
            Log.error("backstop schedule failed: \(error.localizedDescription)")
        }

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

    private func armCountdownTimer() {
        countdownTimer?.invalidate()
        let first = SessionMath.nextMinuteBoundary(after: clock())
        let timer = Timer(fire: first, interval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCountdown() }
        }
        timer.tolerance = 5
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
}
