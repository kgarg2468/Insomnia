import Foundation
import Observation

/// UI state for the status item. The controller mutates it inside
/// `withAnimation` blocks; the views only read it.
@MainActor
@Observable
final class MenuBarModel {
    enum Mode: Equatable, Sendable {
        /// Enter starts a new session.
        case start
        /// Enter extends the running session (reached by clicking the cup or
        /// the countdown while a session is running).
        case extend
    }

    /// What Enter does with the pills as they stand.
    enum CommitAction: Equatable {
        case run(TimeInterval)
        /// Nothing to act on: shake the focused pill.
        case reject
    }

    /// Bare Enter with every pill empty starts the default preset, so the
    /// common case is one keystroke. While extending there is no sensible
    /// default duration, so it shakes instead.
    static func commitAction(mode: Mode, typed: TimeInterval?, defaultPreset: TimeInterval) -> CommitAction {
        if let typed { return .run(typed) }
        guard mode == .start, defaultPreset > 0 else { return .reject }
        return .run(defaultPreset)
    }

    enum Phase: Equatable, Sendable {
        case idle
        case entering(Mode)
        case running

        var isEntering: Bool {
            if case .entering = self { return true }
            return false
        }
    }

    var phase: Phase = .idle
    var input = DurationInput()
    var focused: DurationInput.Field = .hours
    /// How many pills are laid out right now (0...3); stepped for the stagger.
    var visiblePills: Int = 0
    /// Focus glow fades in once the pills have landed.
    var focusVisible: Bool = false
    /// Countdown text shown while the manager is still starting the session.
    var pendingCountdown: String?

    // Animation triggers. Views run a bounce whenever one of these changes.
    var iconBounce: Int = 0
    var focusBounce: Int = 0
    var rejectBounce: Int = 0

    var mode: Mode? {
        if case let .entering(m) = phase { return m }
        return nil
    }
}
