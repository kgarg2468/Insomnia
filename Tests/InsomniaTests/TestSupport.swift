import Foundation
import XCTest
@testable import Insomnia

actor AsyncGate {
    private var started = false
    private var opened = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !opened else { return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        opened = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Creates a temp INSOMNIA_HOME and points the process environment at it.
final class TempHome {
    let root: URL
    let paths: Paths

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv(Paths.environmentKey, root.path, 1)
        paths = Paths.fromEnvironment()
    }

    func destroy() {
        unsetenv(Paths.environmentKey)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Records every call; can be told to throw.
final class FakeSleepGuard: SleepGuarding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _sleepDisabled = false
    private var _lowPowerGate: AsyncGate?
    var throwOn: Set<String> = []

    var calls: [String] { lock.withLock { _calls } }
    var sleepDisabled: Bool {
        get { lock.withLock { _sleepDisabled } }
        set { lock.withLock { _sleepDisabled = newValue } }
    }
    var lowPowerGate: AsyncGate? {
        get { lock.withLock { _lowPowerGate } }
        set { lock.withLock { _lowPowerGate = newValue } }
    }

    private func record(_ c: String) throws {
        lock.withLock { _calls.append(c) }
        if throwOn.contains(c) {
            throw SleepGuardError(command: c, status: 1, stderr: "sudo: a password is required")
        }
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        try record("disablesleep \(disabled ? 1 : 0)")
        sleepDisabled = disabled
    }

    func isSleepDisabled() async throws -> Bool {
        try record("pmset -g")
        return sleepDisabled
    }

    func setLowPowerMode(_ on: Bool) async throws {
        try record("lowpowermode \(on ? 1 : 0)")
        if on, let gate = lowPowerGate { await gate.wait() }
    }
}

final class FakeProcessControl: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var _resumed: [[Int32]] = []
    private var _suspended: [[Int32]] = []
    var resumed: [[Int32]] { lock.withLock { _resumed } }
    var suspended: [[Int32]] { lock.withLock { _suspended } }
    /// Called synchronously inside `suspend`, so a test can inspect disk
    /// at the moment the side effect happens.
    var onSuspend: (@Sendable ([Int32]) -> Void)?
    func resume(pids: [Int32]) { lock.withLock { _resumed.append(pids) } }
    func suspend(pids: [Int32], expectedParents: [Int32: Int32]) {
        lock.withLock { _suspended.append(pids) }
        onSuspend?(pids)
    }
}

/// Fake default output device with a hook fired inside `mute`.
final class FakeAudioControl: AudioControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _volume: Float
    private var _muted: Bool
    private var _applied: [(volume: Float, muted: Bool)] = []
    private var _mutes = 0
    var throwOnRead = false
    var throwOnApply = false
    var onMute: (@Sendable () -> Void)?

    init(volume: Float = 0.6, muted: Bool = false) {
        _volume = volume
        _muted = muted
    }

    var volume: Float { lock.withLock { _volume } }
    var muted: Bool { lock.withLock { _muted } }
    var applied: [(volume: Float, muted: Bool)] { lock.withLock { _applied } }
    var mutes: Int { lock.withLock { _mutes } }

    func read() throws -> (volume: Float, muted: Bool) {
        if throwOnRead { throw AudioControlError(what: "read", status: -1) }
        return lock.withLock { (_volume, _muted) }
    }

    func apply(volume: Float, muted: Bool) throws {
        if throwOnApply { throw AudioControlError(what: "apply", status: -1) }
        lock.withLock {
            _volume = volume
            _muted = muted
            _applied.append((volume, muted))
        }
    }

    func mute() throws {
        lock.withLock {
            _muted = true
            _mutes += 1
        }
        onMute?()
    }
}

/// Freezer over an injected process snapshot; signals go to a FakeProcessControl.
final class FakeFreezer: Freezing, @unchecked Sendable {
    private let lock = NSLock()
    var apps: [RunningApp]
    var processes: [ProcessEntry]
    let control: FakeProcessControl
    let selfBundleId: String

    init(apps: [RunningApp], processes: [ProcessEntry], control: FakeProcessControl, selfBundleId: String = Paths.bundleIdentifier) {
        self.apps = apps
        self.processes = processes
        self.control = control
        self.selfBundleId = selfBundleId
    }

    func plan(bundleIds: [String], config: Config, applyDenylist: Bool) -> [FreezeGroup] {
        lock.withLock {
            FreezePlanner.groups(bundleIds: bundleIds, apps: apps, processes: processes, config: config, selfBundleId: selfBundleId, applyDenylist: applyDenylist)
        }
    }

    func suspend(pids: [Int32], expectedParents: [Int32: Int32]) {
        control.suspend(pids: pids, expectedParents: expectedParents)
    }
    func resume(pids: [Int32]) { control.resume(pids: pids) }
}

/// Mutable clamshell reading for reconcile gating tests.
final class FakeClamshell: @unchecked Sendable {
    private let lock = NSLock()
    private var _closed: Bool?
    init(_ closed: Bool? = false) { _closed = closed }
    var closed: Bool? {
        get { lock.withLock { _closed } }
        set { lock.withLock { _closed = newValue } }
    }
}

final class FakeBackstop: BackstopScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduled: [Date] = []
    private var _clears = 0
    private var _failSchedule = false
    var scheduled: [Date] { lock.withLock { _scheduled } }
    var clears: Int { lock.withLock { _clears } }
    var failSchedule: Bool {
        get { lock.withLock { _failSchedule } }
        set { lock.withLock { _failSchedule = newValue } }
    }
    func schedule(endsAt: Date) async throws {
        if failSchedule { throw BackstopError(message: "fake launchd refused") }
        lock.withLock { _scheduled.append(endsAt) }
    }
    func clear() async throws { lock.withLock { _clears += 1 } }
}

/// A mutable fake clock usable from the @Sendable clock closure.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct Harness {
    let home: TempHome
    let guardFake: FakeSleepGuard
    let procs: FakeProcessControl
    let backstop: FakeBackstop
    let clock: FakeClock
    let store: Store
    let audio: FakeAudioControl
    let notifier: RecordingNotifier
    let clamshell: FakeClamshell

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        home = TempHome()
        guardFake = FakeSleepGuard()
        procs = FakeProcessControl()
        backstop = FakeBackstop()
        clock = FakeClock(now)
        store = Store(paths: home.paths)
        audio = FakeAudioControl()
        notifier = RecordingNotifier()
        clamshell = FakeClamshell(false)
    }

    func makeManager() -> SessionManager {
        let c = clock
        let lid = clamshell
        return SessionManager(
            paths: home.paths,
            sleepGuard: guardFake,
            processControl: procs,
            backstop: backstop,
            audio: audio,
            notifier: notifier,
            clamshell: { lid.closed },
            clock: { c.now }
        )
    }
}
