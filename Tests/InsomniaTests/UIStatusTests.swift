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

    @MainActor
    func testTickAnimationIsShorterThanBaseAndHoldIsSubSecond() {
        XCTAssertEqual(Motion.holdDuration, 0.6, accuracy: 0.0001)
        XCTAssertLessThan(Motion.holdDuration, 1)
        XCTAssertEqual(Motion.tick(reduceMotion: true), Motion.reduced)
        XCTAssertNotEqual(Motion.tick(reduceMotion: false), Motion.base)
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
            SleepHeldLine.Line(text: "Sleep held \u{2014} safe to close the lid", isWarning: false)
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
            StatusMenu.Item(title: "Sleep held \u{2014} safe to close the lid", kind: .info),
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
    }
}
