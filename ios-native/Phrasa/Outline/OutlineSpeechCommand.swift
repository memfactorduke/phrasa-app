import Foundation
import PhrasaCore

/// Explicit outline navigation commands spoken by the presenter.
/// Isolated pure parser so a future shared speech-command module can replace
/// or wrap this without touching coverage matching or UI.
enum OutlineSpeechCommand: Equatable, Sendable {
    case previous
    case next
}

/// Deterministic, offline-safe voice-command matching for Outline mode.
///
/// Safety contract (aligned with regular voice navigation wake style):
/// - Commands require a deliberate wake word plus an action phrase.
///   User-facing: **Phrasa previous point** and **Phrasa next point**.
/// - ASR may mishear the brand; only the safe aliases **Frasa** and **Frase**
///   are accepted as wake equivalents (never broader fuzzy matching).
/// - Bare `previous point`, `next point`, and other variants without the wake
///   word never match — a presenter may say them as ordinary content.
/// - The full command (wake + action) must sit at the **end** of the recent
///   word list (end-anchored).
/// - Any non-filler material before the command rejects the match so ordinary
///   content cannot trigger navigation.
/// - Matched commands are handled as navigation only (excluded from coverage).
enum OutlineSpeechCommandParser: Sendable {
    /// Canonical user-facing phrases shown in UI / accessibility help.
    static let userFacingNext = "Phrasa next point"
    static let userFacingPrevious = "Phrasa previous point"

    /// Concise on-stage hint for the two exact commands (no clutter).
    static let userFacingHint =
        "Say Phrasa next point or Phrasa previous point"

    /// Wake tokens: canonical brand + the only allowed ASR mishears.
    static let wakeWords: Set<String> = [
        "phrasa",
        "frasa",
        "frase",
    ]

    /// Words allowed immediately before a command phrase (disfluencies + mild framing).
    static let fillerWords: Set<String> = [
        "please", "um", "uh", "erm", "okay", "ok", "alright", "right",
        "so", "now", "just", "go", "to", "the", "a", "one", "my",
    ]

    /// Action tails after the wake word. Wake is required and checked separately.
    private static let actionTemplates: [(command: OutlineSpeechCommand, action: [String])] = [
        (.previous, ["previous", "point"]),
        (.next, ["next", "point"]),
    ]

    /// Match a raw recognition tail. Empty / non-command text → nil.
    static func match(utterance: String) -> OutlineSpeechCommand? {
        match(normalizedWords: ReaderTokenizer.normalizeUtterance(utterance))
    }

    /// Match already-normalized words from the rolling speech tail.
    static func match(normalizedWords words: [String]) -> OutlineSpeechCommand? {
        guard !words.isEmpty else { return nil }

        for template in actionTemplates {
            // Full phrase = wake + action (e.g. phrasa next point → 3 tokens).
            let phraseCount = 1 + template.action.count
            guard words.count >= phraseCount else { continue }

            let suffix = Array(words.suffix(phraseCount))
            let wake = suffix[0]
            let action = Array(suffix.dropFirst())
            guard wakeWords.contains(wake), action == template.action else { continue }

            let prefix = Array(words.dropLast(phraseCount))
            // Reject when any non-filler word precedes the command in this tail.
            // That keeps "discuss next point" / bare "next point" inert.
            if prefix.allSatisfy({ fillerWords.contains($0) }) {
                return template.command
            }
        }
        return nil
    }
}
