import AppKit
import QuartzCore

/// The paced mover that carries a width from wherever it is to a target.
/// Pure state stepping with no AppKit and no clock in it: `StatusWidthAnimator`
/// steps it once per display-link callback and the tests step it by hand.
///
/// Frames pace the motion, not time. Control Center relays writes of about
/// 3 pt per frame frame by frame, but larger writes (which a time-based
/// curve produces whenever our callback stalls in the render server) can
/// end in a half-second freeze and one cut to the final layout. So every
/// callback moves by at most `maxStep`, whatever the elapsed time: a stalled
/// frame delays the animation by the stall and never produces a jump.
///
/// The step is `min(maxStep, ramp, tail)`: the ramp is 1, 2, 3 pt for the
/// first three callbacks of a flight (and after a reversal), the tail is
/// `remaining / 6` once fewer than 18 pt remain. The step is never smaller
/// than one grid unit (`1 / scale`), every applied value is rounded to the
/// grid toward the target, and the cap is enforced against the previously
/// applied value after that rounding.
nonisolated struct WidthPacedMotion: Sendable {
    /// The most any single write may move the width, in points.
    static let maxStep: CGFloat = 3
    /// Points to go below which the step eases down as `remaining / tailDivisor`.
    static let tailDistance: CGFloat = 6 * maxStep
    static let tailDivisor: CGFloat = 6
    /// The step on the n-th callback of a flight is at most `min(n, rampLength)`.
    static let rampLength = 3

    /// The last applied (grid-quantized) value.
    private(set) var value: CGFloat
    private(set) var target: CGFloat
    /// Pixels per point: the grid every applied value sits on.
    let scale: CGFloat
    /// Callbacks taken since the flight started or last reversed.
    private var callbacks = 0

    /// - Parameters:
    ///   - value: where the width is now. Off-grid values are quantized
    ///     toward `target` first, so the first step is measured on the grid.
    ///   - scale: the backing scale (1 or 2); the grid unit is its inverse.
    init(value: CGFloat, target: CGFloat, scale: CGFloat) {
        self.scale = max(scale, 1)
        self.value = value
        self.target = target
        alignStart()
    }

    var isSettled: Bool { value == target }

    private var unit: CGFloat { 1 / scale }

    /// Head for `newTarget` from the current value. Same direction keeps
    /// the ramp where it is and the tail follows from the new distance; a
    /// reversal restarts the ramp, so the width brakes in one frame and
    /// cannot overshoot. A target equal to the value lands at once.
    mutating func retarget(_ newTarget: CGFloat) {
        guard newTarget != target else { return }
        let wasHeading = heading
        target = newTarget
        if heading != wasHeading { callbacks = 0 }
        alignStart()
    }

    /// One display-link callback. Returns the value to apply, or nil when
    /// nothing needs writing: already settled, or the quantized value is the
    /// one already applied.
    mutating func step() -> CGFloat? {
        let heading = heading
        guard heading != 0 else { return nil }
        let remaining = abs(target - value)
        let ramp = CGFloat(min(callbacks + 1, Self.rampLength))
        let tail = remaining < Self.tailDistance ? remaining / Self.tailDivisor : Self.maxStep
        let step = max(min(Self.maxStep, ramp, tail), unit)
        callbacks += 1

        var next: CGFloat
        if remaining <= step {
            next = target
        } else {
            next = Self.quantize(value + heading * step, toward: target, scale: scale)
            if abs(next - value) > Self.maxStep {
                next = value + heading * Self.maxStep
            }
            if heading * (target - next) <= 0 {
                next = target
            }
        }
        if next == target { callbacks = 0 }
        guard next != value else { return nil }
        value = next
        return next
    }

    /// +1 growing, -1 narrowing, 0 at rest.
    private var heading: CGFloat {
        target > value ? 1 : target < value ? -1 : 0
    }

    /// Put an off-grid start on the grid, toward the target, unless that
    /// would reach the target: then the first step lands it with a write.
    private mutating func alignStart() {
        let aligned = Self.quantize(value, toward: target, scale: scale)
        guard aligned != value, heading * (target - aligned) > 0 else { return }
        value = aligned
    }

    /// `v` rounded to the grid in the direction of `target`.
    private static func quantize(_ v: CGFloat, toward target: CGFloat, scale: CGFloat) -> CGFloat {
        let scaled = v * scale
        let grid = v < target ? scaled.rounded(.up) : v > target ? scaled.rounded(.down) : scaled
        return grid / scale
    }
}

/// Animates `NSStatusItem.length` from a display link.
///
/// macOS re-lays out the whole menu bar on every change of a status item's
/// length, and Control Center follows small per-frame writes smoothly but
/// large ones badly (see `WidthPacedMotion`), so the width is driven here,
/// one paced set per frame, decoupled from SwiftUI layout: the content is
/// laid out once at its final width and the item's window reveals or clips
/// it as the length moves.
///
/// Pacing is only verified at 120 Hz. On slower displays, under Reduce
/// Motion, with `animated: false`, before any width has been set, or when
/// no link can be made, the length is written once (one-write mode) and the
/// neighbours jump once, as they do for every Apple item. The mode is
/// decided when a flight starts, so a display or Low Power Mode change takes
/// effect on the next flight. The link only runs while a width is in flight.
@MainActor
final class StatusWidthAnimator: NSObject {
    typealias LinkFactory = (_ target: AnyObject, _ selector: Selector) -> CADisplayLink?

