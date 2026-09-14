import CoreGraphics

/// The night palette from the approved identity spec, as plain values.
/// SwiftUI colours are made from these next to the views (EyeMoonMark.swift);
/// the icon generator compiles this file directly, so nothing here needs
/// SwiftUI or AppKit. Semantic colours (warning red, system text) are not
/// branded and stay wherever they are used.
enum BrandPalette {
    struct RGB: Equatable, Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init(hex: UInt32) {
            red = CGFloat((hex >> 16) & 0xFF) / 255
            green = CGFloat((hex >> 8) & 0xFF) / 255
            blue = CGFloat(hex & 0xFF) / 255
        }

        var cgColor: CGColor {
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
        }
    }

    /// App icon tile.
    static let midnight = RGB(hex: 0x06012C)
    /// Pill background in the menu bar.
    static let charcoal = RGB(hex: 0x11151F)
    /// The mark on the app icon.
    static let moonWhite = RGB(hex: 0xEEF0F7)
    /// Active state: the moon while sleep is held, focus and hold rings.
    static let violet = RGB(hex: 0x9691D9)
}
