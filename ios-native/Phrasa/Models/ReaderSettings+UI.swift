import SwiftUI
import UIKit

/// App-layer presentation for domain reader settings. Pure settings types live
/// in the shared domain sources under Packages/PhrasaDomain.
extension ReadingFont {
    func font(size: CGFloat) -> Font {
        switch self {
        case .hyperlegible: .custom("Atkinson Hyperlegible", size: size)
        case .serif: .system(size: size, design: .serif)
        case .sans: .system(size: size, design: .rounded)
        case .mono: .system(size: size, design: .monospaced)
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .hyperlegible:
            return UIFont(name: "AtkinsonHyperlegible-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
        case .serif:
            let base = UIFont.systemFont(ofSize: size).fontDescriptor
            let descriptor = base.withDesign(.serif) ?? base
            return UIFont(descriptor: descriptor, size: size)
        case .sans:
            let base = UIFont.systemFont(ofSize: size).fontDescriptor
            let descriptor = base.withDesign(.rounded) ?? base
            return UIFont(descriptor: descriptor, size: size)
        case .mono:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

extension ReaderTheme {
    /// Strict monochrome stage looks (rebuild visual system). Stored raw values
    /// stay stable for settings/cloud decoding; only the paint is greyscale.
    var background: Color { Color(uiColor: uiBackground) }
    var foreground: Color { Color(uiColor: uiForeground) }

    var uiBackground: UIColor {
        switch self {
        case .stage, .contrast: UIColor(hex: 0x000000)
        case .paper: UIColor(hex: 0xFFFFFF)
        case .amber: UIColor(hex: 0x0A0A0A)
        case .sepia: UIColor(hex: 0x121212)
        }
    }

    var uiForeground: UIColor {
        switch self {
        case .stage, .contrast, .amber, .sepia: UIColor(hex: 0xFFFFFF)
        case .paper: UIColor(hex: 0x000000)
        }
    }
}
