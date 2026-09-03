import SwiftUI

/// One of the Days / Hours / Minutes fields in the menu bar. Dark rounded
/// material, unit name as placeholder, "?" badge on the top-right corner,
/// soft focus glow, snappy bounce on focus and on a rejected key.
struct PillView: View {
    let field: DurationInput.Field
    let text: String?
    let focused: Bool
    let valid: Bool
    let glowVisible: Bool
    let focusBounce: Int
    let rejectBounce: Int
    let reduceMotion: Bool
    let onTap: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6.5, style: .continuous) }
    private var isPlaceholder: Bool { text == nil }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(text ?? field.placeholder)
                .font(.system(size: 12, weight: isPlaceholder ? .regular : .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isPlaceholder ? Color.white.opacity(0.42) : Color.white)
                .contentTransition(.numericText())
                .animation(Motion.base(reduceMotion: reduceMotion), value: text)
                .padding(.horizontal, isPlaceholder ? 7 : 9)
                .frame(minWidth: 26)
                .frame(height: 18)
                .background {
                    shape
                        .fill(Color(white: 0.09).opacity(0.78))
                        .background(.ultraThinMaterial, in: shape)
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(valid ? 0.10 : 0), lineWidth: 0.5)
                }
                .overlay {
                    shape.strokeBorder(Color.red.opacity(valid ? 0 : 0.8), lineWidth: 1)
                }
                .background { glow }

            HelpBadge()
                .offset(x: 3.5, y: -3.5)
                .help(field.help)
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .phaseAnimator([CGFloat(1), Motion.bounceScale(reduceMotion: reduceMotion), 1], trigger: focused ? focusBounce : 0) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in
            Motion.snappy(reduceMotion: reduceMotion)
        }
        .phaseAnimator([CGFloat(0), reduceMotion ? 0 : -3, reduceMotion ? 0 : 3, 0], trigger: focused ? rejectBounce : 0) { content, dx in
            content.offset(x: dx)
        } animation: { _ in
            Motion.snappy(reduceMotion: reduceMotion)
        }
    }

    /// Two blurred strokes: no hard outline, just light bleeding out of the edge.
    private var glow: some View {
        let on = focused && glowVisible
        return ZStack {
            shape
                .stroke(Color.accentColor.opacity(0.95), lineWidth: 1.5)
                .blur(radius: 1.5)
            shape
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 3)
                .blur(radius: 4)
        }
        .opacity(on ? 1 : 0)
        .animation(Motion.base(reduceMotion: reduceMotion), value: on)
    }
}

/// The small circular "?" help affordance. Not an input.
struct HelpBadge: View {
    var body: some View {
        Text("?")
            .font(.system(size: 7.5, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.85))
            .frame(width: 10, height: 10)
            .background(Circle().fill(Color(white: 0.32)))
            .overlay(Circle().strokeBorder(Color(white: 0.12).opacity(0.9), lineWidth: 0.75))
            .accessibilityLabel("Help")
    }
}
