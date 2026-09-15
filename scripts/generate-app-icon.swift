import CoreGraphics
import Foundation
import ImageIO

/// Renders the Insomnia app icon from the same geometry and palette the app
/// draws with. Not part of the SwiftPM targets: scripts/generate-app-icon.sh
/// compiles this file together with Sources/Insomnia/UI/EyeMoonGeometry.swift
/// and BrandPalette.swift, so there is one drawing and no pixel art to keep
/// in step.
///
///   generate-app-icon --png PATH --iconset DIR
///
/// Writes the 1024x1024 master PNG to PATH and every size `iconutil` needs
/// into DIR (an .iconset folder), each rendered straight from the vector
/// geometry at its own pixel size rather than downscaled. Output depends
/// only on this source, so re-running it reproduces the checked-in bytes.
@main
struct GenerateAppIcon {
    /// Apple's macOS icon layout: a rounded tile inset in the 1024 canvas
    /// (the margin is where the system draws its shadow), corners rounded
    /// at a fixed share of the tile side.
    static let canvas: CGFloat = 1024
    static let tileInset: CGFloat = 100
    static let cornerShare: CGFloat = 0.2237
    /// The 24-unit design grid's side as a share of the tile side.
    static let markShare: CGFloat = 0.76
    /// The outline never gets thinner than one device pixel, so the 16 and
    /// 32 pixel sizes keep a readable eye instead of a grey smudge.
    static let minimumStrokePixels: CGFloat = 1

    /// File name and pixel size of each iconset member.
    static let iconset: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var png: String?
        var iconsetDir: String?
        while !args.isEmpty {
            let flag = args.removeFirst()
            switch (flag, args.first) {
            case ("--png", .some(let value)):
                png = value
                args.removeFirst()
            case ("--iconset", .some(let value)):
                iconsetDir = value
                args.removeFirst()
            default:
                throw Failure(description: "usage: generate-app-icon --png PATH --iconset DIR")
            }
        }
        guard let png, let iconsetDir else {
            throw Failure(description: "usage: generate-app-icon --png PATH --iconset DIR")
        }

        try write(render(pixels: Int(canvas)), to: URL(fileURLWithPath: png))
        let dir = URL(fileURLWithPath: iconsetDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for member in iconset {
            try write(render(pixels: member.pixels), to: dir.appendingPathComponent("\(member.name).png"))
        }
    }

    /// The whole icon at `pixels` square: charcoal tile, moon-white mark.
    static func render(pixels: Int) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Failure(description: "could not create a \(pixels)px context")
        }
        // Work in canvas units, y-down like the geometry.
        let scale = CGFloat(pixels) / canvas
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)

        let tile = CGRect(x: tileInset, y: tileInset, width: canvas - 2 * tileInset, height: canvas - 2 * tileInset)
        let corner = tile.width * cornerShare
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(BrandPalette.midnight.cgColor)
        ctx.fillPath()

        let side = tile.width * markShare
        let mark = CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
        let stroke = max(EyeMoonGeometry.lineWidth(for: side), minimumStrokePixels / scale)
        ctx.setStrokeColor(BrandPalette.moonWhite.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(EyeMoonGeometry.eyeOutline(in: mark))
        ctx.strokePath()
        ctx.setFillColor(BrandPalette.moonWhite.cgColor)
        ctx.addPath(EyeMoonGeometry.crescent(in: mark))
        ctx.fillPath()

        guard let image = ctx.makeImage() else {
            throw Failure(description: "could not rasterise the \(pixels)px icon")
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure(description: "could not open \(url.path) for writing")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "could not write \(url.path)")
        }
    }
}
