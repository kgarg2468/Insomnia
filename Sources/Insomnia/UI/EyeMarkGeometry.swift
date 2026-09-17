import CoreGraphics

/// The menu bar mark as pure geometry: the app icon's almond lens
/// (`EyeMoonGeometry.eyeOutline`) with a lid that shades it, five lashes on
/// that lid, and a pupil behind it. Same 24-unit grid and conventions as
/// `EyeMoonGeometry`; CoreGraphics only.
///
/// `progress` runs from 0 (closed: the lid covers the whole lens and its
/// lashes hang below) to 1 (open: the lid sits on the upper edge and its
/// lashes point up). The blink is the upper lid turning about the eye's
/// axis, seen flat: every offset from the axis is scaled by
/// cos(π · (1 − progress)), so half way the lid and lashes lie along the
/// axis and the lashes foreshorten, the way a blink reads from the front.
enum EyeMarkGeometry {
    static let designSize = EyeMoonGeometry.designSize
    /// The eye's horizontal axis, through both corners.
    static let axisY = EyeMoonGeometry.designSize / 2

    // Lashes: five, at these fractions of the lens width, each starting
    // `lashGap` beyond the lid's centre line along its outward normal and
    // running `lashLength`. Stroked at the outline's weight with round caps.
    static let lashFractions: [CGFloat] = [0.2, 0.35, 0.5, 0.65, 0.8]
    static let lashGap: CGFloat = 2.5
    static let lashLength: CGFloat = 3

    // Pupil: a disc with a highlight bitten out of its upper right.
    static let pupilCenter = CGPoint(x: 12, y: 12)
    static let pupilRadius: CGFloat = 4
    static let highlightCenter = CGPoint(x: 14, y: 10)
    static let highlightRadius: CGFloat = 1.4

    /// The closed almond outline, meant to be stroked: the icon's lens.
    static func lens(in rect: CGRect) -> CGPath {
        EyeMoonGeometry.eyeOutline(in: rect)
    }

    /// The lid, meant to be filled: the region between the upper edge of the
    /// lens and the lid's current position. Nothing at progress 1, the whole
    /// lens at progress 0. One closed subpath.
    static func lid(in rect: CGRect, progress: CGFloat) -> CGPath {
        let t = EyeMoonGeometry.gridTransform(in: rect)
        let fold = fold(progress)
        let lid = upperLid
        let path = CGMutablePath()
        path.move(to: lid.p0, transform: t)
        path.addCurve(to: lid.p3, control1: lid.c1, control2: lid.c2, transform: t)
        path.addCurve(to: lid.p0, control1: folded(lid.c2, fold), control2: folded(lid.c1, fold), transform: t)
        path.closeSubpath()
        return path
    }

    /// Five lashes as five open subpaths, meant to be stroked: above the lens
    /// at progress 1, below it at progress 0.
    static func lashes(in rect: CGRect, progress: CGFloat) -> CGPath {
        let t = EyeMoonGeometry.gridTransform(in: rect)
        let fold = fold(progress)
        let lid = upperLid
        let path = CGMutablePath()
        for fraction in lashFractions {
            let s = lid.parameter(atX: lid.p0.x + (lid.p3.x - lid.p0.x) * fraction)
            let base = lid.point(at: s)
            let tangent = lid.tangent(at: s)
            let length = hypot(tangent.x, tangent.y)
            // Outward normal of the upper lid: the tangent turned a quarter turn towards −y.
            let normal = CGPoint(x: tangent.y / length, y: -tangent.x / length)
            let start = CGPoint(x: base.x + normal.x * lashGap, y: base.y + normal.y * lashGap)
            let end = CGPoint(x: base.x + normal.x * (lashGap + lashLength), y: base.y + normal.y * (lashGap + lashLength))
            path.move(to: folded(start, fold), transform: t)
            path.addLine(to: folded(end, fold), transform: t)
        }
        return path
    }

    /// The pupil as one closed subpath, meant to be filled: the disc's rim
    /// runs the long way round from one intersection with the highlight to
    /// the other, and the highlight's arc comes back through the disc. A
    /// single subpath keeps it independent of the fill rule.
    static func pupil(in rect: CGRect) -> CGPath {
        let t = EyeMoonGeometry.gridTransform(in: rect)
        let c = pupilCenter, h = highlightCenter
        let R = pupilRadius, r = highlightRadius
        let d = hypot(h.x - c.x, h.y - c.y)
        // Where the two circles meet, measured from the pupil's centre along the line to the highlight.
        let along = (d * d + R * R - r * r) / (2 * d)
        let half = (R * R - along * along).squareRoot()
        let towards = atan2(h.y - c.y, h.x - c.x)
        let rimSpread = acos(along / R)
        let biteSpread = atan2(half, along - d)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x + R * cos(towards + rimSpread), y: c.y + R * sin(towards + rimSpread)), transform: t)
        // Increasing angle: around the rim away from the highlight.
        path.addArc(center: c, radius: R, startAngle: towards + rimSpread, endAngle: towards - rimSpread, clockwise: false, transform: t)
        // Decreasing angle: along the highlight's inner arc back to the start.
        path.addArc(center: h, radius: r, startAngle: towards - biteSpread, endAngle: towards + biteSpread, clockwise: true, transform: t)
        path.closeSubpath()
        return path
    }

    // MARK: - The upper lid

    /// One cubic Bézier in grid units.
    private struct Cubic {
        let p0: CGPoint
        let c1: CGPoint
        let c2: CGPoint
        let p3: CGPoint

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
        }

        func tangent(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
            return CGPoint(
                x: a * (c1.x - p0.x) + b * (c2.x - c1.x) + c * (p3.x - c2.x),
                y: a * (c1.y - p0.y) + b * (c2.y - c1.y) + c * (p3.y - c2.y)
            )
        }

        /// Parameter at which the curve crosses `x`; x is monotone along a lid.
        func parameter(atX x: CGFloat) -> CGFloat {
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if point(at: mid).x < x { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
    }

    /// The lens's upper lid, read back from the outline's first curve so the
    /// mark follows the icon's lens without repeating its numbers.
    private static let upperLid: Cubic = {
        let grid = CGRect(x: 0, y: 0, width: designSize, height: designSize)
        var points: [CGPoint] = []
        EyeMoonGeometry.eyeOutline(in: grid).applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint where points.isEmpty:
                points.append(element.pointee.points[0])
            case .addCurveToPoint where points.count == 1:
                points.append(contentsOf: [element.pointee.points[0], element.pointee.points[1], element.pointee.points[2]])
            default:
                break
            }
        }
        precondition(points.count == 4, "the eye outline should open with a cubic upper lid")
        return Cubic(p0: points[0], c1: points[1], c2: points[2], p3: points[3])
    }()

    /// How far the lid has turned about the axis: 1 open, 0 half way, −1 closed.
    private static func fold(_ progress: CGFloat) -> CGFloat {
        cos(.pi * (1 - progress))
    }

    private static func folded(_ p: CGPoint, _ fold: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: axisY + (p.y - axisY) * fold)
    }
}
