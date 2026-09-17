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

/// The five lashes on one side of the lens, for stroking. They never move.
struct EyeLashes: Shape {
    let side: EyeMarkGeometry.Side

    func path(in rect: CGRect) -> Path {
        Path(EyeMarkGeometry.lashes(in: rect, side: side))
    }
}

/// Fades one set of lashes with the blink: the lower set is gone by half
/// way, the upper set only starts to show from there, so no lash is ever
/// seen while the lid edge passes its side of the lens. Animatable so the
/// timing follows the lid's own progress rather than a plain crossfade.
nonisolated struct EyeLashFade: ViewModifier, Animatable {
    var progress: CGFloat
    let side: EyeMarkGeometry.Side

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var opacity: CGFloat {
        let x = side == .above ? (progress - 0.5) * 2 : 1 - progress * 2
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    func body(content: Content) -> some View {
        content.opacity(opacity)
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
/// clear with a pupil, lashes above). The change is a blink: the lid lifts
/// off the pupil while the lashes swap sides, or a crossfade under Reduce
/// Motion.
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
                // Crossfade the two end states instead of blinking.
                EyeLid(progress: 0)
                    .fill(.black)
                    .opacity(1 - progress)
                EyeLashes(side: .below)
                    .stroke(.black, style: stroke)
                    .opacity(1 - progress)
                EyeLashes(side: .above)
                    .stroke(.black, style: stroke)
                    .opacity(progress)
            } else {
                EyeLid(progress: progress)
                    .fill(.black)
                EyeLashes(side: .below)
                    .stroke(.black, style: stroke)
                    .modifier(EyeLashFade(progress: progress, side: .below))
                EyeLashes(side: .above)
                    .stroke(.black, style: stroke)
                    .modifier(EyeLashFade(progress: progress, side: .above))
            }
        }
    }
}
