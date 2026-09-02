import AppKit
import SwiftUI

/// Single source of truth for every animation in the menu bar UI (spec 11).
///
/// Springs only. The one non-spring curve lives behind Reduce Motion, where
/// every movement collapses into a short crossfade with no scale.
@MainActor
enum Motion {
    /// Baseline for layout, width changes, pill morphs and the focus glow.
    static let base: Animation = .spring(response: 0.35, dampingFraction: 0.72)
    /// Focus bounce and chip taps: snappier, with a slight overshoot.
    static let snappy: Animation = .spring(response: 0.25, dampingFraction: 0.6)
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

    /// Insert/remove transition for a pill: scale-and-fade, or a plain fade
    /// under Reduce Motion.
    static func pillTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .scale(scale: 0.55, anchor: .leading).combined(with: .opacity)
    }
}
