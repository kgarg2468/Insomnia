import SwiftUI

/// Everything drawn inside the status item: the mark, the three pill slots
/// while entering, or the countdown while a session runs or starts.
///
/// The status item cannot animate its width (every change of
/// `NSStatusItem.length` re-lays out the whole menu bar), so the layout here
/// changes only on state the controller sets outside any animation
/// transaction: `slotsPresent`, `phase` and `startError`. Everything that
/// springs (the pills staggering in and out, the focus ring, the countdown
/// appearing) is scale and opacity inside a layout that has already snapped.
struct StatusRootView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let onTapIcon: () -> Void
    let onTapPill: (DurationInput.Field) -> Void
    let onTapCountdown: () -> Void
    let onHoldEnd: () -> Void
    let onWidthChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    /// Scale of a pill slot's content while hidden; the same shape as
    /// `Motion.pillTransition`, driven by `visiblePills` instead of by
    /// inserting and removing the pill (which would move the layout).
    private static let hiddenPillScale: CGFloat = 0.55

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
    /// Sleep is held right now (journal-backed), independent of the UI phase.
    private var isRunning: Bool { manager.isActive }
    /// Both, not either: the phase can lag the manager by a hop when a
    /// session ends, and that window must not offer an end ring and a
    /// countdown for a session that is already gone.
    private var showsRunningControls: Bool { model.phase.showsRunningControls && isRunning }
    /// A pending start shows its projected countdown; a confirmed session its
    /// live one.
    private var showsCountdown: Bool { model.phase == .starting || showsRunningControls }

    private var countdownText: String {
        if !manager.countdownText.isEmpty { return manager.countdownText }
        if let pending = model.pendingCountdown { return pending }
        // A start with no projection; should not happen but keeps the view total.
        return model.phase == .starting ? MenuBarModel.startingText : ""
    }

    /// The layout-changing state. Transitions of what comes and goes with it
    /// animate off this key. The animation is scoped to the `Group` below,
    /// not the HStack: an animation on the HStack would interpolate its own
    /// size (and so the reported width) every time the key changes, which is
    /// the per-frame relayout this view exists to avoid.
    private struct LayoutKey: Equatable {
        let phase: MenuBarModel.Phase
        let slotsPresent: Bool
    }

    private var layoutKey: LayoutKey {
        LayoutKey(phase: model.phase, slotsPresent: model.slotsPresent)
    }

    var body: some View {
        HStack(spacing: 7) {
            icon
            Group {
                if model.slotsPresent {
                    pills
                    if let error = model.startError {
                        startError(error)
                    }
                } else if showsCountdown {
                    countdown
                    if showsRunningControls {
                        HoldToEndButton(reduceMotion: reduceMotion, action: onHoldEnd)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
            .animation(Motion.base(reduceMotion: reduceMotion), value: layoutKey)
        }
        .padding(.leading, 6)
        // Never animated: `slotsPresent` can land in the same transaction as
        // a `withAnimation` (a refused start reopens the pills in one turn),
        // and an interpolated inset would report a width per frame.
        .animation(nil) { $0.padding(.trailing, model.slotsPresent ? 8 : 6) }
        .frame(height: NSStatusBar.system.thickness)
        .fixedSize()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            onWidthChange(width)
        }
    }

    /// Neutral eye and moon while idle; the moon turns blue-grey while sleep is
    /// held, so the app visibly does something even when Low Power Mode is
    /// not showing.
    private var icon: some View {
        EyeMoonMarkView(isRunning: isRunning, reduceMotion: reduceMotion)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .phaseAnimator([CGFloat(1), reduceMotion ? 1 : 0.86, 1], trigger: model.iconBounce) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in
                Motion.snappy(reduceMotion: reduceMotion)
            }
            .onTapGesture(perform: onTapIcon)
            .accessibilityLabel("Insomnia")
    }

    /// All three slots are in the layout whenever they are present;
    /// `visiblePills` only scales and fades each slot's content, so the
    /// stagger never moves the layout.
    private var pills: some View {
        ForEach(Array(DurationInput.Field.allCases.enumerated()), id: \.element) { index, field in
            let shown = index < model.visiblePills
            PillView(
                field: field,
                text: model.input.text(for: field),
                focused: model.focused == field,
                valid: model.input.isValid(field),
                glowVisible: model.focusVisible,
                focusBounce: model.focusBounce,
                rejectBounce: model.rejectBounce,
                reduceMotion: reduceMotion,
                onTap: { onTapPill(field) }
            )
            .scaleEffect(shown || reduceMotion ? 1 : Self.hiddenPillScale, anchor: .leading)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
            // A slot born already shown (the first pill when its stagger step
            // lands in the same transaction as the slots, every pill when a
            // refused start puts them straight back) has no hidden frame to
            // spring from, so it springs in through the same shape as a
            // transition. One born hidden must not: its stagger step would
            // then compound with a transition still in flight. Removal is
            // instant either way, so a leaving slot never holds the layout.
            .transition(.asymmetric(insertion: shown ? Motion.pillTransition(reduceMotion: reduceMotion) : .identity, removal: .identity))
            .zIndex(Double(10 - index))
        }
    }

    /// The live countdown while running, or the projected one while a start
    /// is pending: the manager has to arm the recovery agent and disable
    /// sleep first, and either can take seconds. The projection is what the
    /// session will read once confirmed, so the live text replaces it
    /// without a jump; the hold-to-end ring waits for the confirmation.
    private var countdown: some View {
        Text(countdownText)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(Motion.tick(reduceMotion: reduceMotion), value: countdownText)
            .padding(.trailing, 1)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapCountdown)
            .accessibilityLabel(model.phase == .starting ? "Starting session" : countdownText)
    }

    /// The manager refused the start: say so next to the pills the value is
    /// still in. The full reason lives in the right-click menu.
    private func startError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(brand: BrandPalette.violet))
            .lineLimit(1)
            .fixedSize()
            .transition(.opacity)
            .accessibilityLabel("Start failed")
    }
}
