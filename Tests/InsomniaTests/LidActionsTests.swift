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

    private func make(
        dockerIdle: @escaping @Sendable () async throws -> Bool = { true },
        mute: Bool = true,
        sampler: BrightnessSampler? = nil,
        reassertDelay: Duration = .seconds(3600)
    ) async -> (SessionManager, LidActions) {
        let m = h.makeManager(reassertDelay: reassertDelay)
        m.config.muteOnLidClose = mute
        m.config.freezeList = ["com.tinyspeck.slackmacgap"]
        let docker = DockerRule(freezer: freezer, probe: dockerIdle)
        let actions = LidActions(manager: m, freezer: freezer, docker: docker, audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: sampler)
        return (m, actions)
    }

    /// A sampler over the harness fakes whose idle clock the test controls.
    private func makeSampler(idle: Locked<Double>) -> BrightnessSampler {
        BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { idle.value })
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    // MARK: Trusted brightness samples

    /// Recent input, panel awake, backlight unsuppressed: the values read
    /// now are the user's and are what gets journaled.
    func testTrustedReadAtCloseJournalsTheCurrentValues() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        // An older sample must not win over a trusted current read.
        h.display.brightness = 0.3
        h.keyboard.brightness = 0.2
        sampler.sample()
        h.display.brightness = 0.7
        h.keyboard.brightness = 0.5

        await actions.onClose()

        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertNil(m.lastError)
    }

    /// The live defect: the lid closes after the panel idle-dimmed and
    /// slept. The display reads its dim value and the keyboard reads 0.
    /// Restoring those would leave a dim panel and a dead backlight; the
    /// last trusted sample is journaled instead. Both are still set to 0.
    func testAsleepAndSuppressedAtCloseJournalsTheLastTrustedSample() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        sampler.sample()
        idle.value = 400
        h.display.asleep = true
        h.display.brightness = 0.0625
        h.keyboard.suppressedOrDimmed = true
        h.keyboard.brightness = 0

        await actions.onClose()

        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7, "the idle-dim value was journaled")
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5, "the suppressed 0 was journaled")
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertNil(m.lastError)

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
    }

    /// Nothing trustworthy is known for the keyboard and it reads 0 under
    /// suppression: journaling that 0 would restore "off" on open, so the
    /// keyboard is left to macOS entirely. The display is still darkened.
    func testSuppressedKeyboardWithNoSampleIsLeftAlone() async throws {
        let idle = Locked<Double>(400)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        h.keyboard.suppressedOrDimmed = true
        h.keyboard.brightness = 0

        await actions.onClose()

        XCTAssertEqual(h.keyboard.sets, [], "a suppressed keyboard with nothing to restore must not be written")
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertNil(m.lastError)
        XCTAssertTrue(logText().contains("keyboard backlight suppressed by display sleep and no trusted sample; leaving it to macOS"), logText())

        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sets, [0, 0.7])
    }

    /// An asleep display with no sample: the dim value is journaled anyway
    /// and set to 0. A dim panel on open beats a black one; the
    /// brightness-up key is the manual fallback.
    func testAsleepDisplayWithNoSampleJournalsTheDimValue() async throws {
        let idle = Locked<Double>(400)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        h.display.asleep = true
        h.display.brightness = 0.0625

        await actions.onClose()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.0625)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertNil(m.lastError)
        XCTAssertTrue(logText().contains("display brightness read while dimmed or asleep and no trusted sample; restoring that value on open"), logText())
        XCTAssertFalse(logText().contains("[error] insomnia: display brightness read while dimmed"), "a known-dim save is a warning, not an error")

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.0625])
    }

    /// Without a sampler (tests, or a build that never wired one) the
    /// device's own asleep/suppressed reading decides on its own.
    func testWithoutASamplerTheDeviceStateAloneDecides() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        h.keyboard.suppressedOrDimmed = true
        h.keyboard.brightness = 0

        await actions.onClose()

        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
    }

    // MARK: Re-asserted restore

    /// powerd re-applies its own remembered brightness a moment after the
    /// wake and can override the restore, so the restore is written a
    /// second time after a delay. With the delay at zero both writes land.
    func testOpenReassertsTheRestoreAfterTheDelay() async throws {
        let (m, actions) = await make(reassertDelay: .zero)
        await m.start(duration: 3600)
        await actions.onClose()

        await actions.onOpen()

        for _ in 0..<300 where h.display.sets.count < 3 || h.keyboard.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.display.sets, [0, 0.7, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness, "the re-assert is not a journaled action")
        XCTAssertNil(s.savedKeyboardBrightness)
        XCTAssertNil(m.lastError)
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("display restore re-asserted"), log)
        XCTAssertTrue(log.contains("keyboard restore re-asserted"), log)
    }

    /// A restore that failed is not re-asserted: there is nothing known to
    /// have been written, and the entry stays for the next undo.
    func testFailedRestoreIsNotReasserted() async throws {
        let (m, actions) = await make(reassertDelay: .zero)
        await m.start(duration: 3600)
        await actions.onClose()
        h.display.throwOnSet = true

        await actions.onOpen()

        for _ in 0..<300 where h.keyboard.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
        XCTAssertEqual(h.display.sets, [0], "a display whose restore threw must not be written again")
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
    }

    /// The restore succeeded but clearing its journal entry did not: that
    /// is reported, not swallowed, and the entry stays so the next undo
    /// retries (writing the same value again is harmless).
    func testRestoreWhoseJournalClearFailsIsReported() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        let file = h.home.paths.stateFile.path
        h.display.onSet = { value in
            // Rename over an immutable state.json is refused.
            if value != 0 { try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file) }
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onOpen()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("restored but the journal entry could not be cleared"), err)
        XCTAssertTrue(err.contains("it will be retried"), err)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7, "the entry must stay for the next undo")
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)

        h.display.onSet = nil
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.7, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
    }

    // MARK: Display and keyboard backlight

    /// The saved brightness is on disk before the display or keyboard is
    /// touched: a crash between the two leaves a journal that restores.
    func testCloseJournalsBrightnessBeforeDarkening() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let store = h.store
        let displaySaw = Locked<Float?>(nil)
        h.display.onSet = { _ in displaySaw.value = ((try? store.loadState()) ?? nil)?.savedDisplayBrightness }
        let keyboardSaw = Locked<Float?>(nil)
        h.keyboard.onSet = { _ in keyboardSaw.value = ((try? store.loadState()) ?? nil)?.savedKeyboardBrightness }

        await actions.onClose()

        XCTAssertEqual(displaySaw.value, 0.7, "display set to 0 before its brightness was journaled")
        XCTAssertEqual(keyboardSaw.value, 0.5, "keyboard set to 0 before its backlight was journaled")
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(h.display.sleepRequests, 1)
        let s = try XCTUnwrap(try store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(m.state, s)
        XCTAssertNil(m.lastError)
    }

    /// Darkening is the first step, before mute and every freeze.
    func testDarkeningRunsBeforeMuteAndFreezes() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let order = Locked<[String]>([])
        h.display.onSet = { _ in order.value.append("display") }
        h.keyboard.onSet = { _ in order.value.append("keyboard") }
        h.audio.onMute = { order.value.append("mute") }
        h.procs.onSuspend = { _ in order.value.append("freeze") }

        await actions.onClose()

        XCTAssertEqual(order.value, ["display", "keyboard", "mute", "freeze", "freeze"])
    }

    /// A second close without an open in between (a crash, a reconcile with
    /// the lid still shut) reads 0 and must not overwrite the real values.
    func testSecondCloseKeepsTheFirstSavedBrightness() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.display.brightness, 0)
        XCTAssertEqual(h.keyboard.brightness, 0)

        await actions.onClose()

        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.display.sets, [0, 0])
        XCTAssertEqual(h.keyboard.sets, [0, 0])

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0, 0.5])
    }

    func testDisplayReadFailureSkipsTheDisplayButKeyboardAndFreezesStillRun() async throws {
        let (m, actions) = await make()
        h.display.throwOnRead = true
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [], "a display whose brightness is unknown must not be set")
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertNil(m.lastError, "a skipped display is logged, not surfaced as an error")

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [], "nothing saved, nothing restored")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
    }

    /// Setting 0 failed: the value is still journaled, so the open restores
    /// it (harmless if the panel never dimmed).
    func testDisplaySetFailureKeepsTheSavedValueForTheOpen() async throws {
        let (m, actions) = await make()
        h.display.throwOnSet = true
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertNil(m.lastError)

        h.display.throwOnSet = false
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.7])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
    }

    func testDarkenOffTouchesNeitherDisplayNorKeyboard() async throws {
        let (m, actions) = await make()
        m.config.darkenDisplayOnLidClose = false
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sleepRequests, 0)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness)
        XCTAssertNil(s.savedKeyboardBrightness)
        XCTAssertEqual(h.procs.suspended.count, 2, "the rest of the transaction still runs")

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.wakes, 0)
    }

    /// Open: wake the panel first (a slept display lights before its
    /// brightness returns), restore both, clear both entries.
    func testOpenWakesThenRestoresBothAndClearsTheJournal() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        let display = h.display
        let wokeBeforeDisplaySet = Locked<Bool?>(nil)
        display.onSet = { value in if value != 0 { wokeBeforeDisplaySet.value = display.wakes == 1 } }
        let wokeBeforeKeyboardSet = Locked<Bool?>(nil)
        h.keyboard.onSet = { value in if value != 0 { wokeBeforeKeyboardSet.value = display.wakes == 1 } }

        await actions.onOpen()

        XCTAssertEqual(wokeBeforeDisplaySet.value, true, "display brightness restored before the panel was woken")
        XCTAssertEqual(wokeBeforeKeyboardSet.value, true)
        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness)
        XCTAssertNil(s.savedKeyboardBrightness)
        XCTAssertEqual(m.state, s)
        XCTAssertNil(m.lastError)
        XCTAssertTrue(m.isActive)
    }

    func testDisplayRestoreFailureKeepsTheEntryAndReportsIt() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.display.throwOnSet = true

        await actions.onOpen()

        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not restore display brightness"), err)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7, "a failed restore stays journaled for the next undo")
        XCTAssertNil(s.savedKeyboardBrightness, "the keyboard is restored independently")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)

        // The next open retries from disk.
        h.display.throwOnSet = false
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.keyboard.sets, [0, 0.5], "already restored, not restored twice")
    }

    func testKeyboardRestoreFailureKeepsTheEntryAndReportsIt() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.keyboard.throwOnSet = true

        await actions.onOpen()

        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not restore keyboard backlight"), err)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.display.sets, [0, 0.7])

        h.keyboard.throwOnSet = false
        await m.end(reason: .user)
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testSessionEndWhileClosedRestoresDisplayAndKeyboard() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()

        await m.end(reason: .timer)

        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// Display sleep is refused whenever any process holds a display
    /// assertion; brightness 0 is the mechanism, the sleep is a bonus.
    func testDisplaySleepRequestFailureIsOnlyLogged() async throws {
        let (m, actions) = await make()
        h.display.throwOnSleep = true
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertNil(m.lastError)
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("display sleep request failed"), log)
    }

    func testNoKeyboardBacklightSkipsTheKeyboard() async throws {
        let (m, actions) = await make()
        h.keyboard.brightness = nil
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertNil(m.lastError)

        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sets, [0, 0.7])
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

    // MARK: Provisional freeze entries

    /// Until the kernel has reported which pids it stopped, the journal must
    /// not claim any of them. Entries are written without identity first
    /// and only the confirmed SIGSTOPs gain one.
    func testCandidatesAreJournaledWithoutIdentityUntilTheKernelConfirmsTheStop() async throws {
        let (m, actions) = await make()
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let store = h.store
        let provisional = Locked(true)
        h.procs.onSuspend = { pids in
            let s = (try? store.loadState()) ?? nil
            let mine = (s?.frozenProcesses ?? []).filter { pids.contains($0.pid) }
            if mine.map(\.pid) != pids || !mine.allSatisfy({ $0.identity == nil }) { provisional.value = false }
        }

        await actions.onClose()

        XCTAssertTrue(provisional.value, "candidates were journaled as owned before the kernel confirmed the stop")
        let s = try XCTUnwrap(try store.loadState())
        XCTAssertEqual(s.frozenProcesses, [
            FrozenProcess(pid: 100, startedAt: 1000),
            FrozenProcess(pid: 102, startedAt: 1002),
            FrozenProcess(pid: 400, startedAt: 4000),
            FrozenProcess(pid: 401, startedAt: 4001),
        ])
        XCTAssertTrue(s.dockerFrozen)
        XCTAssertEqual(m.state, s)
    }

    /// Greptile P1: a skipped pid whose removal from the journal fails must
    /// not stay recorded as owned, or the next resume SIGCONTs a process
    /// Insomnia never stopped. Whatever the failed confirmation leaves on
    /// disk has to be non-resumable.
    func testSkippedPidWhoseConfirmationSaveFailsIsNeverResumed() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { _ in
            // The confirmation write after SIGSTOP fails: rename over an
            // immutable state.json is refused.
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenPids, [100, 101, 102])
        XCTAssertTrue(after.frozenProcesses.allSatisfy { $0.identity == nil },
                      "failed confirmation left ownership evidence on disk: \(after.frozenProcesses)")
        XCTAssertEqual(m.state, after)

        // 100 and 102 were stopped by Insomnia. 101 is stopped too, but by
        // somebody else: that is why the kernel refused our SIGSTOP. Nothing
        // on disk distinguishes them, so none may be resumed.
        h.procs.stoppedNow = [100, 101, 102]
        await actions.onOpen()
        XCTAssertFalse(h.procs.signaled.contains(101), "SIGCONT sent to a process Insomnia never stopped")
        XCTAssertEqual(h.procs.signaled, [], "provisional entries were treated as ownership")
        let opened = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(opened.frozenPids, [100, 101, 102], "stopped pids without proof must all stay for manual recovery")
        XCTAssertTrue(opened.frozenProcesses.allSatisfy { $0.identity == nil }, "\(opened.frozenProcesses)")
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("100, 101, 102"), err)
        XCTAssertTrue(err.contains("interrupted"), "message must name an unconfirmed freeze as a cause: \(err)")
        XCTAssertTrue(err.contains("Check each one first"), "message must ask for verification before any CONT: \(err)")
    }

    /// A crash between the provisional write and the confirmation leaves
    /// identity-less entries. The next launch must not resume them.
    func testProvisionalEntriesLeftByACrashAreNotResumedAfterRestart() async throws {
        var crashed = RuntimeState()
        crashed.frozenProcesses = [FrozenProcess(pid: 100, startedAt: nil), FrozenProcess(pid: 101, startedAt: nil)]
        try h.store.saveState(crashed)
        h.procs.stoppedNow = [100]

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(h.procs.signaled, [], "restart resumed a pid it cannot prove it stopped")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [FrozenProcess(pid: 100, startedAt: nil)], "the stopped one stays for a person; the running one is gone")
        XCTAssertNotNil(m.lastError)
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
