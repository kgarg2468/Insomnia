import SwiftUI

/// The cup drawn by hand instead of `cup.and.saucer`, so the outline and the
/// filled state are the same artwork and the stroke weight matches the rest
/// of the menu bar.
///
/// Everything is laid out in a 24x24 grid (the mockup's SVG viewBox) and
/// scaled into whatever rect the shape is given, so the geometry can be read
/// straight off the drawing.
struct CupMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let g = CupGrid(rect: rect)
        CupMark.addBody(to: &path, g)
        CupMark.addHandle(to: &path, g)
        CupMark.addSaucer(to: &path, g)
        return path
    }

    /// Stroke weight for a mark drawn at `size` points, from the 1.5 units
    /// the artwork uses in the 24-unit grid.
    static func lineWidth(for size: CGFloat) -> CGFloat {
        1.5 * size / CupGrid.designSize
    }

    static func stroke(size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth(for: size), lineCap: .round, lineJoin: .round)
    }

    /// A 12-wide, 11-tall box with square top corners and radius-5 bottom
    /// corners: the part that fills while a session runs.
    fileprivate static func addBody(to path: inout Path, _ g: CupGrid) {
        path.move(to: g.point(4, 8))
        path.addLine(to: g.point(16, 8))
        path.addLine(to: g.point(16, 14))
        path.addArc(center: g.point(11, 14), radius: g.length(5), startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: g.point(9, 19))
        path.addArc(center: g.point(9, 14), radius: g.length(5), startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
    }

    private static func addHandle(to path: inout Path, _ g: CupGrid) {
        path.move(to: g.point(16, 9))
        path.addLine(to: g.point(18, 9))
        path.addArc(center: g.point(18, 11.5), radius: g.length(2.5), startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: g.point(16, 14))
    }

    private static func addSaucer(to path: inout Path, _ g: CupGrid) {
        path.move(to: g.point(3, 21))
        path.addLine(to: g.point(18, 21))
    }
}

/// The closed body subpath on its own, so the running state can fill it
/// without also flooding the handle and the saucer.
struct CupMarkBody: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        CupMark.addBody(to: &path, CupGrid(rect: rect))
        return path
    }
}

/// Maps the 24-unit design grid onto a rect, centred and uniformly scaled.
private struct CupGrid {
    static let designSize: CGFloat = 24

    let scale: CGFloat
    let origin: CGPoint

    init(rect: CGRect) {
        scale = min(rect.width, rect.height) / CupGrid.designSize
        let side = CupGrid.designSize * scale
        origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    func length(_ v: CGFloat) -> CGFloat { v * scale }
}

/// The cup as it appears in the status item: an outline while idle, filled
/// and tinted while sleep is held, cross-fading between the two.
struct CupMarkView: View {
    let isRunning: Bool
    let reduceMotion: Bool
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            CupMark()
                .stroke(.primary, style: CupMark.stroke(size: size))
                .opacity(isRunning ? 0 : 1)

            ZStack {
                CupMarkBody().fill(.tint)
                CupMark().stroke(.tint, style: CupMark.stroke(size: size))
            }
            .opacity(isRunning ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(Motion.base(reduceMotion: reduceMotion), value: isRunning)
    }
}
