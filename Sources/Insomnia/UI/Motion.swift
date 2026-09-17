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

    /// A paced close (the width driven by `StatusWidthAnimator`, 3 pt per
    /// frame) fades the pills where they stand while the bar wipes over
    /// them, and a reopen under it fades them back: opacity only, no scale.
    static let closeFadeDuration: TimeInterval = 0.35

    /// The eye's blink. The lid and the pupil run on their own curves, and
    /// each direction has its own, so the lid is seen lifting and the pupil
    /// is seen arriving: long enough to read as a blink, not a flicker.
    /// Opening: the lid lifts on a slow spring.
    static let blinkResponse: TimeInterval = 0.95
    static let blinkDampingFraction = 0.9
    static let blink: Animation = .spring(response: blinkResponse, dampingFraction: blinkDampingFraction)
    /// Closing: the lid drops a little quicker and nearer critical damping.
    static let blinkCloseResponse: TimeInterval = 0.8
    static let blinkCloseDampingFraction = 0.95
    static let blinkClose: Animation = .spring(response: blinkCloseResponse, dampingFraction: blinkCloseDampingFraction)
    /// Reduce Motion: the lid and the lashes crossfade instead.
    static let reducedBlinkDuration: TimeInterval = 0.3
    static let reducedBlink: Animation = .easeInOut(duration: reducedBlinkDuration)

    /// The pupil arriving behind the lifting lid: a bouncier spring (peak
    /// scale about 1.04) that starts once the lid is under way. Keyed on
    /// the eye state, so a close during the delay retargets it rather than
    /// letting it run late.
    static let pupilOpenResponse: TimeInterval = 0.5
    static let pupilOpenDampingFraction = 0.6
    static let pupilOpenDelay: TimeInterval = 0.2
    static let pupilOpen: Animation = .spring(response: pupilOpenResponse, dampingFraction: pupilOpenDampingFraction).delay(pupilOpenDelay)
    /// The pupil shrinking away as the lid drops: no delay, no bounce.
    static let pupilCloseDuration: TimeInterval = 0.4
    static let pupilClose: Animation = .easeOut(duration: pupilCloseDuration)
    /// The pupil's scale in the closed eye; 1 in the open eye and, since it
    /// never scales, under Reduce Motion.
    static let pupilClosedScale: CGFloat = 0.6

    /// The lid's blink in one direction; a crossfade under Reduce Motion.
    static func blink(opening: Bool, reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        if reduceMotion { return reducedBlink }
        return opening ? blink : blinkClose
    }

    /// The pupil's blink in one direction. Under Reduce Motion it does not
    /// scale at all: only its opacity moves, on the same crossfade as the lid.
    static func pupil(opening: Bool, reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        if reduceMotion { return reducedBlink }
        return opening ? pupilOpen : pupilClose
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
