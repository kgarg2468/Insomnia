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
    /// Baseline for layout, pill morphs and the focus ring.
    static let base: Animation = .spring(response: baseResponse, dampingFraction: baseDampingFraction)
    /// Focus bounce and icon taps: snappier, with a slight overshoot.
    static let snappy: Animation = .spring(response: 0.25, dampingFraction: 0.6)
    /// One digit roll of the 1 Hz countdown; must settle well inside a second.
    static let tick: Animation = .spring(response: 0.18, dampingFraction: 0.85)
    /// How long the end button must be held before the session ends.
    static let holdDuration: TimeInterval = 0.6
    /// Delay between consecutive pills appearing (reversed on collapse).
    static let stagger: TimeInterval = 0.04
    /// Scale a focused pill overshoots to before settling.
    static let overshoot: CGFloat = 1.06
    /// Reduce Motion replacement for every spring.
    static let reduced: Animation = .easeInOut(duration: 0.15)
    /// How long after the last pill starts retracting the slots leave the
    /// layout: the base spring has faded it out by then, so nothing visible
    /// is removed.
    static let retractSettleDuration: TimeInterval = 0.20
    static let reducedRetractSettleDuration: TimeInterval = 0.15

    static func retractSettle(reduceMotion: Bool = Motion.reduceMotion) -> TimeInterval {
        reduceMotion ? reducedRetractSettleDuration : retractSettleDuration
    }

    /// The status item's width, driven by `StatusWidthAnimator` rather than
    /// SwiftUI: slower than `base` and damped almost to critical, so the bar
    /// grows and narrows without a visible overshoot against its neighbours.
    static let widthResponse: TimeInterval = 0.45
    static let widthDampingRatio = 0.92
    static let widthSpring = Spring(response: widthResponse, dampingRatio: widthDampingRatio)
    /// How long after a retract begins the width starts narrowing: the pills
    /// furthest from the mark are mostly gone by then, so the bar's edge
    /// never crosses a pill that is still solid. Not used under Reduce
    /// Motion, where the width snaps once the slots have left.
    static let narrowDelay: TimeInterval = 0.10

    /// The eye's blink. Slow enough that the lid lift and the lash hand-over
    /// read as a blink rather than a flicker (about 0.6 s to settle).
    static let blinkResponse: TimeInterval = 0.7
    static let blinkDampingFraction = 0.9
    static let blink: Animation = .spring(response: blinkResponse, dampingFraction: blinkDampingFraction)
    static let reducedBlinkDuration: TimeInterval = 0.3
    static let reducedBlink: Animation = .easeInOut(duration: reducedBlinkDuration)

    static func blink(reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? reducedBlink : blink
    }

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

    /// Insertion transition for a pill slot born already shown: scale-and-fade,
    /// or a plain fade under Reduce Motion. The same shape `StatusRootView`
    /// drives by hand for the stagger.
    static func pillTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        reveal(scale: 0.55, anchor: .leading, reduceMotion: reduceMotion)
    }

    /// The countdown scaling in from (and out to) the mark's edge.
    static func countdownTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        reveal(scale: 0.7, anchor: .leading, reduceMotion: reduceMotion)
    }

    /// The hold-to-end ring growing in place.
    static func ringTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        reveal(scale: 0.5, anchor: .center, reduceMotion: reduceMotion)
    }

    /// The start-failed label: a fade in both modes.
    static func errorTransition(reduceMotion: Bool = Motion.reduceMotion) -> AnyTransition {
        .opacity.animation(base(reduceMotion: reduceMotion))
    }

    /// Scale-and-fade from `anchor`, or a plain fade under Reduce Motion.
    /// The animation rides on the transition itself, so it runs whatever
    /// transaction the insertion or removal lands in: layout state is set
    /// outside `withAnimation`, and an `.animation(_:value:)` on the
    /// enclosing container does not reach a branch switch.
    private static func reveal(scale: CGFloat, anchor: UnitPoint, reduceMotion: Bool) -> AnyTransition {
        let animation = base(reduceMotion: reduceMotion)
        if reduceMotion { return .opacity.animation(animation) }
        return .scale(scale: scale, anchor: anchor).combined(with: .opacity).animation(animation)
    }
}
