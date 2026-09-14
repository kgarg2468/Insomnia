import CoreGraphics
import SwiftUI
import XCTest
@testable import Insomnia

/// The eye/moon mark, checked on rendered geometry: the crescent's spine is
/// on the left with its opening and tips to the right, it stays clear of the
/// eye outline, the eye interior is never flooded, and the running state is
/// a violet moon rather than a tinted blob.
final class BrandingTests: XCTestCase {
    private let grid = CGRect(x: 0, y: 0, width: EyeMoonGeometry.designSize, height: EyeMoonGeometry.designSize)

    func testCrescentSpineIsOnTheLeftAndItsOpeningAndTipsFaceRight() {
        let moon = EyeMoonGeometry.crescent(in: grid)
        let eye = EyeMoonGeometry.eyeOutline(in: grid)
        let box = moon.boundingBoxOfPath
        let axisY = grid.midY

        // Solid along the spine, and the spine sits left of the eye's centre.
        XCTAssertTrue(moon.contains(CGPoint(x: box.minX + 0.5, y: axisY)))
        XCTAssertLessThan(box.midX, eye.boundingBoxOfPath.midX)
        // The opening: the axis just inside the right edge is empty.
        XCTAssertFalse(moon.contains(CGPoint(x: box.maxX - 0.4, y: axisY)))
        // Two tips at the right edge, one above and one below the axis.
        let probeX = box.maxX - 0.4
        let rows = stride(from: box.minY, through: box.maxY, by: 0.05).filter { moon.contains(CGPoint(x: probeX, y: $0)) }
        XCTAssertFalse(rows.isEmpty, "no tip found at x=\(probeX)")
        XCTAssertTrue(rows.contains { $0 < axisY - 1 }, "upper tip missing: \(rows)")
        XCTAssertTrue(rows.contains { $0 > axisY + 1 }, "lower tip missing: \(rows)")
        XCTAssertFalse(rows.contains { abs($0 - axisY) < 0.5 }, "the moon must not bridge its own opening: \(rows)")
    }

    func testCrescentIsSolidInsideTheEyeAndNeverTouchesTheOutline() {
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let eye = EyeMoonGeometry.eyeOutline(in: rect)
        let moon = EyeMoonGeometry.crescent(in: rect)
        let outline = Raster(size: size) { ctx in
            ctx.addPath(eye)
            ctx.setLineWidth(EyeMoonGeometry.lineWidth(for: CGFloat(size)))
            ctx.strokePath()
        }
        let fill = Raster(size: size) { ctx in
            ctx.addPath(moon)
            ctx.fillPath()
        }

        var moonPixels = 0
        var overlap = 0
        var outsideEye = 0
        for y in 0..<size {
            for x in 0..<size where fill.alpha(x, y) > 0.5 {
                moonPixels += 1
                if outline.alpha(x, y) > 0.05 { overlap += 1 }
                if !eye.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { outsideEye += 1 }
            }
        }
        XCTAssertGreaterThan(moonPixels, size * size / 40, "the moon is a solid shape, not a hairline")
        XCTAssertEqual(overlap, 0, "the moon must not touch the eye outline")
        XCTAssertEqual(outsideEye, 0, "the moon must sit inside the eye")
        // Only one closed subpath: nothing else (no iris, lashes, stars) is drawn inside the eye.
        XCTAssertEqual(subpathCount(moon), 1)
        XCTAssertEqual(subpathCount(eye), 1)
    }

    @MainActor
    func testMenuBarMarkIsLegibleAtSeventeenPointsInLightAndDarkWithoutFloodingTheEye() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = EyeMoonMarkView(isRunning: false, reduceMotion: true, size: 17)
            let px = try Raster.render(view, scheme: scheme, scale: 2)
            let ink = px.count { $0.alpha > 0.5 }
            XCTAssertGreaterThan(ink, 60, "\(scheme): too little ink to read at 17pt")
            XCTAssertLessThan(ink, px.total / 2, "\(scheme): the mark must not be a filled blob")

