import SwiftUI

/// The eye outline on its own, for stroking.
struct EyeOutline: Shape {
    func path(in rect: CGRect) -> Path {
        Path(EyeMoonGeometry.eyeOutline(in: rect))
    }
}

/// The solid crescent on its own, for filling.
struct CrescentMoon: Shape {
    func path(in rect: CGRect) -> Path {
        Path(EyeMoonGeometry.crescent(in: rect))
    }
}

extension Color {
    init(brand rgb: BrandPalette.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// The mark as it appears in the status item: a neutral eye and moon while
/// idle; the moon turns violet while sleep is held, cross-fading between
/// the two. The eye's interior is never filled, so the outline reads the
/// same in both states and in light and dark menu bars.
struct EyeMoonMarkView: View {
    let isRunning: Bool
    let reduceMotion: Bool
    var size: CGFloat = 17

    static func stroke(size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: EyeMoonGeometry.lineWidth(for: size), lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            EyeOutline()
                .stroke(.primary, style: Self.stroke(size: size))
            CrescentMoon()
                .fill(.primary)
                .opacity(isRunning ? 0 : 1)
            CrescentMoon()
                .fill(Color(brand: BrandPalette.violet))
                .opacity(isRunning ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(Motion.base(reduceMotion: reduceMotion), value: isRunning)
    }
}
