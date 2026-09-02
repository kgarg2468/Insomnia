import Foundation
import XCTest
@testable import Insomnia

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
    var throwOn: Set<String> = []

    var calls: [String] { lock.withLock { _calls } }
    var sleepDisabled: Bool {
        get { lock.withLock { _sleepDisabled } }
        set { lock.withLock { _sleepDisabled = newValue } }
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
    }
}

final class FakeProcessControl: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var _resumed: [[Int32]] = []
    var resumed: [[Int32]] { lock.withLock { _resumed } }
    func resume(pids: [Int32]) { lock.withLock { _resumed.append(pids) } }
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

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        home = TempHome()
        guardFake = FakeSleepGuard()
        procs = FakeProcessControl()
        backstop = FakeBackstop()
        clock = FakeClock(now)
        store = Store(paths: home.paths)
    }

    func makeManager() -> SessionManager {
        let c = clock
        return SessionManager(
            paths: home.paths,
            sleepGuard: guardFake,
            processControl: procs,
            backstop: backstop,
            clock: { c.now }
        )
    }
}
