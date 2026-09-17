import AppKit
import XCTest
@testable import Insomnia

final class UIStatusTests: XCTestCase {
    @MainActor
    func testStatusHostUsesIntrinsicSizingAndHasAnIdleFittingSize() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let root = StatusRootView(
            model: MenuBarModel(),
            manager: harness.makeManager(),
            onTapIcon: {},
            onTapPill: { _ in },
            onTapCountdown: {},
            onHoldEnd: {},
            onWidthChange: { _ in }
        )

        let host = StatusItemController.makeHostingView(root)

        XCTAssertTrue(host.sizingOptions.contains(.intrinsicContentSize))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The status item cannot animate its width, so the pills must never
    /// change the layout after the slots have arrived: not while they
    /// stagger in, and not on a digit, which changes the text, its weight
    /// and its padding. Each pill is a fixed slot sized by its placeholder.
    @MainActor
    func testPillSlotsKeepTheFittingWidthWhileStaggeringAndWhileTyping() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        let model = MenuBarModel()
        model.phase = .entering(.start)
        model.slotsPresent = true
        func width() -> CGFloat {
            let root = StatusRootView(
                model: model,
                manager: manager,
                onTapIcon: {},
                onTapPill: { _ in },
                onTapCountdown: {},
                onHoldEnd: {},
                onWidthChange: { _ in }
            )
            return StatusItemController.makeHostingView(root).fittingSize.width
        }
        let idle = MenuBarModel()
        let idleWidth = StatusItemController.makeHostingView(StatusRootView(
            model: idle, manager: manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in }
        )).fittingSize.width

        model.visiblePills = 0
        let hidden = width()
        XCTAssertGreaterThan(hidden, idleWidth, "the slots are in the layout from the first frame")
        model.visiblePills = DurationInput.Field.allCases.count
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "the stagger is scale and opacity only")

        model.input = DurationInput(days: 12, hours: 3, minutes: 45)
        XCTAssertEqual(model.input.text(for: .days), "12")
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "typing never widens a slot")
        model.input = DurationInput(days: DurationInput.maxDays, hours: DurationInput.maxHours, minutes: DurationInput.maxMinutes)
        XCTAssertEqual(model.input.text(for: .minutes), "59")
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "the widest values fit the slots too")
        model.focused = .minutes
        model.focusVisible = true
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "the focus ring is an overlay")
    }

    /// The countdown a start will read is projected from the same session
    /// arithmetic the manager uses, in the shape that session will keep.
    @MainActor
    func testProjectedStartCountdownMatchesTheSessionShape() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let month: TimeInterval = 30 * 24 * 3600
        XCTAssertEqual(MenuBarModel.projectedStartCountdown(now: now, duration: 90 * 60, maxDuration: month), "1:30:00")
        let twoDays = MenuBarModel.projectedStartCountdown(now: now, duration: 2 * 86400, maxDuration: month)
        XCTAssertEqual(twoDays, SessionMath.formatCountdown(remaining: 2 * 86400, shape: .days))
        XCTAssertTrue(twoDays.hasPrefix("2d "))
        // The projection ticks: eight seconds into the wait it reads eight
        // seconds less, in the shape it was projected in.
        let projection = MenuBarModel.projectedStart(now: now, duration: 90 * 60, maxDuration: month)
        XCTAssertEqual(projection.shape, .hours)
        XCTAssertEqual(projection.endsAt, now.addingTimeInterval(90 * 60))
        XCTAssertEqual(projection.countdown(at: now), "1:30:00")
        XCTAssertEqual(projection.countdown(at: now.addingTimeInterval(8)), "1:29:52")
        XCTAssertEqual(projection.countdown(at: now.addingTimeInterval(2 * 3600)), "0:00:00")
        // A short start reads in the minutes shape, and the clamp applies.
        XCTAssertEqual(MenuBarModel.projectedStartCountdown(now: now, duration: 30 * 60, maxDuration: month), "30:00")
        XCTAssertEqual(MenuBarModel.projectedStartCountdown(now: now, duration: 5 * 3600, maxDuration: 3600), "1:00:00")
    }

    @MainActor
    func testTickAnimationIsShorterThanBaseAndHoldIsSubSecond() {
        XCTAssertEqual(Motion.holdDuration, 0.6, accuracy: 0.0001)
        XCTAssertLessThan(Motion.holdDuration, 1)
        XCTAssertEqual(Motion.tick(reduceMotion: true), Motion.reduced)
        XCTAssertNotEqual(Motion.tick(reduceMotion: false), Motion.base)
    }

    /// The blink was over in a handful of frames and barely read. It has to
    /// be slower than the baseline spring so the lid lift and the lash
    /// hand-over are seen, and slower than the Reduce Motion crossfade too.
    @MainActor
    func testTheBlinkIsSlowerThanTheBaseSpring() {
        XCTAssertGreaterThan(Motion.blinkResponse, Motion.baseResponse)
        XCTAssertEqual(Motion.blink(reduceMotion: false), .spring(response: 0.7, dampingFraction: 0.9))
        XCTAssertEqual(Motion.blink(reduceMotion: false), Motion.blink)
        XCTAssertNotEqual(Motion.blink, Motion.base)
        XCTAssertEqual(Motion.blink(reduceMotion: true), .easeInOut(duration: 0.3))
        XCTAssertGreaterThan(Motion.reducedBlinkDuration, 0.15)
    }

    /// The width spring is what the status item's length follows. It has to
    /// arrive, it has to stop (the display link is invalidated on settle),
    /// and it must not overshoot enough to be seen against the neighbours.
    @MainActor
    func testTheWidthSpringReachesItsTargetAndSettlesInFiniteSteps() {
        let dt: TimeInterval = 1.0 / 120
        var motion = WidthSpringMotion(spring: Motion.widthSpring, value: 32)
        XCTAssertTrue(motion.isSettled)
        motion.retarget(240)
        XCTAssertFalse(motion.isSettled)
        XCTAssertEqual(motion.value, 32, "retargeting alone does not move the width")

        var steps = 0
        var peak: CGFloat = 0
        while !motion.isSettled, steps < 1000 {
            motion.advance(by: dt)
            peak = max(peak, motion.value)
            steps += 1
        }
        XCTAssertTrue(motion.isSettled, "the spring must come to rest")
        XCTAssertEqual(motion.value, 240)
        XCTAssertEqual(motion.velocity, 0)
        XCTAssertLessThan(Double(steps) * dt, 1.5, "settles well inside a second and a half")
        XCTAssertGreaterThan(Double(steps) * dt, 0.3, "and is not a snap")
        // A damping ratio of 0.92 overshoots by exp(-0.92 * pi / sqrt(1 - 0.92^2)),
        // about 0.06 %: a tenth of a point on this move, inside the rest band,
        // so the neighbours never step back. Pinned so a softer spring cannot
        // slip in unnoticed.
        XCTAssertLessThan(peak, 240 + 0.25, "no visible overshoot")

        // Advancing a settled spring is a no-op, and heading back works the same.
        motion.advance(by: dt)
        XCTAssertEqual(motion.value, 240)
        motion.retarget(32)
        steps = 0
        while !motion.isSettled, steps < 1000 {
            motion.advance(by: dt)
            steps += 1
        }
        XCTAssertEqual(motion.value, 32)
        XCTAssertLessThan(steps, 1000)
    }

    /// Enter can land while the bar is still growing (and a refusal while it
    /// is narrowing): the spring is re-based on where it is and how fast it
    /// is moving, so a retarget bends the curve without a jump in either.
    @MainActor
    func testRetargetingTheWidthSpringMidFlightIsContinuous() {
        let dt: TimeInterval = 1.0 / 120
        var motion = WidthSpringMotion(spring: Motion.widthSpring, value: 32)
        motion.retarget(240)
        for _ in 0..<12 { motion.advance(by: dt) }  // 0.1 s in, moving fast
        let value = motion.value
        let velocity = motion.velocity
        XCTAssertGreaterThan(velocity, 100, "mid-flight, not settled")

        motion.retarget(90)
        XCTAssertEqual(motion.value, value, "position is continuous through the retarget")
        XCTAssertEqual(motion.velocity, velocity, "and so is velocity")
        motion.advance(by: dt)
        // One frame later the width has moved by about one frame's worth of
        // the velocity it had: no jump, the momentum carries on.
        XCTAssertEqual(motion.value - value, velocity * dt, accuracy: abs(velocity) * dt * 0.5)

        var steps = 0
        while !motion.isSettled, steps < 1000 {
            motion.advance(by: dt)
            steps += 1
        }
        XCTAssertEqual(motion.value, 90)
        XCTAssertLessThan(steps, 1000)
    }

    /// A dropped frame is caught up on the next one: the curve is a function
    /// of time, so two half-steps and one whole step land on the same width.
    @MainActor
    func testTheWidthSpringIsTimeBasedNotStepBased() {
        var whole = WidthSpringMotion(spring: Motion.widthSpring, value: 32)
        var halves = whole
        whole.retarget(240)
        halves.retarget(240)
        whole.advance(by: 0.1)
        halves.advance(by: 0.05)
        halves.advance(by: 0.05)
        XCTAssertEqual(whole.value, halves.value, accuracy: 0.0001)
        XCTAssertEqual(whole.velocity, halves.velocity, accuracy: 0.0001)
    }

    func testCountdownShapeIsDerivedFromSessionSpan() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(30 * 60)).countdownShape, .minutes)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600)).countdownShape, .hours)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(4 * 3600)).countdownShape, .hours)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(2 * 86400)).countdownShape, .days)
        // The shape rides on the persisted span, so it comes back identical after a reload.
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(4 * 3600))
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(Session.self, from: data).countdownShape, .hours)
    }

    @MainActor
    func testCountdownTextTicksInHoursShapeAndPausesWithLid() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 4 * 3600)
        XCTAssertEqual(m.countdownText, "4:00:00")
        XCTAssertEqual(m.remainingText, "4h")

        h.clock.advance(3 * 3600 + 55 * 60 + 53)
        m.refreshCountdown()
        XCTAssertEqual(m.countdownText, "0:04:07")
        XCTAssertEqual(m.remainingText, "4m")

        m.pauseCountdown()
        h.clock.advance(60)
        XCTAssertEqual(m.countdownText, "0:04:07")
        m.resumeCountdown()
        XCTAssertEqual(m.countdownText, "0:03:07")

        await m.end(reason: .user)
        XCTAssertEqual(m.countdownText, "")
    }

    @MainActor
    func testCountdownTextUsesMinutesShapeForShortSession() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 30 * 60)
        XCTAssertEqual(m.countdownText, "30:00")
        h.clock.advance(29 * 60 + 51)
        m.refreshCountdown()
        XCTAssertEqual(m.countdownText, "00:09")
    }

    func testSleepHeldLine() {
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep held per journal \u{2014} not verified live", isWarning: false)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: false),
            SleepHeldLine.Line(text: "Sleep is not held \u{2014} this session is not keeping the Mac awake", isWarning: true)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: false, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep still held with no session", isWarning: true)
        )
        XCTAssertNil(SleepHeldLine.line(sessionActive: false, sleepHeld: false))
    }

    @MainActor
    func testPlaceholderReportsNothing() {
        let s = PlaceholderStatus()
        XCTAssertFalse(s.lidClosed)
        XCTAssertNil(s.batteryPercent)
        XCTAssertFalse(s.isCharging)
        XCTAssertNil(s.wifiSSID)
        XCTAssertNil(s.lastGap)
        XCTAssertEqual(s.frozenCount, 0)
        XCTAssertFalse(s.dockerPaused)
        XCTAssertTrue(s.throttledBrowsers.isEmpty)
        XCTAssertNil(s.instantWatts())
        s.refreshInstant()
        s.refreshOnDemand()
        s.relaunchUnthrottled("Chrome")
    }

    func testMachineLine() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: true, watts: 4.12, wifiSSID: "iPhone", batteryPercent: nil, isCharging: false),
            "Lid: closed \u{00B7} 4.1 W \u{00B7} Wi-Fi: iPhone"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: nil, batteryPercent: nil, isCharging: false),
            "Lid: open"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: "", batteryPercent: 82, isCharging: true),
            "Lid: open \u{00B7} 82% charging"
        )
    }

    func testActionsLine() {
        XCTAssertNil(StatusLines.actions(frozenCount: 0, dockerPaused: false, lastGap: nil))
        XCTAssertEqual(StatusLines.actions(frozenCount: 3, dockerPaused: true, lastGap: nil), "3 apps frozen \u{00B7} Docker paused")
        XCTAssertEqual(StatusLines.actions(frozenCount: 1, dockerPaused: false, lastGap: 12.4), "1 app frozen \u{00B7} last gap 12s")
        XCTAssertEqual(StatusLines.actions(frozenCount: 0, dockerPaused: true, lastGap: 0), "Docker paused")
    }

    func testThrottleWarning() {
        XCTAssertNil(StatusLines.throttleWarning([]))
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome"]), "\u{26A0} Chrome is throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc"]), "\u{26A0} Chrome and Arc are throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc", "Chromium"]), "\u{26A0} Chrome, Arc, and Chromium are throttled")
    }

    func testMenuListsStatusThenSettingsAndQuit() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: "Lid: closed \u{00B7} 82%",
            actions: "3 apps frozen",
            throttledBrowsers: ["Chrome"],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Sleep held per journal \u{2014} not verified live", kind: .info),
            StatusMenu.Item(title: "Lid: closed \u{00B7} 82%", kind: .info),
            StatusMenu.Item(title: "3 apps frozen", kind: .info),
            StatusMenu.Item(title: "\u{26A0} Chrome is throttled", kind: .warning),
            StatusMenu.Item(title: "Relaunch Chrome unthrottled", kind: .relaunchBrowser("Chrome")),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
    }

    func testIdleMenuIsJustSettingsAndQuitWithNoLeadingSeparator() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: ""
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
        XCTAssertFalse(items.contains { $0.kind == .separator })
    }

    func testMenuShowsTheLastErrorAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: "sudo: a password is required"
        )
        XCTAssertEqual(items.first, StatusMenu.Item(title: "\u{26A0} sudo: a password is required", kind: .warning))
        XCTAssertEqual(items.map(\.kind), [.warning, .separator, .settings, .quit])
    }

    /// Greptile caught this as a regression: replacing the popover with a
    /// menu left the throttle warning with no way to act on it.
    func testEveryThrottledBrowserGetsItsOwnRelaunchItem() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            actions: nil,
            throttledBrowsers: ["Chrome", "Arc"],
            error: nil
        )
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser("Chrome") }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser("Arc") }.count, 1)
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser("Chrome"), .relaunchBrowser("Arc"), .separator, .settings, .quit]
        )
    }

    @MainActor
    func testBareEnterStartsTheDefaultPresetButNeverExtends() {
        let preset: TimeInterval = 4 * 3600
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .start, typed: nil, defaultPreset: preset),
            .run(preset)
        )
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .start, typed: 1800, defaultPreset: preset),
            .run(1800)
        )
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .extend, typed: nil, defaultPreset: preset),
            .reject
        )
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .start, typed: nil, defaultPreset: 0),
            .reject
        )
    }

    /// The pills can be in start mode over a live session: the user reopened
    /// them while the start was still in flight. Collapsing then has to show
    /// the countdown, not pretend the Mac is free to sleep.
    @MainActor
    func testCollapsingPillsLandsOnTheCountdownWheneverASessionIsActive() {
        XCTAssertEqual(StatusItemController.collapseTarget(sessionActive: true), .running)
        XCTAssertEqual(StatusItemController.collapseTarget(sessionActive: false), .idle)
    }

    @MainActor
    func testAStartLandingUnderTheStartPillsTurnsThemIntoExtendPills() {
        XCTAssertEqual(StatusItemController.phase(forActive: true, phase: .entering(.start)), .entering(.extend))
        XCTAssertEqual(StatusItemController.phase(forActive: false, phase: .entering(.extend)), .entering(.start))
        XCTAssertEqual(StatusItemController.phase(forActive: true, phase: .idle), .running)
        XCTAssertEqual(StatusItemController.phase(forActive: false, phase: .running), .idle)
        // Nothing to do when the phase already matches the manager.
        XCTAssertNil(StatusItemController.phase(forActive: true, phase: .running))
        XCTAssertNil(StatusItemController.phase(forActive: false, phase: .idle))
    }

    /// The pills take a stagger to retract, and the session can end inside
    /// that window: the deadline fires between the Esc and the landing. The
    /// target has to be read when the pills land, so the countdown does not
    /// come back for a session that is already over.
    @MainActor
    func testCollapseReadsTheSessionWhenThePillsLandNotWhenTheyStartRetracting() async throws {
        // Under Reduce Motion every stagger delay is zero, so the pills can
        // land before the session ends and the sequence this pins never
        // happens — the test would pass without exercising the fix. Skip
        // rather than pretend.
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.start(duration: 3600)
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        // Extend pills, fully open, over the live session.
        controller.model.phase = .entering(.extend)
        controller.model.visiblePills = DurationInput.Field.allCases.count

        controller.collapse()
        // The session ends while the pills are still on screen.
        await manager.end(reason: .user)
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertFalse(controller.model.slotsPresent)
    }

    /// Opening puts the three slots in the layout before any pill shows
    /// (one relayout), and collapsing takes them out only once the last pill
    /// has retracted (one relayout), never in between.
    @MainActor
    func testSlotsArriveOnOpenAndLeaveWithTheLastPill() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})

        controller.expand(mode: .start)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, 0, "the content staggers in after the slots are laid out")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)

        controller.collapse()
        XCTAssertTrue(controller.model.slotsPresent, "the slots stay while the pills retract")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        // The pills have all started retracting, but the last one is still
        // fading: the slots must stay until it has settled.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertTrue(controller.model.slotsPresent, "the bar must not snap under a pill that is still visible")
        try? await Task.sleep(for: .milliseconds(Int(Motion.retractSettleDuration * 1000) + 100))
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.phase, .idle)
    }

    /// The status item's width target comes from the SwiftUI layout and is
    /// meant to change once per open and once per close: the slots arrive
    /// with the phase, and leave with it once the last pill has settled. Same
    /// over a live session, where the countdown and the ring swap with the
    /// slots. The early narrow that starts the bar shrinking before the slots
    /// leave heads for the same width the layout then reports, so it does
    /// not count twice.
    ///
    /// What is measured is the count of distinct targets. Animations do not
    /// render in this background-only test process (an animated layout
    /// change reports its end value only), so this pins the discrete
    /// relayouts; per-frame interpolation of an animated layout width is kept
    /// out by setting the layout state outside any animation, which this
    /// cannot see. The length itself is animated by the width spring.
    @MainActor
    func testTheStatusItemWidthTargetChangesOncePerOpenAndOncePerClose() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        // Long enough for the stagger and the settle, whatever Reduce Motion says.
        let landed = Int((Motion.staggerDelay(index: 2, count: 3, reversed: false) + Motion.retractSettle()) * 1000) + 250
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "installing the host sets the idle width")
        XCTAssertGreaterThanOrEqual(controller.hostWidth, 24, "the host is laid out at the idle width, not left at zero")
        XCTAssertEqual(controller.hostWidth, controller.widthTarget, "install: the host is as wide as the first target")

        controller.expand(mode: .start)
        try? await Task.sleep(for: .milliseconds(landed))
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(controller.widthTargetChangeCount, 2, "open: one relayout")
        XCTAssertGreaterThanOrEqual(controller.hostWidth, controller.widthTarget, "open: the host grew to the pills' width")

        controller.collapse()
        try? await Task.sleep(for: .milliseconds(landed))
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertEqual(controller.widthTargetChangeCount, 3, "close: one relayout")

        await manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(controller.widthTargetChangeCount, 4, "countdown and ring: one relayout")

        controller.expand(mode: .extend)
        try? await Task.sleep(for: .milliseconds(landed))
        XCTAssertEqual(controller.widthTargetChangeCount, 5, "open over a session: one relayout")

        controller.collapse()
        try? await Task.sleep(for: .milliseconds(landed))
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(controller.widthTargetChangeCount, 6, "close to the countdown: one relayout")
    }

    /// While the recovery agent and pmset run, the projected countdown ticks
    /// like the live one will, and the tick stops the moment the session is
    /// confirmed and the live text takes over.
    @MainActor
    func testTheProjectedCountdownTicksWhileStartingAndStopsOnConfirmation() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        let gate = AsyncGate()
        h.backstop.armGate = gate
        controller.expand(mode: .start)
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))

        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertEqual(controller.model.pendingProjection?.shape, .hours)
        XCTAssertEqual(controller.model.pendingCountdown, "2:00:00")
        XCTAssertTrue(controller.pendingTickArmed)
        // Partial seconds round up, so the first whole second can still read
        // 2:00:00; the second one cannot.
        let deadline = Date().addingTimeInterval(2.5)
        while controller.model.pendingCountdown == "2:00:00", Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.model.pendingCountdown, "1:59:59")
        XCTAssertEqual(controller.model.phase, .starting)

        await gate.open()
        let confirmBy = Date().addingTimeInterval(2)
        while controller.model.phase != .running, Date() < confirmBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertFalse(controller.pendingTickArmed)
        XCTAssertNil(controller.model.pendingProjection)
        XCTAssertNil(controller.model.pendingCountdown)
        XCTAssertEqual(manager.countdownText, "2:00:00")
    }

    /// The digits are read by a local key monitor, which only sees events sent
    /// to a window this app owns. The catcher panel is that window, and the
    /// whole fix rests on it being able to take key without taking a click,
    /// and without activating this app: the app in front stays frontmost and
    /// only key status moves to the pills while they are up.
    @MainActor
    func testTheKeyCatcherPanelTakesKeyStatusWithoutTakingClicksOrActivating() {
        _ = NSApplication.shared
        let panel = KeyCatcherPanel()

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    /// Opening the pills has to put up the window that keyboard focus hangs
    /// off, and closing them has to take it away again.
    ///
    /// Key status itself cannot be asserted here: the test binary runs as a
    /// background-only process (`.prohibited`), which the window server never
    /// activates, so `NSApp.keyWindow` stays nil no matter what the app does.
    /// What is pinned instead is the panel's lifecycle, on top of the
    /// `canBecomeKey` contract above.
    @MainActor
    func testOpeningThePillsPutsUpTheKeyCatcherAndCollapsingTakesItDown() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})
        XCTAssertFalse(NSApp.windows.contains { $0 is KeyCatcherPanel && $0.isVisible })

        controller.expand(mode: .start)

        let panel = NSApp.windows.compactMap { $0 as? KeyCatcherPanel }.first { $0.isVisible }
        XCTAssertNotNil(panel)

        controller.collapse()

        XCTAssertFalse(panel?.isVisible ?? true)
        XCTAssertFalse(NSApp.windows.contains { $0 is KeyCatcherPanel && $0.isVisible })
    }
}
