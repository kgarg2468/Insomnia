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
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), .spring(response: 0.95, dampingFraction: 0.9))
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: false), .spring(response: 0.8, dampingFraction: 0.95))
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), Motion.blink)
        XCTAssertNotEqual(Motion.blink, Motion.base)
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: true), .easeInOut(duration: 0.3))
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: true), .easeInOut(duration: 0.3))
        XCTAssertGreaterThan(Motion.reducedBlinkDuration, 0.15)
    }

    /// The extension projection is created at Enter over a live session;
    /// it has to show at once, not wait for the manager to confirm it.
    @MainActor
    func testAPendingProjectionShowsOverTheLiveCountdown() {
        XCTAssertEqual(StatusRootView.countdownText(pending: "2:00:00", live: "1:00:00", phase: .running), "2:00:00")
        XCTAssertEqual(StatusRootView.countdownText(pending: "2:00:00", live: "", phase: .starting), "2:00:00")
        XCTAssertEqual(StatusRootView.countdownText(pending: nil, live: "1:00:00", phase: .running), "1:00:00")
        XCTAssertEqual(StatusRootView.countdownText(pending: nil, live: "", phase: .starting), MenuBarModel.startingText)
        XCTAssertEqual(StatusRootView.countdownText(pending: nil, live: "", phase: .idle), "")
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

    // MARK: Width choreography

    /// The width animator a test steps by hand. Paced on a "120 Hz"
    /// display, one-write on a "60 Hz" one; the display link it hands out
    /// is paused, so no frame ever runs by itself and every landing is the
    /// test's doing (`land()`), like `WidthPacedMotionTests` drives the
    /// animator.
    @MainActor
    private final class WidthProbe {
        /// Read by the animator whenever it decides a mode, so a test can
        /// change the "display" under a flight in the air.
        var framesPerSecond: Int
        var reduceMotion = false
        /// No display link at all: `isPaced` says one-write, and every
        /// target is written once and completes before `setTarget` returns.
        let linkless: Bool
        private(set) var animator: StatusWidthAnimator?
        private(set) var link: CADisplayLink?
        private(set) var applied: [CGFloat] = []

        init(framesPerSecond: Int, linkless: Bool = false) {
            self.framesPerSecond = framesPerSecond
            self.linkless = linkless
        }

        /// The paused link retains the animator as its target; a flight
        /// left in the air must not keep it alive past the test.
        func tearDown() {
            link?.invalidate()
            link = nil
        }

        func make(apply: @escaping (CGFloat) -> Void) -> StatusWidthAnimator {
            let animator = StatusWidthAnimator(
                backingScale: { 2 },
                maximumFramesPerSecond: { [weak self] in self?.framesPerSecond },
                reduceMotion: { [weak self] in self?.reduceMotion ?? false },
                makeLink: { [weak self] target, selector in
                    guard self?.linkless != true else { return nil }
                    let link = NSScreen.main?.displayLink(target: target, selector: selector)
                    link?.isPaused = true
                    self?.link = link
                    return link
                },
                apply: { [weak self] width in
                    self?.applied.append(width)
                    apply(width)
                }
            )
            self.animator = animator
            return animator
        }

        var isAnimating: Bool { animator?.isAnimating ?? false }
        var isPaced: Bool { animator?.isPaced ?? false }
        var target: CGFloat? { animator?.target }

        func frame() throws {
            guard let animator, let link else {
                throw XCTSkip("no screen to make a display link from")
            }
            animator.step(link)
        }

        /// Frames until the flight in progress lands; the count taken.
        @discardableResult
        func land() throws -> Int {
            var frames = 0
            while isAnimating, frames < 1000 {
                try frame()
                frames += 1
            }
            return frames
        }
    }

    /// A controller over a fresh manager with a `WidthProbe` for its width.
    @MainActor
    private struct Lab {
        let h: Harness
        let manager: SessionManager
        let probe: WidthProbe
        let controller: StatusItemController

        init(framesPerSecond: Int, linkless: Bool = false) {
            _ = NSApplication.shared
            h = Harness()
            manager = h.makeManager()
            let probe = WidthProbe(framesPerSecond: framesPerSecond, linkless: linkless)
            self.probe = probe
            controller = StatusItemController(
                manager: manager,
                status: PlaceholderStatus(),
                showSettings: {},
                makeWidthAnimator: { apply in probe.make(apply: apply) }
            )
        }

        func tearDown() {
            probe.tearDown()
            h.home.destroy()
        }

        var model: MenuBarModel { controller.model }
        var paced: Bool { probe.framesPerSecond >= StatusWidthAnimator.pacedMinimumFramesPerSecond }

        /// The width the layout has for `phase` with no slots; what a close
        /// must land on.
        func widthWithoutSlots(phase: MenuBarModel.Phase) -> CGFloat {
            let m = MenuBarModel()
            m.phase = phase
            m.pendingCountdown = model.pendingCountdown
            m.pendingProjection = model.pendingProjection
            let root = StatusRootView(model: m, manager: manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in })
            return max(StatusItemController.makeHostingView(root).fittingSize.width.rounded(.up), 24)
        }

        /// Let the layout report and the pills stagger in.
        func settleOpen() async {
            try? await Task.sleep(for: .milliseconds(300))
        }

        /// The pills' fade, with slack: a paced close takes the slots out
        /// only once this has passed since the close began, however soon
        /// the bar landed.
        func waitOutTheFade() async {
            try? await Task.sleep(for: .milliseconds(Int(Motion.closeFadeDuration * 1000) + 100))
        }

        /// Wait out a close: the flight is landed by hand and the fade
        /// waited out when paced; the stagger and the settle are waited out
        /// when one-write. Then the layout's own report of the landed width
        /// has time to arrive.
        func settleClose() async throws {
            if paced {
                try probe.land()
                await waitOutTheFade()
            } else {
                let landed = Int((Motion.staggerDelay(index: 2, count: 3, reversed: false) + Motion.retractSettle()) * 1000) + 250
                try? await Task.sleep(for: .milliseconds(landed))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The pills take a moment to leave, and the session can end inside
    /// that window: the deadline fires between the Esc and the landing. The
    /// target has to be read when the bar lands, so the countdown does not
    /// come back for a session that is already over; and the landing width
    /// follows the session, since the layout it is heading for changed.
    @MainActor
    func testCollapseReadsTheSessionWhenTheBarLandsNotWhenThePillsStartLeaving() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        await lab.manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lab.model.phase, .running)
        try lab.probe.land()
        lab.controller.expand(mode: .extend)
        await lab.settleOpen()
        try lab.probe.land()

        lab.controller.collapse()
        XCTAssertEqual(lab.probe.target, lab.widthWithoutSlots(phase: .running), "heading for the countdown")
        // The session ends while the pills are still on screen.
        await lab.manager.end(reason: .user)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(lab.model.slotsPresent, "still closing")
        XCTAssertEqual(lab.probe.target, lab.widthWithoutSlots(phase: .idle), "re-aimed at the idle layout")

        try lab.probe.land()
        await lab.waitOutTheFade()
        XCTAssertFalse(lab.manager.isActive)
        XCTAssertEqual(lab.model.phase, .idle)
        XCTAssertEqual(lab.model.visiblePills, 0)
        XCTAssertFalse(lab.model.slotsPresent)
    }

    /// Paced: opening puts the three slots in the layout before any pill
    /// shows (one relayout); closing fades the pills where they stand and
    /// takes the slots out only when the bar has landed on the idle width
    /// (one relayout), never in between.
    @MainActor
    func testSlotsArriveOnOpenAndLeaveWhenTheBarLandsWhenPaced() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, 0, "the content staggers in after the slots are laid out")
        await lab.settleOpen()
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertTrue(lab.probe.isAnimating, "the bar is growing to the pills")
        let opened = try lab.probe.land()
        XCTAssertGreaterThan(opened, 3)
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)

        controller.collapse()
        XCTAssertTrue(controller.model.slotsPresent, "the slots stay while the pills fade")
        XCTAssertTrue(controller.model.pillsFading, "opacity only, no scale")
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(lab.probe.isAnimating, "the bar heads for the idle width at once")
        XCTAssertEqual(lab.probe.target, lab.widthWithoutSlots(phase: .idle))
        for _ in 0..<10 { try lab.probe.frame() }
        XCTAssertTrue(controller.model.slotsPresent, "the slots must not leave while the bar is still wiping over them")
        try? await Task.sleep(for: .milliseconds(Int(Motion.closeFadeDuration * 1000) + 100))
        XCTAssertTrue(controller.model.slotsPresent, "the fade ending does not take the slots out either")

        try lab.probe.land()
        XCTAssertFalse(controller.model.slotsPresent, "the landing does")
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
    }

    /// One-write (a 60 Hz display; Reduce Motion takes the same path): the
    /// pills retract with their stagger and the slots leave once the last
    /// has settled, never before.
    @MainActor
    func testSlotsArriveOnOpenAndLeaveWithTheLastPillWhenOneWrite() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab(framesPerSecond: 60)
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, 0, "the content staggers in after the slots are laid out")
        await lab.settleOpen()
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertFalse(lab.probe.isAnimating, "one-write: the width was written once")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)

        controller.collapse()
        XCTAssertTrue(controller.model.slotsPresent, "the slots stay while the pills retract")
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        let written = lab.probe.applied.count
        // The pills have all started retracting, but the last one is still
        // fading: the slots must stay until it has settled.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertTrue(controller.model.slotsPresent, "the bar must not snap under a pill that is still visible")
        XCTAssertEqual(lab.probe.applied.count, written, "no width write before the slots leave")
        try? await Task.sleep(for: .milliseconds(Int(Motion.retractSettleDuration * 1000) + 100))
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.phase, .idle)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(lab.probe.applied.count, written + 1, "the width snaps once the layout reports")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
    }

    /// The status item's width target is meant to change once per open and
    /// once per close: the slots arrive with the phase, and the close heads
    /// for the width the layout will have once they leave, which is the
    /// width the layout then reports (so that report does not count twice).
    /// Same over a live session, where the countdown and the ring swap with
    /// the slots.
    ///
    /// What is measured is the count of distinct targets. Animations do not
    /// render in this background-only test process (an animated layout
    /// change reports its end value only), so this pins the discrete
    /// relayouts; per-frame interpolation of an animated layout width is kept
    /// out by setting the layout state outside any animation, which this
    /// cannot see. The length itself is moved by the width animator.
    @MainActor
    private func assertTheWidthTargetChangesOncePerOpenAndOncePerClose(framesPerSecond: Int) async throws {
        let lab = Lab(framesPerSecond: framesPerSecond)
        defer { lab.tearDown() }
        let controller = lab.controller
        let manager = lab.manager
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "installing the host sets the idle width")
        XCTAssertGreaterThanOrEqual(controller.hostWidth, 24, "the host is laid out at the idle width, not left at zero")
        XCTAssertEqual(controller.hostWidth, controller.widthTarget, "install: the host is as wide as the first target")

        controller.expand(mode: .start)
        await lab.settleOpen()
        try lab.probe.land()
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(controller.widthTargetChangeCount, 2, "open: one relayout")
        XCTAssertGreaterThanOrEqual(controller.hostWidth, controller.widthTarget, "open: the host grew to the pills' width")

        controller.collapse()
        try await lab.settleClose()
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.widthTargetChangeCount, 3, "close: one relayout")

        await manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(300))
        try lab.probe.land()
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(controller.widthTargetChangeCount, 4, "countdown and ring: one relayout")

        controller.expand(mode: .extend)
        await lab.settleOpen()
        try lab.probe.land()
        XCTAssertEqual(controller.widthTargetChangeCount, 5, "open over a session: one relayout")

        controller.collapse()
        try await lab.settleClose()
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.widthTargetChangeCount, 6, "close to the countdown: one relayout")
        XCTAssertFalse(lab.probe.isAnimating)
    }

    @MainActor
    func testTheStatusItemWidthTargetChangesOncePerOpenAndOncePerCloseWhenPaced() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        try await assertTheWidthTargetChangesOncePerOpenAndOncePerClose(framesPerSecond: 120)
    }

    @MainActor
    func testTheStatusItemWidthTargetChangesOncePerOpenAndOncePerCloseWhenOneWrite() async throws {
        try await assertTheWidthTargetChangesOncePerOpenAndOncePerClose(framesPerSecond: 60)
    }

    /// Enter before the bar has finished opening: the flight turns from
    /// wherever it is towards the countdown's width, the slots' own layout
    /// report (which can arrive after Enter) does not turn it back, and the
    /// slots leave exactly once, at the landing, with the projected
    /// countdown showing.
    @MainActor
    func testAnImmediateEnterWhileOpeningLandsOnTheCountdownWithTheSlotsRemovedOnce() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller
        let gate = AsyncGate()
        lab.h.backstop.armGate = gate

        controller.expand(mode: .start)
        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertNotNil(controller.model.pendingCountdown)
        let countdownWidth = lab.widthWithoutSlots(phase: .starting)
        XCTAssertEqual(controller.widthTarget, countdownWidth)
        XCTAssertEqual(controller.widthTargetChangeCount, 2, "install, then the countdown: the slots never became a target")
        // The slots' layout report lands now, after Enter.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.widthTarget, countdownWidth, "the late report does not turn the bar back")
        XCTAssertEqual(controller.widthTargetChangeCount, 2)
        XCTAssertTrue(controller.model.slotsPresent)

        try lab.probe.land()
        await lab.waitOutTheFade()
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertEqual(
            StatusRootView.countdownText(pending: controller.model.pendingCountdown, live: lab.manager.countdownText, phase: controller.model.phase),
            controller.model.pendingCountdown
        )
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, 2, "the layout reports the width the bar landed on")
        XCTAssertFalse(lab.probe.isAnimating)

        await gate.open()
        let deadline = Date().addingTimeInterval(2)
        while controller.model.phase != .running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertFalse(controller.model.slotsPresent)
    }

    /// The countdown is clicked while the bar is still closing on it: the
    /// slots never left, the pending landing is dropped, the pills fade
    /// back and the bar turns round to the pills' width.
    @MainActor
    func testReopeningDuringACloseKeepsTheSlotsAndFadesThePillsBack() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        await lab.settleOpen()
        try lab.probe.land()
        let pillsWidth = controller.widthTarget

        controller.collapse()
        for _ in 0..<10 { try lab.probe.frame() }
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, 0)
        let turned = lab.probe.applied.last!
        XCTAssertLessThan(turned, pillsWidth)

        controller.expand(mode: .start)
        XCTAssertTrue(controller.model.slotsPresent, "never left")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count, "faded back, no stagger")
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertEqual(lab.probe.target, pillsWidth, "back to the pills' width")
        try lab.probe.frame()
        XCTAssertEqual(lab.probe.applied.last, turned + 1, "the reversal brakes and restarts the ramp")

        try lab.probe.land()
        XCTAssertTrue(controller.model.slotsPresent, "the dropped landing never removes the slots")
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(lab.probe.applied.last, pillsWidth)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertTrue(controller.model.focusVisible, "the focus glow comes back after the pills")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        controller.collapse()
    }

    /// The bar can land before the last pill has faded (a short distance,
    /// or a stalled fade): the slots stay until the fade has had its whole
    /// `closeFadeDuration`, then leave in one relayout, and the layout's
    /// report of the landed width is not a new target.
    @MainActor
    func testSlotsWaitForTheFadeWhenTheBarLandsFirst() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        await lab.settleOpen()
        try lab.probe.land()
        let changes = controller.widthTargetChangeCount

        controller.collapse()
        try lab.probe.land()   // by hand, at once: the fade has barely begun
        XCTAssertFalse(lab.probe.isAnimating)
        XCTAssertEqual(lab.probe.applied.last, lab.widthWithoutSlots(phase: .idle))
        XCTAssertTrue(controller.model.slotsPresent, "landed, but the pills are still fading")
        XCTAssertTrue(controller.model.pillsFading)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.model.slotsPresent, "mid-fade: still there")
        XCTAssertEqual(controller.model.phase, .entering(.start))

        try? await Task.sleep(for: .milliseconds(Int(Motion.closeFadeDuration * 1000) - 150 + 100))
        XCTAssertFalse(controller.model.slotsPresent, "gone once the fade has run out")
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertEqual(controller.model.phase, .idle)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1, "the layout reports the width the bar landed on")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
        XCTAssertFalse(lab.probe.isAnimating)
    }

    /// No display link at all (a fast display, Reduce Motion off): every
    /// width is written once, so `isPaced` says one-write and the close
    /// takes the one-write path. The pills retract with their stagger over
    /// an unchanged width, the slots leave once the last has settled, and
    /// the width moves only after that, on the layout's report: it must
    /// never snap across pills still visible.
    @MainActor
    func testWithoutALinkTheCloseIsOneWriteAndTheWidthMovesOnlyAfterTheSlotsLeave() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab(framesPerSecond: 120, linkless: true)
        defer { lab.tearDown() }
        let controller = lab.controller
        XCTAssertFalse(lab.probe.isPaced, "no link: one-write")

        controller.expand(mode: .start)
        await lab.settleOpen()
        XCTAssertFalse(lab.probe.isAnimating, "no link: written once")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
        let pillsWidth = controller.widthTarget
        let written = lab.probe.applied.count
        let changes = controller.widthTargetChangeCount

        controller.collapse()
        XCTAssertEqual(controller.widthTarget, pillsWidth, "the width stays while the pills retract")
        XCTAssertEqual(lab.probe.applied.count, written, "no snap inside collapse()")
        XCTAssertTrue(controller.model.slotsPresent, "the slots stay while the pills retract")
        XCTAssertFalse(controller.model.pillsFading, "one-write: the pills retract, they do not fade in place")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        // The pills have all started retracting, but the last one is still
        // settling: the slots and the width must wait for it.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertTrue(controller.model.slotsPresent, "the last pill is still settling")
        XCTAssertEqual(controller.widthTarget, pillsWidth)
        XCTAssertEqual(lab.probe.applied.count, written, "no width write before the slots leave")
        try? await Task.sleep(for: .milliseconds(Int(Motion.retractSettleDuration * 1000) + 100))
        XCTAssertFalse(controller.model.slotsPresent, "gone once the last pill has settled")
        XCTAssertEqual(controller.model.phase, .idle)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTarget, lab.widthWithoutSlots(phase: .idle), "the width moves on the layout's report")
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1)
        XCTAssertEqual(lab.probe.applied.count, written + 1, "one write, after the slots left")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
        XCTAssertFalse(lab.probe.isAnimating)
    }

    /// A click on the eye while a paced close is still in flight: the phase
    /// is still `.entering`, but the key catcher is gone and the pills are
    /// fading, so there is nothing to commit and nothing more to collapse.
    /// The click reopens the pills, whether or not something was typed.
    @MainActor
    func testClickingTheEyeDuringAPacedCloseReopensThePills() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        await lab.settleOpen()
        try lab.probe.land()
        let pillsWidth = controller.widthTarget

        // Nothing typed: without a close in flight the click would collapse.
        controller.collapse()
        for _ in 0..<10 { try lab.probe.frame() }
        XCTAssertLessThan(lab.probe.applied.last!, pillsWidth)
        controller.iconTapped()
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count, "faded back")
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertEqual(lab.probe.target, pillsWidth, "back to the pills' width")
        try lab.probe.land()
        await lab.waitOutTheFade()
        XCTAssertTrue(controller.model.slotsPresent, "the dropped landing never takes the slots out")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertEqual(lab.probe.applied.last, pillsWidth)

        // Something typed: without a close in flight the click would commit.
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))
        controller.collapse()
        for _ in 0..<10 { try lab.probe.frame() }
        XCTAssertTrue(controller.model.pillsFading)
        controller.iconTapped()
        XCTAssertEqual(controller.model.phase, .entering(.start), "reopened, not committed")
        XCTAssertNil(controller.model.pendingCountdown)
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertEqual(lab.probe.target, pillsWidth)
        XCTAssertNil(controller.model.input.total, "the reopen path starts fresh")
        try lab.probe.land()
        await lab.waitOutTheFade()
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        controller.collapse()
    }

    /// Over a live session the same click reopens the pills in extend mode.
    @MainActor
    func testClickingTheEyeDuringAPacedCloseOverASessionReopensTheExtendPills() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller
        await lab.manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.model.phase, .running)
        try lab.probe.land()

        controller.expand(mode: .extend)
        await lab.settleOpen()
        try lab.probe.land()
        let pillsWidth = controller.widthTarget

        controller.collapse()
        for _ in 0..<10 { try lab.probe.frame() }
        XCTAssertEqual(lab.probe.target, lab.widthWithoutSlots(phase: .running), "heading for the countdown")
        controller.iconTapped()
        XCTAssertEqual(controller.model.phase, .entering(.extend))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(lab.probe.target, pillsWidth)
        try lab.probe.land()
        await lab.waitOutTheFade()
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.phase, .entering(.extend))
        controller.collapse()
    }

    /// Enter over a live session projects the extended countdown and the
    /// close heads for that layout. When the extend call resolves the
    /// projection clears; the manager may never notify (here the backstop
    /// refuses, so the session is unchanged), so the close itself has to
    /// re-aim at the layout the cleared projection leaves behind, before it
    /// lands, and the layout's report then lands on that same width.
    @MainActor
    func testTheCloseReAimsWhenTheExtendResolvesAndTheProjectionClears() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller
        await lab.manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.model.phase, .running)
        try lab.probe.land()
        let liveWidth = lab.widthWithoutSlots(phase: .running)

        controller.expand(mode: .extend)
        await lab.settleOpen()
        try lab.probe.land()
        controller.focus(.days)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .days))
        lab.h.backstop.failArm = true

        controller.commit()
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertNotNil(controller.model.pendingCountdown)
        let projectedWidth = lab.widthWithoutSlots(phase: .running)
        XCTAssertNotEqual(projectedWidth, liveWidth, "the projection has the days shape")
        XCTAssertEqual(lab.probe.target, projectedWidth, "heading for the projected countdown")
        let changes = controller.widthTargetChangeCount
        for _ in 0..<5 { try lab.probe.frame() }

        let deadline = Date().addingTimeInterval(2)
        while controller.model.pendingCountdown != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(controller.model.pendingCountdown, "the extend resolved")
        XCTAssertTrue(lab.manager.isActive)
        XCTAssertEqual(lab.manager.countdownText, "1:00:00", "refused: the session is unchanged")
        XCTAssertTrue(controller.model.slotsPresent, "still closing")
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(lab.probe.target, liveWidth, "re-aimed at the live countdown")
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1)

        try lab.probe.land()
        await lab.waitOutTheFade()
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(lab.probe.applied.last, liveWidth)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1, "the layout reports the width the bar landed on")
        XCTAssertFalse(lab.probe.isAnimating)
    }

    /// A second close while a paced close is in flight (Esc, then Settings
    /// or a click away) after the display stopped qualifying for pacing (a
    /// window move, Low Power Mode): the close in flight is re-aimed, never
    /// covered by a one-write retract. That retract would take the slots
    /// out after its shorter settle, under pills still fading, leave the
    /// fade flag up and the close pending, and the pending close would then
    /// swallow every layout report. Here: the slots stay past the settle,
    /// leave once the fade has run out and the bar has landed, the fade
    /// ends, and the next layout change is followed again.
    @MainActor
    func testASecondCloseAfterTheDisplaySlowedReAimsThePacedCloseInsteadOfRetractingOverIt() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        await lab.settleOpen()
        try lab.probe.land()
        let idleWidth = lab.widthWithoutSlots(phase: .idle)

        controller.collapse()
        XCTAssertTrue(controller.model.pillsFading)
        XCTAssertTrue(lab.probe.isAnimating, "paced close in flight")
        XCTAssertEqual(lab.probe.target, idleWidth)
        for _ in 0..<5 { try lab.probe.frame() }
        let changes = controller.widthTargetChangeCount

        lab.probe.framesPerSecond = 60
        XCTAssertFalse(lab.probe.isPaced, "a flight started now would be one-write")
        XCTAssertEqual(controller.model.phase, .entering(.start), "still closing")
        controller.collapse()
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertTrue(controller.model.pillsFading)
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertTrue(lab.probe.isAnimating, "the flight in the air goes on")
        XCTAssertEqual(lab.probe.target, idleWidth, "same landing")
        XCTAssertEqual(controller.widthTargetChangeCount, changes, "one target per close")

        try lab.probe.land()
        XCTAssertEqual(lab.probe.applied.last, idleWidth)
        XCTAssertTrue(controller.model.slotsPresent, "landed, but the pills are still fading")
        // Past the one-write settle, short of the fade: a retract started
        // over the close would have taken the slots out by now.
        try? await Task.sleep(for: .milliseconds(Int(Motion.retractSettleDuration * 1000) + 50))
        XCTAssertTrue(controller.model.slotsPresent, "the slots wait out the whole fade")
        XCTAssertTrue(controller.model.pillsFading)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        await lab.waitOutTheFade()
        XCTAssertFalse(controller.model.slotsPresent, "gone once the fade has run out")
        XCTAssertFalse(controller.model.pillsFading, "the fade ended")
        XCTAssertEqual(controller.model.phase, .idle)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, changes, "the layout reports the width the bar landed on")
        XCTAssertFalse(lab.probe.isAnimating)

        // The close is over: a layout change (a session landing, so the
        // countdown and the ring arrive) is followed again.
        await lab.manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(controller.widthTarget, lab.widthWithoutSlots(phase: .running), "the layout's report is followed")
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1)
        XCTAssertFalse(controller.model.slotsPresent, "the slots left once, at the close")
        XCTAssertFalse(controller.model.pillsFading)
    }

    /// The bar lands on the projected countdown before the pills have
    /// faded, so the slots' removal is queued on the fade's remainder; then
    /// the extend resolves (refused here, so the projection clears and the
    /// live countdown has another shape) during that wait. The queued
    /// removal belongs to the old landing and is cancelled: the slots stay
    /// until the replacement flight lands on the live width, then leave
    /// once.
    @MainActor
    func testAReAimDuringTheFadeWaitCancelsTheQueuedRemovalAndTheSlotsLeaveWithTheNewLanding() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller
        await lab.manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.model.phase, .running)
        try lab.probe.land()
        let liveWidth = lab.widthWithoutSlots(phase: .running)

        controller.expand(mode: .extend)
        await lab.settleOpen()
        try lab.probe.land()
        controller.focus(.days)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .days))
        let gate = AsyncGate()
        lab.h.backstop.armGate = gate
        lab.h.backstop.failArm = true

        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .running)
        let projectedWidth = lab.widthWithoutSlots(phase: .running)
        XCTAssertNotEqual(projectedWidth, liveWidth, "the projection has the days shape")
        XCTAssertEqual(lab.probe.target, projectedWidth)
        let changes = controller.widthTargetChangeCount

        try lab.probe.land()   // by hand, at once: the fade has barely begun
        XCTAssertFalse(lab.probe.isAnimating)
        XCTAssertEqual(lab.probe.applied.last, projectedWidth)
        XCTAssertTrue(controller.model.slotsPresent, "landed, but the pills are still fading: removal queued")
        XCTAssertTrue(controller.model.pillsFading)

        // The extend resolves inside that wait: the projection clears and
        // the close re-aims at the live countdown's width.
        await gate.open()
        let deadline = Date().addingTimeInterval(2)
        while controller.model.pendingCountdown != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(controller.model.pendingCountdown, "the extend resolved")
        XCTAssertEqual(lab.manager.countdownText, "1:00:00", "refused: the session is unchanged")
        XCTAssertTrue(controller.model.slotsPresent, "still closing")
        XCTAssertTrue(controller.model.pillsFading)
        XCTAssertEqual(lab.probe.target, liveWidth, "re-aimed at the live countdown")
        XCTAssertTrue(lab.probe.isAnimating, "the replacement flight is in the air")
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1)

        // The fade runs out with the replacement flight still in the air:
        // the queued removal was cancelled, so the slots stay.
        await lab.waitOutTheFade()
        XCTAssertTrue(controller.model.slotsPresent, "the cancelled removal never fires; the bar has not landed")
        XCTAssertTrue(controller.model.pillsFading)
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertTrue(lab.probe.isAnimating)

        try lab.probe.land()
        XCTAssertFalse(controller.model.slotsPresent, "gone at the replacement landing")
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(lab.probe.applied.last, liveWidth)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, changes + 1, "the layout reports the width the bar landed on")
        XCTAssertFalse(lab.probe.isAnimating)
    }

    /// The manager refuses the start while the bar is closing on the
    /// countdown: the close is cancelled, the pills come back with the
    /// value and the error label, and the pending landing never fires.
    @MainActor
    func testARefusedStartDuringACloseRestoresThePillsAndDropsTheLanding() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs animated width flights")
        let lab = Lab(framesPerSecond: 120)
        defer { lab.tearDown() }
        let controller = lab.controller
        lab.h.backstop.failArm = true

        controller.expand(mode: .start)
        await lab.settleOpen()
        try lab.probe.land()
        let pillsWidth = controller.widthTarget
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))

        controller.commit()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertTrue(controller.model.pillsFading)
        for _ in 0..<5 { try lab.probe.frame() }
        XCTAssertLessThan(lab.probe.applied.last!, pillsWidth, "closing on the countdown")

        let deadline = Date().addingTimeInterval(2)
        while !controller.model.phase.isEntering, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertFalse(controller.model.pillsFading)
        XCTAssertTrue(controller.model.focusVisible)
        XCTAssertEqual(controller.model.input.text(for: .hours), "2")
        XCTAssertEqual(controller.model.startError, MenuBarModel.startFailedText)
        XCTAssertGreaterThanOrEqual(lab.probe.target ?? 0, pillsWidth, "turned back to the pills, and the label on top")

        try lab.probe.land()
        XCTAssertTrue(controller.model.slotsPresent, "the landing of the cancelled close never fires")
        XCTAssertEqual(controller.model.startError, MenuBarModel.startFailedText)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        try? await Task.sleep(for: .milliseconds(100))
        try lab.probe.land()
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertGreaterThan(controller.widthTarget, pillsWidth, "the layout reported the label's extra")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
        controller.collapse()
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
