import Foundation

/// Word-level fuzzy comparison tuned for imperfect speech recognition.
public enum FuzzyMatcher {
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for",
        "is", "are", "was", "were", "be", "it", "its", "this", "that", "with", "as",
        "i", "you", "he", "she", "we", "they", "me", "my", "your", "so", "if", "by",
        "do", "no", "not", "up", "out", "am", "us", "our",
        "where", "how", "why", "what", "when", "who", "which",
        "here", "there", "now", "then",
    ]

    public static func wordWeight(_ word: String) -> Double {
        guard !word.isEmpty else { return 0 }
        if stopwords.contains(word) { return 0.35 }
        // Digit-bearing tokens are identity-critical (chapter2, covid19, room3).
        if containsDigit(word) { return 1.3 }
        if word.count >= 7 { return 1.3 }
        if word.count >= 4 { return 1.0 }
        return 0.7
    }

    /// True when either side is empty-safe equal, or fuzzy-similar without
    /// digit identity loss. Digit-bearing tokens only match exactly so that
    /// `chapter2`/`chapter3` and `covid19`/`covid20` never fuzzy-match.
    public static func wordsSimilar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return !lhs.isEmpty }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }

        // Digits are identity-bearing; never fuzzy-match across digit differences.
        if containsDigit(lhs) || containsDigit(rhs) {
            return false
        }

        let maximumLength = max(lhs.count, rhs.count)
        if maximumLength >= 4 {
            let distance = levenshteinDistance(lhs, rhs)
            if distance <= 1 { return true }
            if maximumLength >= 8, distance <= 2 { return true }
        }

        let lhsCode = phoneticCode(lhs)
        return !lhsCode.isEmpty && lhsCode == phoneticCode(rhs)
    }

    static func containsDigit(_ word: String) -> Bool {
        word.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    public static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftIndex in left.indices {
            current[0] = leftIndex + 1
            for rightIndex in right.indices {
                let substitution = previous[rightIndex] + (left[leftIndex] == right[rightIndex] ? 0 : 1)
                current[rightIndex + 1] = min(
                    min(previous[rightIndex + 1] + 1, current[rightIndex] + 1),
                    substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    /// A compact metaphone-style key for English speech-recognition errors.
    /// It intentionally focuses on consonant sound structure and the common
    /// silent/digraph rules exercised by Phrasa's production corpus.
    static func phoneticCode(_ input: String) -> String {
        var word = input.lowercased().filter { $0.isASCII && $0.isLetter }
        guard !word.isEmpty else { return "" }

        if word.hasPrefix("wr") { word.removeFirst() }
        if word.hasPrefix("kn") || word.hasPrefix("gn") || word.hasPrefix("pn") {
            word.removeFirst()
        }
        if word.hasPrefix("who") { word.removeFirst() }

        word = removingIntervocalicW(from: word)
        let replacements: [(String, String)] = [
            ("ght", "t"), ("gh", ""), ("th", "0"), ("ph", "f"),
            ("sh", "x"), ("ch", "x"), ("tch", "x"), ("ck", "k"),
            ("qu", "k"), ("dg", "j"),
        ]
        for (source, replacement) in replacements {
            word = word.replacingOccurrences(of: source, with: replacement)
        }

        var result = ""
        var previous: Character?
        for character in word {
            let encoded: Character?
            switch character {
            case "a", "e", "i", "o", "u", "y", "h", "w": encoded = nil
            case "c", "k", "q": encoded = "k"
            case "s", "z": encoded = "s"
            case "v": encoded = "f"
            case "d": encoded = "t"
            case "g": encoded = "k"
            default: encoded = character
            }
            if let encoded, encoded != previous {
                result.append(encoded)
                previous = encoded
            }
        }
        return result
    }

    private static func removingIntervocalicW(from word: String) -> String {
        let characters = Array(word)
        guard characters.count >= 3 else { return word }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        return String(characters.enumerated().compactMap { index, character in
            if character == "w",
               index > 0,
               index + 1 < characters.count,
               vowels.contains(characters[index - 1]),
               vowels.contains(characters[index + 1]) {
                return nil
            }
            return character
        })
    }
}
