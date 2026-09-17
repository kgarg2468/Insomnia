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

    private var countdownText: String {
        if !manager.countdownText.isEmpty { return manager.countdownText }
        return model.pendingCountdown ?? ""
    }

    /// The layout-changing state. Transitions of what comes and goes with it
    /// animate off this key, while the HStack outside it snaps.
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
                } else if model.phase == .starting {
                    starting
                } else if showsRunningControls {
                    countdown
                    HoldToEndButton(reduceMotion: reduceMotion, action: onHoldEnd)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(Motion.base(reduceMotion: reduceMotion), value: layoutKey)
        }
        .padding(.leading, 6)
        .padding(.trailing, model.slotsPresent ? 8 : 6)
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
            .transition(.identity)
            .zIndex(Double(10 - index))
        }
    }

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
    }

    /// Enter was pressed and the manager is still arming the recovery agent
    /// and disabling sleep. Deliberately not a countdown: it stands in for
    /// nothing that exists yet, and it must stay legible if the start is
    /// refused a frame later.
    private var starting: some View {
        Text(MenuBarModel.startingText)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.trailing, 1)
            .transition(.opacity)
            .accessibilityLabel("Starting session")
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