    /// The slowest display pacing is verified on (120 Hz ProMotion).
    static let pacedMinimumFramesPerSecond = 100

    private let backingScale: () -> CGFloat
    private let maximumFramesPerSecond: () -> Int?
    private let reduceMotion: () -> Bool
    private let makeLink: LinkFactory
    private let apply: (CGFloat) -> Void
    private var link: CADisplayLink?
    private var motion: WidthPacedMotion?
    private var lastApplied: CGFloat?
    private var completion: (() -> Void)?
    private nonisolated(unsafe) var reduceMotionObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - backingScale: pixels per point of the screen the item is on; every
    ///     in-flight width sits on that grid so no frame lands between pixels.
    ///   - maximumFramesPerSecond: the refresh rate of that screen, or nil
    ///     when unknown (then one-write).
    ///   - reduceMotion: the accessibility setting; read when a flight starts
    ///     and again when the system reports it changed.
    ///   - makeLink: a display link for that screen, or nil when there is
    ///     none (then one-write).
    ///   - apply: sets the length. Called at most once per frame while in
    ///     flight, the last time with the exact target; never twice with the
    ///     same value in a row.
    init(
        backingScale: @escaping () -> CGFloat,
        maximumFramesPerSecond: @escaping () -> Int?,
        reduceMotion: @escaping () -> Bool,
        makeLink: @escaping LinkFactory,
        apply: @escaping (CGFloat) -> Void
    ) {
        self.backingScale = backingScale
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.reduceMotion = reduceMotion
        self.makeLink = makeLink
        self.apply = apply
        super.init()
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.accessibilityDisplayOptionsDidChange() }
            } else {
                Task { @MainActor in self?.accessibilityDisplayOptionsDidChange() }
            }
        }
    }

    deinit {
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        }
    }

    /// Whether a flight started now would be paced rather than one-write:
    /// Reduce Motion off, a display of at least `pacedMinimumFramesPerSecond`,
    /// and a display link to pace it with. The controller reads this to
    /// choose its choreography, which must never see "paced" and then get a
    /// snap: with no link `setTarget` writes at once, which would cut the
    /// bar across content the paced choreography leaves visible. So a link
    /// is probed for (made and invalidated, never run) whenever none is in
    /// flight; the answer is not cached, since the screen can change.
    var isPaced: Bool {
        guard pacedConditionsHold else { return false }
        if link != nil { return true }
        guard let probe = makeLink(self, #selector(step(_:))) else { return false }
        probe.invalidate()
        return true
    }

    /// The settings half of `isPaced`: Reduce Motion off and a fast display.
    private var pacedConditionsHold: Bool {
        !reduceMotion() && (maximumFramesPerSecond() ?? 0) >= Self.pacedMinimumFramesPerSecond
    }

    /// The width heading for (or resting at), if one has been set.
    var target: CGFloat? { motion?.target }
    /// The width last applied, if one has been set.
    var current: CGFloat? { motion?.value }
    var isAnimating: Bool { link != nil }

    /// Head for `width`. Paced from wherever the width is when `animated`
    /// and the flight is paced; otherwise written once. `completion` runs
    /// once when `width` has landed: synchronously, with no extra write, if
    /// it already has (or is written at once); after the final write of a
    /// paced flight otherwise. It replaces any pending completion, which is
    /// dropped, not called: the caller retargeted, so the old landing never
    /// happens.
    ///
    /// The mode is latched when the flight starts (the link is made) and
    /// kept through every retarget until it lands or is stopped, so a
    /// refresh-rate or Reduce Motion reading that changes mid-flight cannot
    /// snap a flight that began paced. Reduce Motion turning on is the one
    /// mid-flight override, through the notification, which snaps.
    func setTarget(_ width: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        self.completion = completion
        // The settings alone decide here: the link is made below, once, and
        // its absence snaps (`isPaced` probes for it so the caller knows).
        guard animated, var motion, isAnimating || pacedConditionsHold else {
            snap(to: width)
            return
        }
        motion.retarget(width)
        self.motion = motion
        if motion.isSettled {
            stop()
            finish()
            return
        }
        if link == nil {
            guard let link = makeLink(self, #selector(step(_:))) else {
                snap(to: width)
                return
            }
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// One-write: land on `width` now.
    private func snap(to width: CGFloat) {
        stop()
        motion = WidthPacedMotion(value: width, target: width, scale: backingScale())
        write(width)
        finish()
    }

    private func write(_ width: CGFloat) {
        guard width != lastApplied else { return }
        lastApplied = width
        apply(width)
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    private func finish() {
        let completion = completion
        self.completion = nil
        completion?()
    }

    /// Reduce Motion turning on mid-flight ends the flight where it was
    /// going; turning off changes nothing until the next flight.
    private func accessibilityDisplayOptionsDidChange() {
        guard link != nil, reduceMotion(), let target = motion?.target else { return }
        snap(to: target)
    }

    /// One frame. Internal so the tests can drive it without a run loop.
    @objc func step(_ link: CADisplayLink) {
        guard var motion else {
            stop()
            return
        }
        let next = motion.step()
        self.motion = motion
        if let next { write(next) }
        if motion.isSettled {
            stop()
            finish()
        }
    }
}
