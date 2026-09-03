import AppKit
import SwiftUI

/// Single source of truth for every animation in the menu bar UI (spec 11).
///
/// Springs only. The one non-spring curve lives behind Reduce Motion, where
/// every movement collapses into a short crossfade with no scale.
@MainActor
enum Motion {
    static let baseResponse: TimeInterval = 0.35
    static let baseDampingFraction = 0.72
    /// Long enough for the width spring to become visually stationary.
    static let widthSettleDuration: TimeInterval = baseResponse * 2
    /// Baseline for layout, width changes, pill morphs and the focus glow.
    static let base: Animation = .spring(response: baseResponse, dampingFraction: baseDampingFraction)
    /// Focus bounce and chip taps: snappier, with a slight overshoot.
    static let snappy: Animation = .spring(response: 0.25, dampingFraction: 0.6)
    /// One digit roll of the 1 Hz countdown; must settle well inside a second.
    static let tick: Animation = .spring(response: 0.18, dampingFraction: 0.85)
    /// How long the end button must be held before the session ends.
    static let holdDuration: TimeInterval = 0.6
    /// Delay between consecutive pills appearing (reversed on collapse).
    static let stagger: TimeInterval = 0.04
    /// Scale a focused pill or tapped chip overshoots to before settling.
    static let overshoot: CGFloat = 1.06
    /// Reduce Motion replacement for every spring.
    static let reduced: Animation = .easeInOut(duration: 0.15)

    /// System Reduce Motion setting, read live so toggling it in System
    /// Settings takes effect on the next animation.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func base(reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? reduced : base
    }

    static func snappy(reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? reduced : snappy
    }

    static func tick(reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? reduced : tick
    }

    /// Delay for pill `index` of `count` when expanding (`reversed == false`)
    /// or collapsing (`reversed == true`). Zero under Reduce Motion.
    static func staggerDelay(index: Int, count: Int, reversed: Bool, reduceMotion: Bool = Motion.reduceMotion) -> TimeInterval {
        guard !reduceMotion, count > 0 else { return 0 }
        let position = reversed ? (count - 1 - index) : index
        return Double(max(position, 0)) * stagger
    }

    /// Overshoot scale for a bounce, 1.0 under Reduce Motion.
    static func bounceScale(reduceMotion: Bool = Motion.reduceMotion) -> CGFloat {
        reduceMotion ? 1 : overshoot
    }

    /// Unit progress for the same under-damped spring used by SwiftUI. AppKit
    /// has no spring animator for `NSStatusItem.length`, so the controller
    /// samples this curve at display cadence to move neighbouring items
    /// continuously instead of jumping between intrinsic widths.
    static func springProgress(elapsed: TimeInterval) -> CGFloat {
        guard elapsed > 0 else { return 0 }
        guard elapsed < widthSettleDuration else { return 1 }
        let damping = baseDampingFraction
        let undampedFrequency = 2 * Double.pi / baseResponse
        let dampedRoot = sqrt(1 - damping * damping)
        let dampedFrequency = undampedFrequency * dampedRoot
        let envelope = exp(-damping * undampedFrequency * elapsed)
        let wave = cos(dampedFrequency * elapsed)
            + damping / dampedRoot * sin(dampedFrequency * elapsed)
        return CGFloat(1 - envelope * wave)
    }

    /// Insert/remove transition for a pill: scale-and-fade, or a plain fade
    /// under Reduce Motion.
    static func pillTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .scale(scale: 0.55, anchor: .leading).combined(with: .opacity)
    }
}
