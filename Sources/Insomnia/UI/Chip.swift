import SwiftUI

/// A rounded preset / extend button that bounces when tapped.
struct Chip: View {
    let title: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var taps = 0
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    Capsule(style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.32 : 0.22)) : AnyShapeStyle(.quaternary.opacity(hovering ? 1.5 : 1)))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.base(reduceMotion: reduceMotion), value: hovering)
        .phaseAnimator([CGFloat(1), Motion.bounceScale(reduceMotion: reduceMotion), 1], trigger: taps) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in
            Motion.snappy(reduceMotion: reduceMotion)
        }
    }
}

/// Short chip label for a preset: "30m", "2h", "3d".
func chipLabel(for seconds: TimeInterval) -> String {
    SessionMath.formatRemaining(seconds).replacingOccurrences(of: " ", with: "")
}
