import Foundation

/// Platform-neutral reader mode. UI presentation lives in the app layer.
public enum ReaderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case speed
    case voice
    public var id: Self { self }
    public var label: String { rawValue.capitalized }
}

public enum ScrollStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case continuous
    case line
    public var id: Self { self }
    public var label: String { rawValue.capitalized }
}

public enum ReadingFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case hyperlegible
    case serif
    case sans
    case mono
    public var id: Self { self }
    public var label: String { rawValue.capitalized }
}

public enum ReaderTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case stage
    case paper
    case amber
    case contrast
    case sepia
    public var id: Self { self }
    /// Human labels for monochrome stage looks. Raw values stay stable for
    /// settings and cloud decoding (including legacy amber/sepia keys).
    public var label: String {
        switch self {
        case .stage: "Stage"
        case .paper: "Paper"
        case .amber: "Elevated"
        case .contrast: "High contrast"
        case .sepia: "Dim"
        }
    }
}

public enum ReadingAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading
    case center
    public var id: Self { self }
    public var label: String { rawValue.capitalized }
}

/// Configurable pre-roll before Speed mode starts from the beginning of a script.
public enum SpeedCountdown: Int, Codable, CaseIterable, Identifiable, Sendable {
    case off = 0
    case fiveSeconds = 5
    case fifteenSeconds = 15

    public var id: Self { self }
    public static let `default`: SpeedCountdown = .fiveSeconds
    public var seconds: Int { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .fiveSeconds: "5 seconds"
        case .fifteenSeconds: "15 seconds"
        }
    }

    public var shortLabel: String {
        switch self {
        case .off: "Off"
        case .fiveSeconds: "5s"
        case .fifteenSeconds: "15s"
        }
    }

    public var displaySequence: [Int] {
        guard rawValue > 0 else { return [] }
        return Array(stride(from: rawValue, through: 1, by: -1))
    }
}

/// Pure policy for when Speed mode should show a start countdown.
public enum SpeedModeStartPolicy: Sendable {
    public static let nearStartThreshold: Double = 0.01

    public static func shouldBeginWithCountdown(
        mode: ReaderMode,
        progress: Double,
        countdown: SpeedCountdown,
        nearStartThreshold: Double = nearStartThreshold
    ) -> Bool {
        mode == .speed
            && progress < nearStartThreshold
            && countdown.seconds > 0
    }
}

/// Durable reader preferences. Bounds are enforced by `normalize()`.
public struct ReaderSettings: Codable, Equatable, Sendable {
    public var mode: ReaderMode = .speed
    public var scrollStyle: ScrollStyle = .continuous
    public var font: ReadingFont = .hyperlegible
    public var fontSize: Double = 56
    public var lineHeight: Double = 1.45
    public var horizontalMargin: Double = 0.12
    public var alignment: ReadingAlignment = .leading
    public var theme: ReaderTheme = .stage
    public var mirrorHorizontal = false
    public var mirrorVertical = false
    /// Vertical position of the reading focus band (0 = top, 1 = bottom).
    /// Fresh installs default to 25%; explicit persisted values are never migrated.
    public var focusPosition: Double = 0.25
    public var speedWPM: Double = 140
    public var speedCountdown: SpeedCountdown = .default
    public var recognitionLanguage = "en-US"
    public var showPacing = true
    public var targetDuration: TimeInterval?

    public init(
        mode: ReaderMode = .speed,
        scrollStyle: ScrollStyle = .continuous,
        font: ReadingFont = .hyperlegible,
        fontSize: Double = 56,
        lineHeight: Double = 1.45,
        horizontalMargin: Double = 0.12,
        alignment: ReadingAlignment = .leading,
        theme: ReaderTheme = .stage,
        mirrorHorizontal: Bool = false,
        mirrorVertical: Bool = false,
        focusPosition: Double = 0.25,
        speedWPM: Double = 140,
        speedCountdown: SpeedCountdown = .default,
        recognitionLanguage: String = "en-US",
        showPacing: Bool = true,
        targetDuration: TimeInterval? = nil
    ) {
        self.mode = mode
        self.scrollStyle = scrollStyle
        self.font = font
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.horizontalMargin = horizontalMargin
        self.alignment = alignment
        self.theme = theme
        self.mirrorHorizontal = mirrorHorizontal
        self.mirrorVertical = mirrorVertical
        self.focusPosition = focusPosition
        self.speedWPM = speedWPM
        self.speedCountdown = speedCountdown
        self.recognitionLanguage = recognitionLanguage
        self.showPacing = showPacing
        self.targetDuration = targetDuration
    }

