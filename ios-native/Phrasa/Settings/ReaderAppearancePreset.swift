import Foundation
import SwiftUI

/// The presentation-only portion of reader settings.
///
/// Looks intentionally exclude playback mode, speed, scroll behavior, voice
/// language, and pacing. Applying a look can never surprise a presenter by
/// changing how the prompter moves or listens.
struct ReaderAppearance: Codable, Equatable, Sendable {
    var font: ReadingFont
    var fontSize: Double
    var lineHeight: Double
    var horizontalMargin: Double
    var alignment: ReadingAlignment
    var theme: ReaderTheme
    var mirrorHorizontal: Bool
    var mirrorVertical: Bool
    var focusPosition: Double

    init(settings: ReaderSettings) {
        font = settings.font
        fontSize = settings.fontSize
        lineHeight = settings.lineHeight
        horizontalMargin = settings.horizontalMargin
        alignment = settings.alignment
        theme = settings.theme
        mirrorHorizontal = settings.mirrorHorizontal
        mirrorVertical = settings.mirrorVertical
        focusPosition = settings.focusPosition
    }

    func applying(to settings: ReaderSettings) -> ReaderSettings {
        var result = settings
        result.font = font
        result.fontSize = fontSize
        result.lineHeight = lineHeight
        result.horizontalMargin = horizontalMargin
        result.alignment = alignment
        result.theme = theme
        result.mirrorHorizontal = mirrorHorizontal
        result.mirrorVertical = mirrorVertical
        result.focusPosition = focusPosition
        result.normalize()
        return result
    }
}

struct ReaderAppearancePreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var appearance: ReaderAppearance
    var isBuiltIn: Bool

    static let builtIns: [ReaderAppearancePreset] = {
        let defaults = ReaderSettings()

        var beamSplitter = defaults
        beamSplitter.mirrorHorizontal = true
        beamSplitter.fontSize = 72

        var largePrint = defaults
        largePrint.fontSize = 96
        largePrint.horizontalMargin = 0.06
        largePrint.lineHeight = 1.55

        var paper = defaults
        paper.theme = .paper
        paper.font = .serif

        var highContrast = defaults
        highContrast.theme = .contrast
        highContrast.fontSize = 64

        return [
            ReaderAppearancePreset(
                id: "builtin:beam-splitter",
                name: "Beam-splitter",
                appearance: ReaderAppearance(settings: beamSplitter),
                isBuiltIn: true
            ),
            ReaderAppearancePreset(
                id: "builtin:large-print",
                name: "Large print",
                appearance: ReaderAppearance(settings: largePrint),
                isBuiltIn: true
            ),
            ReaderAppearancePreset(
                id: "builtin:paper",
                name: "Paper",
                appearance: ReaderAppearance(settings: paper),
                isBuiltIn: true
            ),
            ReaderAppearancePreset(
                id: "builtin:high-contrast",
                name: "High contrast",
                appearance: ReaderAppearance(settings: highContrast),
                isBuiltIn: true
            )
        ]
    }()
}

enum ReaderAppearancePresetStore {
    private static let key = "phrasa.reader.appearance-presets"

    static func load() -> [ReaderAppearancePreset] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([ReaderAppearancePreset].self, from: data)
        else {
            return []
        }
        return decoded.filter { !$0.isBuiltIn && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func save(_ presets: [ReaderAppearancePreset]) {
        guard let data = try? JSONEncoder().encode(presets.filter { !$0.isBuiltIn }) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension ReaderTheme {
    /// Focus/selection accent stays monochrome against each stage background.
    var readerAccent: Color { foreground }
}
