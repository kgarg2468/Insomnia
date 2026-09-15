import CoreGraphics

/// The soft charcoal palette from the approved identity spec, as plain values.
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

    /// App icon tile: a mid charcoal grey.
    static let midnight = RGB(hex: 0x303336)
    /// Pill background in the menu bar: a deep charcoal.
    static let charcoal = RGB(hex: 0x17191B)
    /// The mark on the app icon: a warm off-white.
    static let moonWhite = RGB(hex: 0xE6E3DD)
    /// Active state: the blue-grey moon while sleep is held, focus and hold rings.
    static let violet = RGB(hex: 0xA6BBC3)
}
