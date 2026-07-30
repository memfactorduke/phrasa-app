import AppKit
import SwiftUI
import PhrasaDomain

/// Strict monochrome Phrasa product chrome for macOS.
/// Canvas pure black; ink pure white; system red only for destructive warnings.
enum MacDesign {
    static let canvas = Color(red: 0, green: 0, blue: 0)
    static let elevated = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let surfaceSecondary = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
    static let border = Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
    static let ink = Color.white
    static let muted = Color(red: 163 / 255, green: 163 / 255, blue: 163 / 255)
    static let danger = Color.red
    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 8
    static let pagePadding: CGFloat = 20
    static let minHitTarget: CGFloat = 28
    static let motionDuration: Double = 0.16

    static var motion: Animation {
        .easeOut(duration: motionDuration)
    }

    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : motion
    }
}

extension ReadingFont {
    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .hyperlegible:
            return NSFont(name: "AtkinsonHyperlegible-Regular", size: size)
                ?? NSFont.systemFont(ofSize: size)
        case .serif:
            let base = NSFont.systemFont(ofSize: size)
            if let descriptor = base.fontDescriptor.withDesign(.serif) {
                return NSFont(descriptor: descriptor, size: size) ?? base
            }
            return base
        case .sans:
            let base = NSFont.systemFont(ofSize: size)
            if let descriptor = base.fontDescriptor.withDesign(.rounded) {
                return NSFont(descriptor: descriptor, size: size) ?? base
            }
            return base
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .hyperlegible: .custom("Atkinson Hyperlegible", size: size)
        case .serif: .system(size: size, design: .serif)
        case .sans: .system(size: size, design: .rounded)
        case .mono: .system(size: size, design: .monospaced)
        }
    }
}

extension ReaderTheme {
    /// Strict monochrome stage looks (rebuild visual system). Stored raw values
    /// stay stable for settings/cloud decoding; only the paint is greyscale.
    var background: Color {
        switch self {
        case .stage, .contrast: Color(red: 0, green: 0, blue: 0)
        case .paper: Color(red: 1, green: 1, blue: 1)
        case .amber: Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
        case .sepia: Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
        }
    }

    var foreground: Color {
        switch self {
        case .stage, .contrast, .amber, .sepia: Color(red: 1, green: 1, blue: 1)
        case .paper: Color(red: 0, green: 0, blue: 0)
        }
    }

    var nsBackground: NSColor {
        switch self {
        case .stage, .contrast: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .paper: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .amber: NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
        case .sepia: NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
        }
    }

    var nsForeground: NSColor {
        switch self {
        case .stage, .contrast, .amber, .sepia: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .paper: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }
}
