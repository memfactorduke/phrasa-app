import Foundation
import CryptoKit

/// Canonical resume state for a script. Speed progress and voice token progress
/// are separate domain values; a content signature prevents restoring into an
/// edited script that no longer matches the saved focus. Effective mode and
/// speed are restored with the bookmark so the stage reopens in the same path.
public struct ResumeBookmark: Codable, Equatable, Hashable, Sendable {
    public var scriptID: UUID
    /// Focus token index for voice-follow and for speed mode when both are stored.
    public var focusTokenIndex: Int
    /// Fractional speed progress in `0...1`, independent of voice tokens.
    public var speedProgress: Double?
    public var contentSignature: String
    public var savedAt: Date
    /// Playback path in effect when the bookmark was saved (optional for v1 archives).
    public var mode: ReaderMode?
    /// Effective speed in WPM when the bookmark was saved (optional for v1 archives).
    public var speedWPM: Double?

    public init(
        scriptID: UUID,
        focusTokenIndex: Int,
        speedProgress: Double? = nil,
        contentSignature: String,
        savedAt: Date = .now,
        mode: ReaderMode? = nil,
        speedWPM: Double? = nil
    ) {
        self.scriptID = scriptID
        self.focusTokenIndex = max(0, focusTokenIndex)
        if let speedProgress {
            self.speedProgress = min(max(speedProgress, 0), 1)
        } else {
            self.speedProgress = nil
        }
        self.contentSignature = contentSignature
        self.savedAt = savedAt
        self.mode = mode
        if let speedWPM {
            self.speedWPM = speedWPM.clamped(to: 40...400)
        } else {
            self.speedWPM = nil
        }
    }

    /// Returns the bookmark only when the script body/title still match the
    /// signature captured at save time. Incompatible resumes are discarded.
    public func validated(against script: ScriptDocument) -> ResumeBookmark? {
        guard script.id == scriptID else { return nil }
        guard contentSignature == ScriptContentSignature.make(script) else { return nil }
        return self
    }

    /// Effective fractional progress for the speed prompter (token ratio fallback).
    public func effectiveSpeedProgress(tokenCount: Int) -> Double {
        if let speedProgress { return speedProgress }
        guard tokenCount > 1 else { return 0 }
        return (Double(focusTokenIndex) / Double(tokenCount - 1)).clamped(to: 0...1)
    }
}

/// Stable content signature used by resume and other local progress gates.
/// This is intentionally independent of cloud sync fingerprinting so local
/// resume cannot be broken by remote metadata changes.
public enum ScriptContentSignature {
    public static func make(_ script: ScriptDocument) -> String {
        make(title: script.title, body: script.body)
    }

    public static func make(title: String, body: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled script"
            : title
        var fields: [String] = []
        func append(_ value: String) {
            fields.append("\(value.utf8.count):\(value)")
        }
        append("phrasa-content-v1")
        append(normalizedTitle)
        append(body)
        let digest = SHA256.hash(data: Data(fields.joined().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Completeness recap values produced by a reading session. The UI shows the
/// latest recap rather than an analytics dashboard.
public struct ReadingRecap: Codable, Equatable, Hashable, Sendable {
    public var scriptID: UUID
    public var activeDuration: TimeInterval
    public var averageWPM: Double
    public var targetDuration: TimeInterval?
    public var completedAt: Date
    public var runCount: Int
    public var resume: ResumeBookmark?

    public init(
        scriptID: UUID,
        activeDuration: TimeInterval,
        averageWPM: Double,
        targetDuration: TimeInterval? = nil,
        completedAt: Date = .now,
        runCount: Int = 1,
        resume: ResumeBookmark? = nil
    ) {
        self.scriptID = scriptID
        self.activeDuration = max(0, activeDuration)
        self.averageWPM = max(0, averageWPM)
        self.targetDuration = targetDuration
        self.completedAt = completedAt
        self.runCount = max(1, runCount)
        self.resume = resume
    }

    public var targetDifference: TimeInterval? {
        guard let targetDuration else { return nil }
        return activeDuration - targetDuration
    }
}
