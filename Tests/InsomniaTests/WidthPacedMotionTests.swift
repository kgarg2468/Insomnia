import AppKit
import XCTest
@testable import Insomnia

/// The paced width mover and the animator that drives it. The motion is
/// pure and stepped by hand; the animator is driven by calling its frame
/// callback directly, never by a running display link.
final class WidthPacedMotionTests: XCTestCase {
    // MARK: WidthPacedMotion

    /// Steps until landed, collecting every write. Stops early on a nil
    /// before landing so a stuck motion fails the assertions that follow.
    private func fly(_ motion: inout WidthPacedMotion, limit: Int = 1000) -> [CGFloat] {
        var writes: [CGFloat] = []
        while !motion.isSettled, writes.count < limit {
            guard let write = motion.step() else { break }
            writes.append(write)
        }
        return writes
    }

    private func deltas(from start: CGFloat, _ writes: [CGFloat]) -> [CGFloat] {
        zip([start] + writes, writes).map { $1 - $0 }
    }

    private func assertFlight(
        from start: CGFloat, to target: CGFloat, scale: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Int {
        var motion = WidthPacedMotion(value: start, target: target, scale: scale)
        let writes = fly(&motion)
        let unit = 1 / scale
        XCTAssertTrue(motion.isSettled, "lands", file: file, line: line)
        XCTAssertEqual(writes.last, target, "lands exactly", file: file, line: line)
        XCTAssertEqual(motion.value, target, file: file, line: line)
        XCTAssertNil(motion.step(), "nothing to do after landing", file: file, line: line)
        XCTAssertEqual(motion.value, target, file: file, line: line)
        let heading: CGFloat = target > start ? 1 : -1
        for delta in deltas(from: start, writes) {
            XCTAssertGreaterThan(delta * heading, 0, "monotonic, never repeats a value", file: file, line: line)
            XCTAssertLessThanOrEqual(delta * heading, WidthPacedMotion.maxStep, "never more than 3 pt", file: file, line: line)
        }
        for write in writes {
            XCTAssertLessThanOrEqual((write - target) * heading, 0, "never overshoots", file: file, line: line)
        }
        // Every in-flight write sits on the grid; only the landing may not
        // (the target is whatever the caller asked for).
        for write in writes.dropLast() {
            XCTAssertEqual(write.truncatingRemainder(dividingBy: unit), 0, accuracy: 1e-9, "on the grid", file: file, line: line)
        }
        return writes.count
    }

    func testTheUsualMovesLandExactlyWithoutOvershootAtBothScales() {
        for scale: CGFloat in [1, 2] {
            _ = assertFlight(from: 32, to: 226, scale: scale)
            _ = assertFlight(from: 226, to: 32, scale: scale)
            _ = assertFlight(from: 32, to: 148, scale: scale)   // 116 pt
            _ = assertFlight(from: 148, to: 32, scale: scale)
            _ = assertFlight(from: 32, to: 110, scale: scale)   // 78 pt
            _ = assertFlight(from: 110, to: 32, scale: scale)
        }
    }

    /// Ramp 1, 2, 3 then 3 pt per callback, easing in the last 18 pt: about
    /// 75 callbacks (0.62 s at 120 Hz) for the full open. Pinned so neither
    /// a slower cruise nor a longer tail slips in.
    func testTheFullOpenTakesBetween60And85Callbacks() {
        let callbacks = assertFlight(from: 32, to: 226, scale: 2)
        XCTAssertTrue((60...85).contains(callbacks), "\(callbacks) callbacks")
        let close = assertFlight(from: 226, to: 32, scale: 2)
        XCTAssertTrue((60...85).contains(close), "\(close) callbacks")
    }

    /// The step is a function of the callback count, never of time: there
    /// is no clock to feed, so a late callback advances exactly once.
    func testTheRampIsOneTwoThreeThenCruise() {
        var motion = WidthPacedMotion(value: 32, target: 226, scale: 2)
        XCTAssertEqual(motion.step(), 33)
        XCTAssertEqual(motion.step(), 35)
        XCTAssertEqual(motion.step(), 38)
        XCTAssertEqual(motion.step(), 41)
        XCTAssertEqual(motion.step(), 44)

        var narrowing = WidthPacedMotion(value: 226, target: 32, scale: 1)
        XCTAssertEqual(narrowing.step(), 225)
        XCTAssertEqual(narrowing.step(), 223)
        XCTAssertEqual(narrowing.step(), 220)
        XCTAssertEqual(narrowing.step(), 217)
    }

    /// Past the ramp, with `remaining` just above, at and below 18 pt.
    func testTheTailStartsBelow18Points() {
        func cruising(scale: CGFloat) -> WidthPacedMotion {
            var motion = WidthPacedMotion(value: 0, target: 1000, scale: scale)
            for _ in 0..<3 { _ = motion.step() }   // ramp done, value 6
            XCTAssertEqual(motion.value, 6)
            return motion
        }
        for scale: CGFloat in [1, 2] {
            var above = cruising(scale: scale)
            above.retarget(6 + 21)
            XCTAssertEqual(above.step(), 9, "21 pt to go: full step")

            var equal = cruising(scale: scale)
            equal.retarget(6 + 18)
            XCTAssertEqual(equal.step(), 9, "18 pt to go: still a full step")

            var below = cruising(scale: scale)
            below.retarget(6 + 12)
            XCTAssertEqual(below.step(), 8, "12 pt to go: 12 / 6 = 2")
        }
        var fractional = cruising(scale: 2)
        fractional.retarget(6 + 15)
        XCTAssertEqual(fractional.step(), 8.5, "15 pt to go: 15 / 6 = 2.5 on the half-point grid")
        var whole = cruising(scale: 1)
        whole.retarget(6 + 15)
        XCTAssertEqual(whole.step(), 9, "2.5 rounds up to the point grid toward the target")

        // The tail: 18 → 0.5 pt, each step raised to at least one grid unit.
        var tail = cruising(scale: 2)
        tail.retarget(6 + 17)
        let writes = fly(&tail)
        XCTAssertEqual(writes, [9, 11.5, 13.5, 15.5, 17, 18, 19, 20, 20.5, 21, 21.5, 22, 22.5, 23])
    }

    func testShortDistancesLandExactly() {
        for scale: CGFloat in [1, 2] {
            var still = WidthPacedMotion(value: 32, target: 32, scale: scale)
            XCTAssertTrue(still.isSettled)
            XCTAssertNil(still.step())

            for distance: CGFloat in [0.5, 1, 2, 3] {
                _ = assertFlight(from: 32, to: 32 + distance, scale: scale)
                _ = assertFlight(from: 32 + distance, to: 32, scale: scale)
            }
        }
        var half = WidthPacedMotion(value: 32, target: 32.5, scale: 2)
        XCTAssertEqual(fly(&half), [32.5])
        var one = WidthPacedMotion(value: 32, target: 33, scale: 2)
        XCTAssertEqual(fly(&one), [32.5, 33])
        var oneWhole = WidthPacedMotion(value: 32, target: 33, scale: 1)
        XCTAssertEqual(fly(&oneWhole), [33])
        var three = WidthPacedMotion(value: 32, target: 35, scale: 1)
        XCTAssertEqual(fly(&three), [33, 34, 35])
    }

    /// A width set unanimated can be anything; the flight starts from the
    /// grid, toward the target, so the first step is measured on the grid.
    func testAFractionalStartIsQuantizedTowardTheTarget() {
        var growing = WidthPacedMotion(value: 32.3, target: 226, scale: 2)
        XCTAssertEqual(growing.value, 32.5)
        XCTAssertEqual(growing.step(), 33.5)

        var narrowing = WidthPacedMotion(value: 226.3, target: 32, scale: 2)
        XCTAssertEqual(narrowing.value, 226)
        XCTAssertEqual(narrowing.step(), 225)

        var whole = WidthPacedMotion(value: 32.3, target: 226, scale: 1)
        XCTAssertEqual(whole.value, 33)
        XCTAssertEqual(whole.step(), 34)

        // Within a grid unit of the target the start is left alone and the
        // first step lands with a write, so the value is never silently
        // declared landed.
        var almost = WidthPacedMotion(value: 32.3, target: 32.5, scale: 2)
        XCTAssertEqual(almost.value, 32.3)
        XCTAssertFalse(almost.isSettled)
        XCTAssertEqual(almost.step(), 32.5)
        XCTAssertTrue(almost.isSettled)

        _ = assertFlight(from: 32.3, to: 226, scale: 2)
        _ = assertFlight(from: 225.7, to: 32, scale: 2)
    }

    /// Enter can land while the bar is still growing: nearer or farther in
    /// the same direction keeps the ramp where it is and the tail follows
    /// from the new distance.
    func testRetargetingInTheSameDirectionKeepsTheRamp() {
        var motion = WidthPacedMotion(value: 32, target: 226, scale: 2)
        XCTAssertEqual(motion.step(), 33)
        motion.retarget(150)   // nearer, during the ramp
        XCTAssertEqual(motion.value, 33, "a retarget never moves the value")
        XCTAssertEqual(motion.target, 150)
        XCTAssertEqual(motion.step(), 35, "the ramp continues at 2")
        motion.retarget(300)   // farther
        XCTAssertEqual(motion.step(), 38, "and at 3")
        XCTAssertEqual(motion.step(), 41)

        // During the cruise: nearer lands the tail from the new distance.
        motion.retarget(41 + 12)
        XCTAssertEqual(motion.step(), 43, "12 / 6 = 2")
        let writes = fly(&motion)
        XCTAssertEqual(writes.last, 53)

        // During the tail: farther goes straight back to the cruise step.
        var tail = WidthPacedMotion(value: 0, target: 30, scale: 2)
        for _ in 0..<8 { _ = tail.step() }   // 1, 2, 3, 3, 3, 3 → 15; then 15/6, 12.5/6
        XCTAssertLessThan(30 - tail.value, 18)
        let before = tail.value
        tail.retarget(300)
        XCTAssertEqual(tail.step(), before + 3)
    }

    /// A refusal while the bar is narrowing, or a click-away while it is
    /// growing: the ramp restarts from the value it has, so the width brakes
    /// in one frame and never overshoots.
    func testAReversalRestartsTheRampWithoutADiscontinuity() {
        var motion = WidthPacedMotion(value: 32, target: 226, scale: 2)
        for _ in 0..<10 { _ = motion.step() }
        XCTAssertEqual(motion.value, 59)
        motion.retarget(32)
        XCTAssertEqual(motion.value, 59, "position is continuous through the reversal")
        XCTAssertEqual(motion.step(), 58, "first step back is 1 pt")
        XCTAssertEqual(motion.step(), 56)
        XCTAssertEqual(motion.step(), 53)
        let writes = fly(&motion)
        XCTAssertEqual(writes.last, 32)
        for delta in deltas(from: 53, writes) {
            XCTAssertLessThan(delta, 0)
            XCTAssertGreaterThanOrEqual(delta, -3)
        }
        XCTAssertNil(motion.step())
    }

    func testATargetEqualToTheCurrentValueLandsAndARepeatedTargetIsANoOp() {
        var motion = WidthPacedMotion(value: 32, target: 226, scale: 2)
        _ = motion.step()
        motion.retarget(226)
        XCTAssertEqual(motion.target, 226)
        XCTAssertEqual(motion.step(), 35, "a repeated target does not reset the ramp")

        motion.retarget(35)
        XCTAssertTrue(motion.isSettled, "landed without a write")
        XCTAssertEqual(motion.value, 35)
        XCTAssertNil(motion.step())

        motion.retarget(226)
        XCTAssertEqual(motion.step(), 36, "a new flight ramps again")
    }

    // MARK: StatusWidthAnimator

    @MainActor
    private final class Fixture {
        var applied: [CGFloat] = []
        /// Writes and completions in the order they happened.
        var events: [String] = []
        var maximumFramesPerSecond: Int? = 120
        var reduceMotion = false
        var linkRequests = 0
        var linkless = false
        /// Reachable from `deinit`, which is not on the main actor.
        nonisolated(unsafe) var link: CADisplayLink?
        private(set) var animator: StatusWidthAnimator!

        init(scale: CGFloat = 2) {
            animator = StatusWidthAnimator(
                backingScale: { scale },
                maximumFramesPerSecond: { [unowned self] in maximumFramesPerSecond },
                reduceMotion: { [unowned self] in reduceMotion },
                makeLink: { [unowned self] target, selector in
                    linkRequests += 1
                    guard !linkless else { return nil }
                    // Paused: the tests step it by hand, no frame runs by itself.
                    link = NSScreen.main?.displayLink(target: target, selector: selector)
                    link?.isPaused = true
                    return link
                },
                apply: { [unowned self] width in
                    applied.append(width)
                    events.append("apply \(width)")
                }
            )
        }

        /// The link retains the animator, whose closures point back here
        /// unowned: a flight left in the air must not outlive the fixture.
        deinit {
            link?.invalidate()
        }

        func completion(_ name: String) -> () -> Void {
            { [unowned self] in events.append(name) }
        }

        func count(_ name: String) -> Int { events.filter { $0 == name }.count }

        /// Drives frames until the flight lands. Needs a screen for the link.
        func requireLink() throws {
            try XCTSkipUnless(link != nil, "no screen to make a display link from")
        }

        func frame() throws {
            try requireLink()
            animator.step(link!)
        }

        func land() throws -> Int {
            var frames = 0
            while animator.isAnimating, frames < 1000 {
                try frame()
                frames += 1
            }
            return frames
        }
    }

    @MainActor
    func testPacedNeedsAFastDisplayAndNoReduceMotion() throws {
        let f = Fixture()
        try XCTSkipUnless(NSScreen.main != nil, "no screen to make a display link from")
        XCTAssertTrue(f.animator.isPaced)
        f.maximumFramesPerSecond = 60
        XCTAssertFalse(f.animator.isPaced, "60 Hz is one-write")
        f.maximumFramesPerSecond = nil
        XCTAssertFalse(f.animator.isPaced, "unknown is one-write")
        f.maximumFramesPerSecond = 120
        f.reduceMotion = true
        XCTAssertFalse(f.animator.isPaced)
        f.reduceMotion = false
        XCTAssertTrue(f.animator.isPaced)
    }

    @MainActor
    func testTheFirstWidthAndAnUnanimatedWidthAreWrittenOnceAndCompleteAtOnce() {
        let f = Fixture()
        XCTAssertNil(f.animator.target)
        XCTAssertNil(f.animator.current)
        f.animator.setTarget(32, animated: true, completion: f.completion("first"))
        XCTAssertEqual(f.events, ["apply 32.0", "first"], "the first width is written once, then completes")
        XCTAssertEqual(f.animator.target, 32)
        XCTAssertEqual(f.animator.current, 32)
        XCTAssertFalse(f.animator.isAnimating)

        f.animator.setTarget(226, animated: false, completion: f.completion("snap"))
        XCTAssertEqual(f.events, ["apply 32.0", "first", "apply 226.0", "snap"])
        XCTAssertEqual(f.linkRequests, 0)
        XCTAssertFalse(f.animator.isAnimating)
        XCTAssertEqual(f.animator.current, 226)
    }

    @MainActor
    func testWithoutALinkOrAFastDisplayTheWidthIsWrittenOnce() {
        let linkless = Fixture()
        linkless.linkless = true
        linkless.animator.setTarget(32, animated: false)
        linkless.animator.setTarget(226, animated: true, completion: linkless.completion("done"))
        XCTAssertEqual(linkless.events, ["apply 32.0", "apply 226.0", "done"])
        XCTAssertEqual(linkless.linkRequests, 1, "it asked for a link and got none")
        XCTAssertFalse(linkless.animator.isAnimating)

        let slow = Fixture()
        slow.maximumFramesPerSecond = 60
        slow.animator.setTarget(32, animated: false)
        slow.animator.setTarget(226, animated: true, completion: slow.completion("done"))
        XCTAssertEqual(slow.events, ["apply 32.0", "apply 226.0", "done"])
        XCTAssertEqual(slow.linkRequests, 0, "one-write never asks for a link")

        let reduced = Fixture()
        reduced.reduceMotion = true
        reduced.animator.setTarget(32, animated: false)
        reduced.animator.setTarget(226, animated: true, completion: reduced.completion("done"))
        XCTAssertEqual(reduced.events, ["apply 32.0", "apply 226.0", "done"])
        XCTAssertEqual(reduced.linkRequests, 0)
    }

    /// A fast display with Reduce Motion off, but no link to pace with:
    /// `isPaced` must say one-write, since a flight would be written once
    /// (and complete before `setTarget` returns), and the controller must
    /// not choreograph a paced close over a snap. The check probes for a
    /// link every time (the screen can change) and never leaves one
    /// running: the probe is invalidated at once, which is what releases
    /// its target.
    @MainActor
    func testPacedNeedsALinkWhichTheProbeNeverLeavesRunning() throws {
        let f = Fixture()
        f.linkless = true
        XCTAssertFalse(f.animator.isPaced, "no link: one-write despite 120 Hz and Reduce Motion off")
        XCTAssertEqual(f.linkRequests, 1, "it asked for a link and got none")
        XCTAssertFalse(f.animator.isAnimating)
        f.animator.setTarget(32, animated: false)
        var completedBeforeReturn = false
        f.animator.setTarget(226, animated: true) { [unowned f] in
            completedBeforeReturn = true
            f.events.append("done")
        }
        XCTAssertTrue(completedBeforeReturn, "the completion ran inside setTarget")
        XCTAssertEqual(f.events, ["apply 32.0", "apply 226.0", "done"])
        XCTAssertFalse(f.animator.isAnimating)
        XCTAssertEqual(f.animator.current, 226)

        f.linkless = false
        try XCTSkipUnless(NSScreen.main != nil, "no screen to make a display link from")
        let requests = f.linkRequests
        XCTAssertTrue(f.animator.isPaced, "a link can be made: paced")
        XCTAssertEqual(f.linkRequests, requests + 1, "probed for a link")
        XCTAssertFalse(f.animator.isAnimating, "the probe is not a flight")
        XCTAssertTrue(f.animator.isPaced, "probed again: the answer is not cached")
        XCTAssertEqual(f.linkRequests, requests + 2)
        XCTAssertFalse(f.animator.isAnimating)

        // The probe was invalidated: an invalidated link releases its
        // target, so an animator held only by its probes is freed.
        var probes: [CADisplayLink] = []
        weak var released: StatusWidthAnimator?
        autoreleasepool {
            let animator = StatusWidthAnimator(
                backingScale: { 2 },
                maximumFramesPerSecond: { 120 },
                reduceMotion: { false },
                makeLink: { target, selector in
                    let link = NSScreen.main!.displayLink(target: target, selector: selector)
                    probes.append(link)
                    return link
                },
                apply: { _ in }
            )
            released = animator
            XCTAssertTrue(animator.isPaced)
            XCTAssertFalse(animator.isAnimating)
        }
        XCTAssertEqual(probes.count, 1)
        XCTAssertNil(released, "the probe link was invalidated and let its target go")
    }

    /// The mode is decided once per flight. A display that starts
    /// reporting 60 Hz (a window move, Low Power Mode) or a Reduce Motion
    /// reading that flips without the notification must not turn the next
    /// retarget of a paced flight into a snap; only the landing ends the
    /// flight, and the flight after that is one-write.
    @MainActor
    func testTheModeIsLatchedWhenAFlightStartsAndReadAgainForTheNext() throws {
        let f = Fixture()
        f.animator.setTarget(32, animated: false)
        f.animator.setTarget(226, animated: true, completion: f.completion("open"))
        try f.requireLink()
        for _ in 0..<5 { try f.frame() }
        XCTAssertEqual(f.animator.current, 44)

        f.maximumFramesPerSecond = 60
        XCTAssertFalse(f.animator.isPaced, "a flight started now would be one-write")
        f.animator.setTarget(150, animated: true, completion: f.completion("enter"))
        XCTAssertTrue(f.animator.isAnimating, "the flight in the air stays paced")
        XCTAssertEqual(f.applied.last, 44, "no snap")
        XCTAssertEqual(f.count("open"), 0)
        XCTAssertEqual(f.count("enter"), 0)
        try f.frame()
        XCTAssertEqual(f.applied.last, 47, "still 3 pt per frame")

        // The Reduce Motion reading flipping without the notification does
        // not snap either; the notification path is the one override.
        f.reduceMotion = true
        f.animator.setTarget(120, animated: true, completion: f.completion("nearer"))
        XCTAssertTrue(f.animator.isAnimating)
        XCTAssertEqual(f.applied.last, 47)
        f.reduceMotion = false

        let frames = try f.land()
        XCTAssertGreaterThan(frames, 1, "\(frames) frames: paced to the end")
        XCTAssertEqual(f.applied.last, 120)
        XCTAssertEqual(f.count("enter"), 0, "dropped by the retarget")
        XCTAssertEqual(f.count("nearer"), 1)
        XCTAssertFalse(f.animator.isAnimating)
        XCTAssertEqual(f.linkRequests, 1)

        // Landed: the next flight reads the mode afresh, and at 60 Hz that
        // is one write.
        let written = f.applied.count
        f.animator.setTarget(32, animated: true, completion: f.completion("close"))
        XCTAssertFalse(f.animator.isAnimating)
        XCTAssertEqual(f.applied.count, written + 1, "one write")
        XCTAssertEqual(f.events.suffix(2), ["apply 32.0", "close"])
        XCTAssertEqual(f.linkRequests, 1, "one-write never asked for a link")

        // And back at 120 Hz the flight after that is paced again.
        f.maximumFramesPerSecond = 120
        f.animator.setTarget(226, animated: true, completion: f.completion("reopen"))
        try f.requireLink()
        XCTAssertTrue(f.animator.isAnimating)
        XCTAssertEqual(f.linkRequests, 2)
        _ = try f.land()
        XCTAssertEqual(f.count("reopen"), 1)
    }

    @MainActor
    func testAnAlreadyLandedTargetCompletesOnceWithoutAWrite() {
        let f = Fixture()
        f.animator.setTarget(32, animated: false)
        f.animator.setTarget(32, animated: true, completion: f.completion("again"))
        XCTAssertEqual(f.events, ["apply 32.0", "again"])
        f.animator.setTarget(32, animated: false, completion: f.completion("snap"))
        XCTAssertEqual(f.events, ["apply 32.0", "again", "snap"], "no duplicate write, still one completion each")
        XCTAssertEqual(f.linkRequests, 0)
        XCTAssertFalse(f.animator.isAnimating)
    }

    @MainActor
    func testAPacedFlightStepsToTheTargetStopsTheLinkAndCompletesAfterTheLastWrite() throws {
        let f = Fixture()
        f.animator.setTarget(32, animated: false)
        f.animator.setTarget(226, animated: true, completion: f.completion("landed"))
        try f.requireLink()
        XCTAssertTrue(f.animator.isAnimating)
        XCTAssertEqual(f.applied, [32], "a retarget alone writes nothing")
        XCTAssertEqual(f.animator.target, 226)
        XCTAssertEqual(f.animator.current, 32)

        let frames = try f.land()
        XCTAssertFalse(f.animator.isAnimating, "the link is invalidated on landing")
        XCTAssertTrue((60...85).contains(frames), "\(frames) frames")
        XCTAssertEqual(f.applied.last, 226)
        XCTAssertEqual(f.animator.current, 226)
        XCTAssertEqual(f.events.suffix(2), ["apply 226.0", "landed"], "the completion runs after the final write")
        XCTAssertEqual(f.count("landed"), 1)
        XCTAssertEqual(f.applied.count, frames + 1, "one write per frame, none skipped, none repeated")
        for (a, b) in zip(f.applied, f.applied.dropFirst()) {
            XCTAssertGreaterThan(b, a)
            XCTAssertLessThanOrEqual(b - a, 3)
        }

        // Another frame after landing does nothing.
        let written = f.applied.count
        try f.frame()
        XCTAssertEqual(f.applied.count, written)
        XCTAssertEqual(f.count("landed"), 1)
    }

    @MainActor
    func testARetargetReusesTheLinkAndDropsThePendingCompletion() throws {
        let f = Fixture()
        f.animator.setTarget(32, animated: false)
        f.animator.setTarget(226, animated: true, completion: f.completion("open"))
        try f.requireLink()
        for _ in 0..<5 { try f.frame() }
        XCTAssertEqual(f.animator.current, 44)

        f.animator.setTarget(150, animated: true, completion: f.completion("enter"))
        XCTAssertEqual(f.linkRequests, 1, "the running link is reused")
        XCTAssertTrue(f.animator.isAnimating)
        XCTAssertEqual(f.animator.current, 44)
        XCTAssertEqual(f.applied.last, 44, "a retarget writes nothing by itself")

        _ = try f.land()
        XCTAssertEqual(f.applied.last, 150)
        XCTAssertEqual(f.count("open"), 0, "dropped, never called")
        XCTAssertEqual(f.count("enter"), 1)
        XCTAssertEqual(f.events.last, "enter")
        XCTAssertFalse(f.animator.isAnimating)

        // A reversal mid-flight brakes in one frame.
        f.animator.setTarget(32, animated: true, completion: f.completion("close"))
        for _ in 0..<5 { try f.frame() }
        XCTAssertEqual(f.animator.current, 138)
        f.animator.setTarget(226, animated: true, completion: f.completion("reopen"))
        try f.frame()
        XCTAssertEqual(f.applied.last, 139)
        _ = try f.land()
        XCTAssertEqual(f.applied.last, 226)
        XCTAssertEqual(f.count("close"), 0)
        XCTAssertEqual(f.count("reopen"), 1)
    }

    @MainActor
    func testARetargetToTheCurrentWidthLandsAtOnceWithoutAWrite() throws {
        let f = Fixture()
        f.animator.setTarget(32, animated: false)
        f.animator.setTarget(226, animated: true, completion: f.completion("open"))
        try f.requireLink()
        for _ in 0..<5 { try f.frame() }
        let written = f.applied.count
        f.animator.setTarget(f.animator.current!, animated: true, completion: f.completion("stay"))
        XCTAssertFalse(f.animator.isAnimating, "the link stops")
        XCTAssertEqual(f.applied.count, written, "no write")
        XCTAssertEqual(f.count("open"), 0)
        XCTAssertEqual(f.count("stay"), 1)
        XCTAssertEqual(f.animator.target, 44)
    }

    @MainActor
    func testReduceMotionTurningOnMidFlightSnapsToTheTarget() throws {
        let f = Fixture()
        f.animator.setTarget(32, animated: false)
        f.animator.setTarget(226, animated: true, completion: f.completion("open"))
        try f.requireLink()
        for _ in 0..<5 { try f.frame() }
        let written = f.applied.count

        f.reduceMotion = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertFalse(f.animator.isAnimating)
        XCTAssertEqual(f.applied.count, written + 1, "one write, to the target")
        XCTAssertEqual(f.applied.last, 226)
        XCTAssertEqual(f.events.suffix(2), ["apply 226.0", "open"])
        XCTAssertEqual(f.animator.current, 226)

        // Nothing more happens for the notification when not in flight, and
        // the next flight is one-write.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(f.count("open"), 1)
        f.animator.setTarget(32, animated: true, completion: f.completion("close"))
        XCTAssertEqual(f.events.suffix(2), ["apply 32.0", "close"])
        XCTAssertFalse(f.animator.isAnimating)
    }
}
