import SwiftUI

extension Color {
    init(brand rgb: BrandPalette.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// The almond lens on its own, for stroking.
struct EyeLens: Shape {
    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.lens(in: rect))
    }
}

/// The lid that shades the lens, for filling: nothing at 1, the whole lens at 0.
struct EyeLid: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.lid(in: rect, progress: progress))
    }
}

/// The five lashes, for stroking: above the lens at 1, below it at 0.
struct EyeLashes: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.lashes(in: rect, progress: progress))
    }
}

/// The pupil with its highlight bitten out, for filling.
struct EyePupil: Shape {
    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.pupil(in: rect))
    }
}

/// The mark as it appears in the status item: a closed eye while idle (the
/// lens shaded, lashes below), which opens while sleep is held (the lens
/// clear with a pupil, lashes above). The change is a blink: the lid sweeps
/// across the lens carrying its lashes, or a crossfade under Reduce Motion.
/// Everything is drawn in `.primary`, so the mark follows the light or dark
/// menu bar and never takes a tint.
struct EyeMarkView: View {
    /// 0 closed, 1 open.
    let progress: CGFloat
    let reduceMotion: Bool
    var size: CGFloat = 17

    init(isRunning: Bool, reduceMotion: Bool, size: CGFloat = 17) {
        self.init(progress: isRunning ? 1 : 0, reduceMotion: reduceMotion, size: size)
    }

    /// One frozen frame of the blink, for previews.
    init(progress: CGFloat, reduceMotion: Bool = true, size: CGFloat = 17) {
        self.progress = progress
        self.reduceMotion = reduceMotion
        self.size = size
    }

    static func stroke(size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: EyeMoonGeometry.lineWidth(for: size), lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        // The layers are drawn opaque and used as a mask over a single
        // `.primary` fill: the label colour is translucent, and this keeps the
        // lid, outline and lashes from doubling up where they overlap.
        Rectangle()
            .fill(.primary)
            .mask { layers }
            .frame(width: size, height: size)
            .animation(Motion.base(reduceMotion: reduceMotion), value: progress)
    }

    private var layers: some View {
        let stroke = Self.stroke(size: size)
        return ZStack {
            EyeLens()
                .stroke(.black, style: stroke)
            EyePupil()
                .fill(.black)
            if reduceMotion {
                // Crossfade the two end states instead of sweeping.
                EyeLid(progress: 0)
                    .fill(.black)
                    .opacity(1 - progress)
                EyeLashes(progress: 0)
                    .stroke(.black, style: stroke)
                    .opacity(1 - progress)
                EyeLashes(progress: 1)
                    .stroke(.black, style: stroke)
                    .opacity(progress)
            } else {
                EyeLid(progress: progress)
                    .fill(.black)
                EyeLashes(progress: progress)
                    .stroke(.black, style: stroke)
            }
        }
    }
}
