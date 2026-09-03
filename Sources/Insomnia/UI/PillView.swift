import SwiftUI

/// One of the Days / Hours / Minutes fields in the menu bar. Flat dark
/// rounded rectangle, unit name as placeholder, a crisp accent ring when
/// focused, snappy bounce on focus and on a rejected key.
///
/// Nothing here blurs or uses a material: every frame of this view is
/// composited inside the menu bar, so the cheap drawing is the point.
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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }
    private var isPlaceholder: Bool { text == nil }
    /// The ring only appears once the pills have landed.
    private var ringVisible: Bool { focused && glowVisible }

    var body: some View {
        Text(text ?? field.placeholder)
            .font(.system(size: 12, weight: isPlaceholder ? .regular : .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isPlaceholder ? Color.white.opacity(0.42) : Color.white)
            .contentTransition(.numericText())
            .animation(Motion.base(reduceMotion: reduceMotion), value: text)
            .padding(.horizontal, isPlaceholder ? 8 : 10)
            .frame(minWidth: 28)
            .frame(height: 19)
            .background(shape.fill(Color(white: 0.09).opacity(0.92)))
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                shape
                    .strokeBorder(Color.accentColor.opacity(ringVisible ? 1 : 0), lineWidth: 1.5)
                    .animation(Motion.base(reduceMotion: reduceMotion), value: ringVisible)
            }
            .overlay {
                shape.strokeBorder(Color.red.opacity(valid ? 0 : 0.8), lineWidth: 1)
            }
            .environment(\.colorScheme, .dark)
            .contentShape(Rectangle())
            .help(field.help)
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
}
