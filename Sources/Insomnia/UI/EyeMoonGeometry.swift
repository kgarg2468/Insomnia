import CoreGraphics

/// The Insomnia mark as pure geometry: an almond-shaped eye outline with a
/// solid crescent moon inside it, and nothing else. The moon's convex spine
/// is on the left; its opening and both tips face right.
///
/// Everything is laid out on a 24-unit grid and scaled into whatever rect it
/// is asked for, so the same numbers draw the 17-point status item and the
/// 1024-pixel app icon: scripts/generate-app-icon.sh compiles this file
/// straight into the icon generator. CoreGraphics only, no SwiftUI or
/// AppKit, so the file builds standalone. Coordinates are y-down (SwiftUI's
/// convention); the vertical centre line y = 12 is the eye's axis.
enum EyeMoonGeometry {
    static let designSize: CGFloat = 24
    /// Outline weight in grid units: 1.5 of 24, the menu bar's line weight.
    static let strokeUnits: CGFloat = 1.5

    // Eye: two pointed corners on the axis; each lid is one cubic curve.
    private static let corners = (left: CGPoint(x: 1.5, y: 12), right: CGPoint(x: 22.5, y: 12))
    private static let lidControlX = (left: CGFloat(7), right: CGFloat(17))
    private static let lidControlY = (top: CGFloat(4.5), bottom: CGFloat(19.5))

    // Moon: a disc with a second disc bitten out of its right-hand side.
    private static let moonCenter = CGPoint(x: 11.6, y: 12)
    private static let moonRadius: CGFloat = 4.2
    private static let biteCenter = CGPoint(x: 13.9, y: 12)
    private static let biteRadius: CGFloat = 3.85

    /// Maps the design grid onto `rect`: uniformly scaled, centred.
    static func gridTransform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / designSize
        let side = designSize * scale
        return CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
    }

    /// Stroke weight for a mark drawn into a square of `size`.
    static func lineWidth(for size: CGFloat) -> CGFloat {
        strokeUnits * size / designSize
    }

    /// The closed almond outline, meant to be stroked.
    static func eyeOutline(in rect: CGRect) -> CGPath {
        let t = gridTransform(in: rect)
        let path = CGMutablePath()
        path.move(to: corners.left, transform: t)
        path.addCurve(
            to: corners.right,
            control1: CGPoint(x: lidControlX.left, y: lidControlY.top),
            control2: CGPoint(x: lidControlX.right, y: lidControlY.top),
            transform: t
        )
        path.addCurve(
            to: corners.left,
            control1: CGPoint(x: lidControlX.right, y: lidControlY.bottom),
            control2: CGPoint(x: lidControlX.left, y: lidControlY.bottom),
            transform: t
        )
        path.closeSubpath()
        return path
    }

    /// The solid crescent as one closed subpath, meant to be filled: the
    /// outer arc runs from tip to tip around the left, the inner arc comes
    /// back along the bite. A single subpath keeps it independent of the
    /// fill rule and lets `contains` answer for it directly.
    static func crescent(in rect: CGRect) -> CGPath {
        let t = gridTransform(in: rect)
        // Where the two circles meet, measured from the moon's centre.
        let d = biteCenter.x - moonCenter.x
        let along = (d * d + moonRadius * moonRadius - biteRadius * biteRadius) / (2 * d)
        let half = (moonRadius * moonRadius - along * along).squareRoot()
        let tipX = moonCenter.x + along
        let tipAngle = acos(along / moonRadius)
        let biteAngle = atan2(half, tipX - biteCenter.x)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: tipX, y: moonCenter.y - half), transform: t)
        // Decreasing angle from the upper tip: through the left-hand spine to the lower tip.
        path.addArc(center: moonCenter, radius: moonRadius, startAngle: -tipAngle, endAngle: tipAngle, clockwise: true, transform: t)
        // Increasing angle from the lower tip: along the bite back up to the upper tip.
        path.addArc(center: biteCenter, radius: biteRadius, startAngle: biteAngle, endAngle: -biteAngle, clockwise: false, transform: t)
        path.closeSubpath()
        return path
    }
}
