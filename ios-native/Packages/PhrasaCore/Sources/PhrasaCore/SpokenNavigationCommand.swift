import Foundation

/// Voice-mode paragraph navigation intents.
///
/// These never advance alignment; the reader reseats both engines when a
/// command fires so subsequent speech cannot snap the cursor back.
public enum SpokenNavigationIntent: String, Equatable, Sendable, CaseIterable {
    case previousParagraph
    case nextParagraph
    case currentParagraph
}

/// Fail-safe spoken navigation for voice-follow.
///
/// ## Supported phrases (after normalization)
///
/// All commands require the deliberate wake word **phrasa** (or ASR variants
/// `frasa` / `frase`) as the first token of the command. Bare script language
/// such as “previous paragraph” alone never matches.
///
/// | Intent | Exact normalized phrases |
/// |--------|--------------------------|
/// | Previous paragraph | `phrasa previous paragraph`, `phrasa last paragraph`, `phrasa prior paragraph`, `phrasa go back paragraph`, `phrasa back paragraph` |
/// | Next paragraph | `phrasa next paragraph`, `phrasa following paragraph`, `phrasa forward paragraph` |
/// | Current paragraph | `phrasa current paragraph`, `phrasa this paragraph`, `phrasa restart paragraph`, `phrasa repeat paragraph` |
///
/// ## Recognition behavior
///
/// 1. Normalize the recognition tail with ``ReaderTokenizer/normalizeUtterance(_:)``.
/// 2. Match only when a documented phrase is a **suffix** of that tail (rolling
///    ASR may prefix earlier script words).
/// 3. Matching is exact on normalized tokens — no fuzzy word matching — so
///    ordinary script text cannot accidentally fire.
/// 4. Callers should enforce ``cooldownSeconds`` so a single utterance cannot
///    multi-fire while the tail revises.
/// 5. On fire, jump to the first display token of the target paragraph
///    (``targetTokenIndex(intent:tokens:currentIndex:)``).
public enum SpokenNavigationCommand: Sendable {
    /// Primary wake word (product name).
    public static let commandPrefix = "phrasa"

    /// Acceptable single-token ASR substitutions for the wake word only.
    public static let commandPrefixAliases: Set<String> = ["phrasa", "frasa", "frase"]

    /// Minimum gap between successful navigations.
    public static let cooldownSeconds: TimeInterval = 1.25

    /// Canonical (prefix-normalized) phrase → intent pairs for docs and tests.
    public static let documentedPhrases: [(phrase: String, intent: SpokenNavigationIntent)] = [
        ("phrasa previous paragraph", .previousParagraph),
        ("phrasa last paragraph", .previousParagraph),
        ("phrasa prior paragraph", .previousParagraph),
        ("phrasa go back paragraph", .previousParagraph),
        ("phrasa back paragraph", .previousParagraph),
        ("phrasa next paragraph", .nextParagraph),
        ("phrasa following paragraph", .nextParagraph),
        ("phrasa forward paragraph", .nextParagraph),
        ("phrasa current paragraph", .currentParagraph),
        ("phrasa this paragraph", .currentParagraph),
        ("phrasa restart paragraph", .currentParagraph),
        ("phrasa repeat paragraph", .currentParagraph),
    ]

    /// Pure matcher over already-normalized speech words.
    public static func match(normalizedWords: [String]) -> SpokenNavigationIntent? {
        guard !normalizedWords.isEmpty else { return nil }
        let patterns = compiledPatterns
        // Prefer longer phrases so "go back paragraph" wins over shorter tails.
        for pattern in patterns {
            let count = pattern.tokens.count
            guard normalizedWords.count >= count else { continue }
            let suffix = normalizedWords.suffix(count)
            if zip(suffix, pattern.tokens).allSatisfy({ $0 == $1 }) {
                return pattern.intent
            }
        }
        return nil
    }

    /// Convenience over a raw recognition tail string.
    public static func match(utterance: String) -> SpokenNavigationIntent? {
        match(normalizedWords: ReaderTokenizer.normalizeUtterance(utterance))
    }

    /// First display-token index of the paragraph this intent targets.
    ///
    /// - Previous at paragraph 0 → start of the current paragraph (not past start).
    /// - Next with no following paragraph → `nil` (no-op).
    /// - Current → start of the paragraph containing `currentIndex`.
    public static func targetTokenIndex(
        intent: SpokenNavigationIntent,
        tokens: [ReaderToken],
        currentIndex: Int
    ) -> Int? {
        guard !tokens.isEmpty else { return nil }
        let clamped = max(0, min(currentIndex, tokens.count - 1))
        let currentParagraph = tokens[clamped].paragraph

        switch intent {
        case .currentParagraph:
            return firstTokenIndex(ofParagraph: currentParagraph, in: tokens)
        case .previousParagraph:
            if currentParagraph <= 0 {
                return firstTokenIndex(ofParagraph: 0, in: tokens)
            }
            return firstTokenIndex(ofParagraph: currentParagraph - 1, in: tokens)
        case .nextParagraph:
            return firstTokenIndex(ofParagraph: currentParagraph + 1, in: tokens)
        }
    }

    public static func allowsCommand(
        lastFiredAt: Date?,
        now: Date,
        cooldown: TimeInterval = cooldownSeconds
    ) -> Bool {
        guard let lastFiredAt else { return true }
        return now.timeIntervalSince(lastFiredAt) >= cooldown
    }

    // MARK: - Internals

    private struct Pattern: Sendable {
        let tokens: [String]
        let intent: SpokenNavigationIntent
    }

    /// Expanded patterns with wake-word aliases, longest-first.
    private static let compiledPatterns: [Pattern] = {
        var patterns: [Pattern] = []
        for entry in documentedPhrases {
            let parts = entry.phrase.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = parts.first, first == commandPrefix, parts.count > 1 else { continue }
            let rest = Array(parts.dropFirst())
            for prefix in commandPrefixAliases {
                patterns.append(Pattern(tokens: [prefix] + rest, intent: entry.intent))
            }
        }
        return patterns.sorted { $0.tokens.count > $1.tokens.count }
    }()

    private static func firstTokenIndex(ofParagraph paragraph: Int, in tokens: [ReaderToken]) -> Int? {
        tokens.first(where: { $0.paragraph == paragraph })?.index
    }
}
