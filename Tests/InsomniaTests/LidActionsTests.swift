import XCTest
@testable import Insomnia

@MainActor
final class LidActionsTests: XCTestCase {
    var h: Harness!
    var freezer: FakeFreezer!

    let processes: [ProcessEntry] = [
        ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
        ProcessEntry(pid: 100, ppid: 1, startedAt: 1000),
        ProcessEntry(pid: 101, ppid: 100, startedAt: 1001),
        ProcessEntry(pid: 102, ppid: 100, startedAt: 1002),
        ProcessEntry(pid: 400, ppid: 1, startedAt: 4000),
        ProcessEntry(pid: 401, ppid: 400, startedAt: 4001),
    ]
    let apps: [RunningApp] = [
        RunningApp(pid: 100, bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
        RunningApp(pid: 400, bundleId: "com.docker.docker", name: "Docker"),
    ]

    override func setUp() async throws {
        h = Harness()
        freezer = FakeFreezer(apps: apps, processes: processes, control: h.procs)
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    private func make(dockerIdle: @escaping @Sendable () async throws -> Bool = { true }, mute: Bool = true) async -> (SessionManager, LidActions) {
        let m = h.makeManager()
        m.config.muteOnLidClose = mute
        m.config.freezeList = ["com.tinyspeck.slackmacgap"]
        let docker = DockerRule(freezer: freezer, probe: dockerIdle)
        let actions = LidActions(manager: m, freezer: freezer, docker: docker, audio: h.audio)
        return (m, actions)
    }

    func testCloseJournalsBeforeActing() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let store = h.store

        // The fake audio's mute sees state.json already holding the saved values.
        let sawSaved = Locked(false)
        h.audio.onMute = {
            let s = (try? store.loadState()) ?? nil
            sawSaved.value = s?.savedOutputVolume == 0.6 && s?.savedMuted == false
        }
        // Each suspend sees its own pids already journaled.
        let sawPids = Locked(true)
        h.procs.onSuspend = { pids in
            let s = (try? store.loadState()) ?? nil
            if !Set(pids).isSubset(of: Set(s?.frozenPids ?? [])) { sawPids.value = false }
        }

        await actions.onClose()

        XCTAssertTrue(sawSaved.value, "mute ran before the journal was written")
        XCTAssertTrue(sawPids.value, "SIGSTOP ran before the pids were journaled")
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [400, 401]])
        let s = try XCTUnwrap(try store.loadState())
        // Identity travels with each pid so resume can prove it is the same process.
        XCTAssertEqual(s.frozenProcesses, [
            FrozenProcess(pid: 100, startedAt: 1000),
            FrozenProcess(pid: 101, startedAt: 1001),
            FrozenProcess(pid: 102, startedAt: 1002),
            FrozenProcess(pid: 400, startedAt: 4000),
            FrozenProcess(pid: 401, startedAt: 4001),
        ])
        XCTAssertTrue(s.dockerFrozen)
        XCTAssertEqual(s.savedOutputVolume, 0.6)
        XCTAssertEqual(s.savedMuted, false)
        XCTAssertEqual(m.state, s)
        XCTAssertTrue(m.isActive)
    }

    func testOpenRestoresFromDiskAndClears() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.clock.advance(120)

        await actions.onOpen()

        XCTAssertEqual(h.procs.resumed, [[100, 101, 102, 400, 401]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.volume, 0.6)
        XCTAssertEqual(h.audio.applied.first?.muted, false)
        XCTAssertFalse(h.audio.muted)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [])
        XCTAssertFalse(s.dockerFrozen)
        XCTAssertNil(s.savedOutputVolume)
        XCTAssertNil(s.savedMuted)
        XCTAssertTrue(s.sleepDisabledByUs)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.remainingText, "58m")
    }

    /// The whole lid-close transaction, each journal write and the side
    /// effect that follows it, runs under the recovery lock: a backstop that
    /// wakes up in between cannot restore from a journal whose SIGSTOP or
    /// mute is still pending. Checked from inside the fakes with a second
    /// attempt on the same lock file.
    func testLidCloseHoldsTheRecoveryLockAcrossJournalAndSideEffects() async throws {
        let lock = RecoveryLock(url: h.home.paths.recoveryLock)
        let busyAtMute = Locked<Bool?>(nil)
        let busyAtSuspend = Locked<[Bool]>([])
        let busyAtProbe = Locked<Bool?>(nil)
        h.audio.onMute = { busyAtMute.value = (try? lock.tryAcquire()) == nil }
        h.procs.onSuspend = { _ in busyAtSuspend.value.append((try? lock.tryAcquire()) == nil) }
        let (m, actions) = await make(dockerIdle: {
            busyAtProbe.value = (try? lock.tryAcquire()) == nil
            return true
        })
        await m.start(duration: 3600)
        await actions.onClose()

        XCTAssertEqual(busyAtMute.value, true, "mute ran without the recovery lock")
        XCTAssertEqual(busyAtSuspend.value, [true, true], "SIGSTOP ran without the recovery lock")
        XCTAssertEqual(busyAtProbe.value, true, "Docker probe ran outside the transaction")
        XCTAssertNotNil(try lock.tryAcquire(), "lock still held after the transaction")
    }

    func testOpenTwiceIsIdempotent() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        await actions.onOpen()
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
    }

    func testOpenWithCleanStateDoesNothing() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.audio.applied.count, 0)
    }

    func testNoSessionIsNoop() async throws {
        let (_, actions) = await make()
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.procs.suspended, [])
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
    }

    func testMuteOffLeavesAudioAlone() async throws {
        let (m, actions) = await make(mute: false)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.count, 0)
    }

    func testDockerWithContainersIsLeftAlone() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).dockerFrozen)
    }

    func testDockerProbeErrorLeavesDockerAlone() async throws {
        let (m, actions) = await make(dockerIdle: { throw ShellTimeoutError.timedOut(exe: "docker", seconds: 5) })
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).dockerFrozen)
    }

    func testDockerRuleOffSkipsDocker() async throws {
        let (m, actions) = await make()
        m.config.dockerRule = false
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
    }

    func testSessionEndWhileClosedRestoresEverything() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        await m.end(reason: .timer)
        XCTAssertEqual(h.procs.resumed, [[100, 101, 102, 400, 401]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        // Lid open afterwards: no session, nothing happens.
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)
    }

    func testSessionEndWhileDockerProbeIsSuspendedNeverFreezesDocker() async throws {
        let probe = AsyncGate()
        let (m, actions) = await make(dockerIdle: {
            await probe.wait()
            return true
        })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await probe.waitUntilStarted()

        // The end queues behind the lid-close transaction; release the probe
        // first, then wait for both.
        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        await probe.open()
        await close.value
        _ = await end.value

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testAudioReadFailureSkipsMuteButStillFreezes() async throws {
        let (m, actions) = await make()
        h.audio.throwOnRead = true
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        XCTAssertEqual(h.procs.suspended.count, 2)
    }

    /// A helper that was already stopped before the lid closed (a debugger,
    /// the user, an earlier crash) is not Insomnia's to freeze: it is never
    /// journaled and never resumed on lid open.
    func testProcessStoppedBeforeTheSessionIsNeverOwned() async throws {
        freezer.processes = [
            ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
            ProcessEntry(pid: 100, ppid: 1, startedAt: 1000),
            ProcessEntry(pid: 101, ppid: 100, startedAt: 1001),
            ProcessEntry(pid: 102, ppid: 100, startedAt: 1002, stopped: true),
            ProcessEntry(pid: 400, ppid: 1, startedAt: 4000),
            ProcessEntry(pid: 401, ppid: 400, startedAt: 4001),
        ]
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101], [400, 401]])
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [100, 101, 400, 401])

        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [[100, 101, 400, 401]])
        XCTAssertFalse(h.procs.resumed.flatMap { $0 }.contains(102), "SIGCONT sent to a process Insomnia never stopped")
    }

    /// The kernel is re-checked at SIGSTOP time. A pid it would not stop
    /// (already stopped, exited, reused) was journaled first and must leave
    /// the journal, or a later resume would claim it.
    func testPidTheKernelWouldNotStopIsDroppedFromTheJournal() async throws {
        let (m, actions) = await make()
        h.procs.refuseSuspend = [101, 400, 401]
        await m.start(duration: 3600)
        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [400, 401]])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 102])
        XCTAssertFalse(s.dockerFrozen, "Docker marked frozen although no Docker pid was stopped")

        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [[100, 102]])
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T
    init(_ v: T) { _v = v }
    var value: T {
        get { lock.withLock { _v } }
        set { lock.withLock { _v = newValue } }
    }
}