            let probes = Probes(size: 17, scale: 2)
            XCTAssertGreaterThan(px.alpha(probes.outline), 0.5, "\(scheme): outline missing at \(probes.outline)")
            // `.primary` is the system label colour, which is itself only 85% opaque.
            XCTAssertGreaterThan(px.alpha(probes.moon), 0.7, "\(scheme): moon missing at \(probes.moon)")
            XCTAssertLessThan(px.alpha(probes.interior), 0.05, "\(scheme): eye interior flooded at \(probes.interior)")
            let moon = px.rgb(probes.moon)
            switch scheme {
            case .light: XCTAssertLessThan(moon.luminance, 0.3, "light: idle ink is dark")
            case .dark: XCTAssertGreaterThan(moon.luminance, 0.7, "dark: idle ink is light")
            @unknown default: XCTFail("unexpected scheme")
            }
        }
    }

    @MainActor
    func testRunningStateTurnsOnlyTheMoonVioletAndKeepsTheEyeInteriorClear() throws {
        let probes = Probes(size: 17, scale: 2)
        let idle = try Raster.render(EyeMoonMarkView(isRunning: false, reduceMotion: true), scheme: .light, scale: 2)
        let active = try Raster.render(EyeMoonMarkView(isRunning: true, reduceMotion: true), scheme: .light, scale: 2)

        let idleMoon = idle.rgb(probes.moon)
        XCTAssertLessThan(idleMoon.saturation, 0.1, "idle moon is neutral: \(idleMoon)")
        let activeMoon = active.rgb(probes.moon)
        XCTAssertGreaterThan(active.alpha(probes.moon), 0.9)
        XCTAssertGreaterThan(activeMoon.saturation, 0.2, "active moon is tinted: \(activeMoon)")
        XCTAssertGreaterThan(activeMoon.blue, activeMoon.green, "active moon leans violet, not warm: \(activeMoon)")
        XCTAssertGreaterThan(activeMoon.blue, activeMoon.red, "active moon leans violet, not warm: \(activeMoon)")
        XCTAssertGreaterThan(activeMoon.luminance, 0.3, "restrained violet, not a dark fill: \(activeMoon)")

        XCTAssertLessThan(idle.alpha(probes.interior), 0.05, "eye interior stays clear while idle")
        XCTAssertLessThan(active.alpha(probes.interior), 0.05, "eye interior stays clear while running")
        XCTAssertGreaterThan(active.alpha(probes.outline), 0.5, "the outline is still drawn while running")
    }

    // MARK: - Helpers

    private func subpathCount(_ path: CGPath) -> Int {
        var moves = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moves += 1 }
        }
        return moves
    }

    /// Grid points worth probing, mapped into a rendered view of `size`
    /// points at `scale`: derived from the paths' own bounding boxes so the
    /// test follows the geometry rather than pinning magic numbers.
    private struct Probes {
        let outline: (Int, Int)
        let moon: (Int, Int)
        let interior: (Int, Int)

        init(size: CGFloat, scale: CGFloat) {
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let eyeBox = EyeMoonGeometry.eyeOutline(in: rect).boundingBoxOfPath
            let moonBox = EyeMoonGeometry.crescent(in: rect).boundingBoxOfPath
            let unit = size / EyeMoonGeometry.designSize
            func px(_ x: CGFloat, _ y: CGFloat) -> (Int, Int) { (Int((x * scale).rounded()), Int((y * scale).rounded())) }
            outline = px(eyeBox.minX + 0.3 * unit, eyeBox.midY)
            moon = px(moonBox.minX + 1.1 * unit, moonBox.midY)
            interior = px(moonBox.maxX + 2.5 * unit, moonBox.midY)
        }
    }
}

/// RGBA8 bitmap with the design's y-down orientation, drawn by CoreGraphics
/// or filled from a rendered SwiftUI view.
struct Raster {
    struct RGB: CustomStringConvertible {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
        var saturation: CGFloat {
            let hi = max(red, green, blue)
            let lo = min(red, green, blue)
            return hi == 0 ? 0 : (hi - lo) / hi
        }
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }

    let width: Int
    let height: Int
    private let data: [UInt8]

    var total: Int { width * height }

    init(size: Int, draw: (CGContext) -> Void) {
        self.init(width: size, height: size) { ctx in
            // Design coordinates are y-down; CoreGraphics bitmaps are y-up.
            ctx.translateBy(x: 0, y: CGFloat(size))
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
        }
    }

    private init(width: Int, height: Int, draw: (CGContext) -> Void) {
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            draw(ctx)
        }
        data = bytes
    }

    /// Renders a SwiftUI view under `scheme` at `scale` into a bitmap whose
    /// (0,0) is the view's top-left.
    @MainActor
    static func render<V: View>(_ view: V, scheme: ColorScheme, scale: CGFloat) throws -> Raster {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        return Raster(width: image.width, height: image.height) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private func offset(_ x: Int, _ y: Int) -> Int {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
        return (y * width + x) * 4
    }

    func alpha(_ x: Int, _ y: Int) -> CGFloat {
        CGFloat(data[offset(x, y) + 3]) / 255
    }

    func alpha(_ p: (Int, Int)) -> CGFloat { alpha(p.0, p.1) }

    /// Straight (un-premultiplied) colour at a pixel.
    func rgb(_ p: (Int, Int)) -> RGB {
        let o = offset(p.0, p.1)
        let a = max(CGFloat(data[o + 3]), 1)
        return RGB(red: CGFloat(data[o]) / a, green: CGFloat(data[o + 1]) / a, blue: CGFloat(data[o + 2]) / a)
    }

    func count(where pass: ((alpha: CGFloat, rgb: RGB)) -> Bool) -> Int {
        var n = 0
        for y in 0..<height {
            for x in 0..<width where pass((alpha(x, y), rgb((x, y)))) { n += 1 }
        }
        return n
    }
}
