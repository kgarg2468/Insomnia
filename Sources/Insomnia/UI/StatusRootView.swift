import SwiftUI

/// Everything drawn inside the status item: the cup, the three pills while
/// entering, or the countdown while running. The pills and the countdown
/// share a matched-geometry id so one morphs into the other.
struct StatusRootView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let onTapIcon: () -> Void
    let onTapPill: (DurationInput.Field) -> Void
    let onTapCountdown: () -> Void
    let onHoldEnd: () -> Void
    let onWidthChange: (CGFloat) -> Void

    @Namespace private var morph
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
    private var isEntering: Bool { model.phase.isEntering }
    /// Sleep is held right now (journal-backed), independent of the UI phase.
    private var isRunning: Bool { manager.isActive }

    private var countdownText: String {
        if !manager.countdownText.isEmpty { return manager.countdownText }
        return model.pendingCountdown ?? ""
    }

    var body: some View {
        HStack(spacing: 7) {
            icon
            if isEntering {
                pills
            } else if model.phase == .running {
                countdown
                HoldToEndButton(reduceMotion: reduceMotion, action: onHoldEnd)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, isEntering ? 8 : 6)
        .frame(height: NSStatusBar.system.thickness)
        .fixedSize()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            onWidthChange(width)
        }
    }

    /// Outline cup while idle; filled and tinted while sleep is held, so the
    /// app visibly does something even when Low Power Mode is not showing.
    private var icon: some View {
        Image(systemName: isRunning ? "cup.and.saucer.fill" : "cup.and.saucer")
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .tint(.accentColor)
            .contentTransition(.symbolEffect(.replace))
            .animation(Motion.base(reduceMotion: reduceMotion), value: isRunning)
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

    private var pills: some View {
        ForEach(Array(DurationInput.Field.allCases.prefix(model.visiblePills).enumerated()), id: \.element) { index, field in
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
            .modifier(MorphSource(id: field == .hours ? "morph" : nil, namespace: morph, isSource: isEntering))
            .transition(Motion.pillTransition(reduceMotion: reduceMotion))
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
            .matchedGeometryEffect(id: "morph", in: morph, isSource: !isEntering)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapCountdown)
    }
}

/// `matchedGeometryEffect` that can be switched off for the pills that do not
/// take part in the morph.
private struct MorphSource: ViewModifier {
    let id: String?
    let namespace: Namespace.ID
    let isSource: Bool

    func body(content: Content) -> some View {
        if let id {
            content.matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            content
        }
    }
}
