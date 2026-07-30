import SwiftUI

/// Strict monochrome Phrasa product chrome.
/// Canvas is pure black; ink is pure white; color appears only for system
/// destructive semantics. Corners stay square-to-8; no gradients or glow.
enum PhrasaDesign {
    static let canvas = Color(uiColor: UIColor(hex: 0x000000))
    static let elevated = Color(uiColor: UIColor(hex: 0x0A0A0A))
    static let surface = elevated
    static let surfaceSecondary = Color(uiColor: UIColor(hex: 0x121212))
    static let border = Color(uiColor: UIColor(hex: 0x1F1F1F))
    static let divider = border
    static let ink = Color(uiColor: UIColor(hex: 0xFFFFFF))
    static let muted = Color(uiColor: UIColor(hex: 0xA3A3A3))
    /// Destructive / warning only — never decorative brand color.
    static let danger = Color.red
    /// Compatibility aliases used by Settings/Cloud until those lanes adopt ink.
    static let ember = ink
    static let emberSoft = surfaceSecondary
    static let success = ink
    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 8
    static let pagePadding: CGFloat = 20
    static let minTouchTarget: CGFloat = 44
    static let motionDuration: Double = 0.16

    /// Flat fill for product surfaces (no gradients).
    static var canvasBackground: Color { canvas }

    /// Functional ease-out; callers should also respect Reduce Motion.
    static var motion: Animation {
        .easeOut(duration: motionDuration)
    }

    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : motion
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

struct PhrasaWordmark: View {
    var body: some View {
        Text("Phrasa")
            .font(.system(.title2, design: .default, weight: .semibold))
            .foregroundStyle(PhrasaDesign.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PhrasaIconBadge: View {
    let systemImage: String
    var size: CGFloat = 64

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(PhrasaDesign.ink)
            .frame(width: size, height: size)
            .background(PhrasaDesign.surfaceSecondary, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                    .stroke(PhrasaDesign.border, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct PhrasaEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.6)
            .foregroundStyle(PhrasaDesign.muted)
    }
}

struct PhrasaCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
                    .stroke(PhrasaDesign.border, lineWidth: 1)
            }
    }
}

extension View {
    func phrasaCard(padding: CGFloat = 16) -> some View {
        modifier(PhrasaCardModifier(padding: padding))
    }

    /// Prefer system SF chrome sizing with a minimum 44pt touch target.
    func phrasaTouchTarget(minSize: CGFloat = PhrasaDesign.minTouchTarget) -> some View {
        frame(minWidth: minSize, minHeight: minSize)
        .contentShape(Rectangle())
    }
}

struct PhrasaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(PhrasaDesign.canvas)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PhrasaDesign.minTouchTarget)
            .padding(.horizontal, 16)
            .background(
                PhrasaDesign.ink.opacity(buttonOpacity(pressed: configuration.isPressed)),
                in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .animation(PhrasaDesign.motion(reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private func buttonOpacity(pressed: Bool) -> Double {
        if !isEnabled { return 0.45 }
        return pressed ? 0.82 : 1
    }
}

struct PhrasaSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(PhrasaDesign.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PhrasaDesign.minTouchTarget)
            .padding(.horizontal, 16)
            .background(
                PhrasaDesign.surfaceSecondary.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                    .stroke(PhrasaDesign.border, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(PhrasaDesign.motion(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct MetricLabel: View {
    let words: Int
    let duration: TimeInterval

    var body: some View {
        Text("\(words.formatted()) words  ·  \(duration.compactDuration)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(PhrasaDesign.muted)
    }
}

extension TimeInterval {
    var compactDuration: String {
        let total = max(0, Int(self.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes):\(String(format: "%02d", seconds))" : "\(seconds)s"
    }
}
