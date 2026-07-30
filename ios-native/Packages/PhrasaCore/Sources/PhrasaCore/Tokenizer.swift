import Foundation
import NaturalLanguage

/// A display token and the normalized value used to align recognized speech.
public struct ReaderToken: Equatable, Sendable {
    public let raw: String
    public let normalized: String
    public let paragraph: Int
    public let index: Int

    public init(raw: String, normalized: String, paragraph: Int, index: Int) {
        self.raw = raw
        self.normalized = normalized
        self.paragraph = paragraph
        self.index = index
    }
}

/// Pure text preparation shared by live recognition and the reader layout.
public enum ReaderTokenizer {
    /// Lowercase, compatibility-decompose, remove Latin accents, then retain
    /// Unicode letters, numbers, and marks from every writing system.
    public static func normalizeWord(_ word: String) -> String {
        let decomposed = word.lowercased().decomposedStringWithCompatibilityMapping
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.nonBaseCharacters)

        let scalars = decomposed.unicodeScalars.filter { scalar in
            // Match the web engine: remove the Latin combining-diacritic block,
            // while preserving marks required by Indic and other scripts.
            if (0x0300...0x036F).contains(scalar.value) { return false }
            return allowed.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Split a whitespace-delimited chunk. Chinese and Japanese chunks receive
    /// word segmentation so an unspaced recognition result remains matchable.
    public static func splitChunkWords(_ chunk: String) -> [String] {
        guard containsUnspacedScript(chunk) else { return [chunk] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(containsKana(chunk) ? .japanese : .simplifiedChinese)
        tokenizer.string = chunk
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: chunk.startIndex..<chunk.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        guard !ranges.isEmpty else { return [chunk] }

        var output: [String] = []
        output.reserveCapacity(ranges.count)
        for index in ranges.indices {
            let wordRange = ranges[index]
            let start = index == ranges.startIndex ? chunk.startIndex : wordRange.lowerBound
            let end = index + 1 < ranges.endIndex ? ranges[index + 1].lowerBound : chunk.endIndex
            // The range begins at the word itself (except leading punctuation
            // on the first token) and ends where the next word begins. This
            // naturally glues intervening punctuation to the previous word.
            output.append(String(chunk[start..<end]))
        }
        return output.filter { !$0.isEmpty }
    }

    /// Tokenize text, treating every run of newlines as a paragraph boundary.
    public static func tokenize(_ text: String) -> [ReaderToken] {
        let paragraphs = text.split(whereSeparator: \.isNewline)
        var tokens: [ReaderToken] = []
        var tokenIndex = 0

        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            for chunk in paragraph.split(whereSeparator: \.isWhitespace) {
                for raw in splitChunkWords(String(chunk)) {
                    tokens.append(
                        ReaderToken(
                            raw: raw,
                            normalized: normalizeWord(raw),
                            paragraph: paragraphIndex,
                            index: tokenIndex
                        )
                    )
                    tokenIndex += 1
                }
            }
        }
        return tokens
    }

    /// Normalize a speech result into matchable words, dropping punctuation-only tokens.
    public static func normalizeUtterance(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .flatMap { splitChunkWords(String($0)) }
            .map(normalizeWord)
            .filter { !$0.isEmpty }
    }

    private static func containsUnspacedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF: // Katakana
                true
            default:
                false
            }
        }
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
        }
    }
}
