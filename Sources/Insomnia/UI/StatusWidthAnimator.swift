import AppKit
import QuartzCore
import SwiftUI

/// The spring that carries a width from wherever it is to a target. Pure
/// state stepping with no AppKit in it: `StatusWidthAnimator` drives it from
/// a display link and the tests step it by hand.
///
/// The curve is SwiftUI's own `Spring`, evaluated in closed form from the
/// moment of the last retarget. A retarget mid-flight re-bases the spring on
/// the value and velocity it has right then, so the width bends towards the
/// new target without a jump in position or speed.
nonisolated struct WidthSpringMotion {
    /// Closer than this to the target, and slower than `restVelocity`, the
    /// motion snaps to the target and stops.
    static let restDistance: CGFloat = 0.25
    /// Points per second.
    static let restVelocity: CGFloat = 1

    let spring: Spring
    private(set) var value: CGFloat
    /// Points per second.
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat

    private var origin: CGFloat
    private var originVelocity: CGFloat = 0
    /// Seconds since the last retarget.
    private var elapsed: TimeInterval = 0

    init(spring: Spring, value: CGFloat) {
        self.spring = spring
        self.value = value
        self.target = value
        self.origin = value
    }

    var isSettled: Bool { value == target && velocity == 0 }

    /// Head for `newTarget` from the current value and velocity.
    mutating func retarget(_ newTarget: CGFloat) {
        guard newTarget != target else { return }
        origin = value
        originVelocity = velocity
        elapsed = 0
        target = newTarget
    }

    /// Move `dt` seconds along the curve. Time-based, not step-based: a
    /// dropped frame is caught up on the next one rather than slowing the
    /// motion down.
    mutating func advance(by dt: TimeInterval) {
        guard !isSettled else { return }
        elapsed += max(dt, 0)
        let span = target - origin
        value = origin + spring.value(target: span, initialVelocity: originVelocity, time: elapsed)
        velocity = spring.velocity(target: span, initialVelocity: originVelocity, time: elapsed)
        if abs(value - target) < Self.restDistance, abs(velocity) < Self.restVelocity {
            value = target
            velocity = 0
        }
    }
}

/// Animates `NSStatusItem.length` with a display link.
///
/// macOS re-lays out the whole menu bar on every change of a status item's
/// length, but a measured set costs about 0.5 ms and holds 120 Hz, so the
/// width is driven here, one set per frame, decoupled from SwiftUI layout:
/// the content is laid out once at its final width and the item's window
/// reveals or clips it as the length springs.
///
/// The link only runs while a width is in flight; it is invalidated the
/// moment the spring settles. With `animated: false` (Reduce Motion, or the
/// very first width) the length is set at once.
@MainActor
final class StatusWidthAnimator: NSObject {
    typealias LinkFactory = (_ target: AnyObject, _ selector: Selector) -> CADisplayLink?

    private let spring: Spring
    private let backingScale: () -> CGFloat
    private let makeLink: LinkFactory
    private let apply: (CGFloat) -> Void
    private var link: CADisplayLink?
    private var motion: WidthSpringMotion?
    private var lastTimestamp: CFTimeInterval = 0

    /// - Parameters:
    ///   - backingScale: pixels per point of the screen the item is on; the
    ///     in-flight width is rounded to it so no frame lands between pixels.
    ///   - makeLink: a display link for the screen the item is on, or nil
    ///     when there is none (the width then snaps).
    ///   - apply: sets the length. Called once per frame while in flight,
    ///     and once more with the exact target when the spring settles.
    init(
        spring: Spring = Motion.widthSpring,
        backingScale: @escaping () -> CGFloat,
        makeLink: @escaping LinkFactory,
        apply: @escaping (CGFloat) -> Void
    ) {
        self.spring = spring
        self.backingScale = backingScale
        self.makeLink = makeLink
        self.apply = apply
    }

    /// The width heading for (or resting at), if one has been set.
    var target: CGFloat? { motion?.target }
    /// The width the item has right now, if one has been set.
    var current: CGFloat? { motion?.value }
    var isAnimating: Bool { link != nil }

    /// Head for `width`. Animated from wherever the width is and however
    /// fast it is moving, unless `animated` is false or no width has been
    /// set yet, in which case the width is applied at once.
    func setTarget(_ width: CGFloat, animated: Bool) {
        guard animated, var motion else {
            stop()
            self.motion = WidthSpringMotion(spring: spring, value: width)
            apply(width)
            return
        }
        motion.retarget(width)
        self.motion = motion
        if motion.isSettled {
            stop()
            apply(width)
            return
        }
        if link == nil {
            guard let link = makeLink(self, #selector(step(_:))) else {
                snap(to: width)
                return
            }
            lastTimestamp = CACurrentMediaTime()
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private func snap(to width: CGFloat) {
        stop()
        motion = WidthSpringMotion(spring: spring, value: width)
        apply(width)
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard var motion else {
            stop()
            return
        }
        // The value for the frame about to be shown, not the one just past.
        let now = link.targetTimestamp
        motion.advance(by: now - lastTimestamp)
        lastTimestamp = now
        self.motion = motion
        if motion.isSettled {
            stop()
            apply(motion.value)
        } else {
            let scale = max(backingScale(), 1)
            apply((motion.value * scale).rounded() / scale)
        }
    }
}