    public mutating func normalize() {
        fontSize = fontSize.clamped(to: 20...160)
        lineHeight = lineHeight.clamped(to: 1...2.4)
        horizontalMargin = horizontalMargin.clamped(to: 0...0.4)
        focusPosition = focusPosition.clamped(to: 0.15...0.85)
        speedWPM = speedWPM.clamped(to: 40...400)
        // Horizontal and vertical mirror are mutually exclusive unless a tested
        // optical use case proves otherwise (rebuild feature contract).
        if mirrorVertical { mirrorHorizontal = false }
        if let targetDuration, targetDuration < 15 { self.targetDuration = nil }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, scrollStyle, font, fontSize, lineHeight, horizontalMargin
        case alignment, theme, mirrorHorizontal, mirrorVertical, focusPosition
        case speedWPM, speedCountdown, recognitionLanguage, showPacing, targetDuration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReaderSettings()
        mode = try values.decodeIfPresent(ReaderMode.self, forKey: .mode) ?? defaults.mode
        scrollStyle = try values.decodeIfPresent(ScrollStyle.self, forKey: .scrollStyle) ?? defaults.scrollStyle
        font = try values.decodeIfPresent(ReadingFont.self, forKey: .font) ?? defaults.font
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? defaults.lineHeight
        horizontalMargin = try values.decodeIfPresent(Double.self, forKey: .horizontalMargin) ?? defaults.horizontalMargin
        alignment = try values.decodeIfPresent(ReadingAlignment.self, forKey: .alignment) ?? defaults.alignment
        theme = try values.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? defaults.theme
        mirrorHorizontal = try values.decodeIfPresent(Bool.self, forKey: .mirrorHorizontal) ?? defaults.mirrorHorizontal
        mirrorVertical = try values.decodeIfPresent(Bool.self, forKey: .mirrorVertical) ?? defaults.mirrorVertical
        focusPosition = try values.decodeIfPresent(Double.self, forKey: .focusPosition) ?? defaults.focusPosition
        speedWPM = try values.decodeIfPresent(Double.self, forKey: .speedWPM) ?? defaults.speedWPM
        if let raw = try? values.decodeIfPresent(Int.self, forKey: .speedCountdown),
           let countdown = SpeedCountdown(rawValue: raw) {
            speedCountdown = countdown
        } else {
            speedCountdown = defaults.speedCountdown
        }
        recognitionLanguage = try values.decodeIfPresent(String.self, forKey: .recognitionLanguage) ?? defaults.recognitionLanguage
        showPacing = try values.decodeIfPresent(Bool.self, forKey: .showPacing) ?? defaults.showPacing
        targetDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .targetDuration)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(scrollStyle, forKey: .scrollStyle)
        try values.encode(font, forKey: .font)
        try values.encode(fontSize, forKey: .fontSize)
        try values.encode(lineHeight, forKey: .lineHeight)
        try values.encode(horizontalMargin, forKey: .horizontalMargin)
        try values.encode(alignment, forKey: .alignment)
        try values.encode(theme, forKey: .theme)
        try values.encode(mirrorHorizontal, forKey: .mirrorHorizontal)
        try values.encode(mirrorVertical, forKey: .mirrorVertical)
        try values.encode(focusPosition, forKey: .focusPosition)
        try values.encode(speedWPM, forKey: .speedWPM)
        try values.encode(speedCountdown, forKey: .speedCountdown)
        try values.encode(recognitionLanguage, forKey: .recognitionLanguage)
        try values.encode(showPacing, forKey: .showPacing)
        try values.encodeIfPresent(targetDuration, forKey: .targetDuration)
    }
}

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
