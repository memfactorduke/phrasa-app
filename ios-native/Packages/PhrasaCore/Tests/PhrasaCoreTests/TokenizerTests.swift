import XCTest
@testable import PhrasaCore

final class TokenizerTests: XCTestCase {
    func testNormalizationStripsPunctuationAndLatinDiacritics() {
        XCTAssertEqual(ReaderTokenizer.normalizeWord("There's,"), "theres")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("Hello!"), "hello")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("café"), "cafe")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("naïve"), "naive")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("2024."), "2024")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("—"), "")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("..."), "")
    }

    func testNormalizationPreservesNonLatinWritingSystems() {
        XCTAssertEqual(ReaderTokenizer.normalizeWord("世界"), "世界")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("こんにちは"), "こんにちは")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("Привет"), "привет")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("مرحبا"), "مرحبا")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("नमस्ते"), "नमस्ते")
        XCTAssertFalse(ReaderTokenizer.normalizeWord("안녕하세요").isEmpty)
        XCTAssertEqual(ReaderTokenizer.normalizeWord("😀"), "")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("！？"), "")
    }

    func testTokenizePreservesRawWordsIndicesAndParagraphs() {
        let words = ReaderTokenizer.tokenize("Hello, world!")
        XCTAssertEqual(words.map(\.raw), ["Hello,", "world!"])
        XCTAssertEqual(words.map(\.normalized), ["hello", "world"])

        let indexed = ReaderTokenizer.tokenize("one two three")
        XCTAssertEqual(indexed.map(\.index), [0, 1, 2])

        let paragraphs = ReaderTokenizer.tokenize("first line\n\nsecond para")
        XCTAssertEqual(paragraphs.map(\.paragraph), [0, 0, 1, 1])
        XCTAssertEqual(ReaderTokenizer.tokenize("  a   b  ").map(\.raw), ["a", "b"])
    }

    func testUtteranceNormalizesAndDropsEmptyTokens() {
        XCTAssertEqual(
            ReaderTokenizer.normalizeUtterance("Um, the QUICK — fox"),
            ["um", "the", "quick", "fox"]
        )
    }

    func testChineseSegmentationMatchesExistingEngine() {
        let expected = ["我们", "今天", "发布", "新", "产品"]
        XCTAssertEqual(ReaderTokenizer.splitChunkWords("我们今天发布新产品"), expected)
        XCTAssertEqual(ReaderTokenizer.normalizeUtterance("我们今天发布新产品"), expected)

        let tokens = ReaderTokenizer.tokenize("我们今天发布新产品")
        XCTAssertEqual(tokens.map(\.normalized), expected)
        XCTAssertEqual(tokens.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertTrue(tokens.allSatisfy { $0.paragraph == 0 })
    }

    func testJapaneseSegmentationRoundTrips() {
        let text = "今日は皆さんに新しい製品を紹介します"
        let words = ReaderTokenizer.splitChunkWords(text)
        XCTAssertGreaterThan(words.count, 3)
        XCTAssertEqual(words.joined(), text)
        XCTAssertEqual(
            ReaderTokenizer.normalizeUtterance(text),
            ReaderTokenizer.tokenize(text).map(\.normalized)
        )
    }

    func testPunctuationStaysWithNeighboringCJKWords() {
        XCTAssertEqual(ReaderTokenizer.splitChunkWords("你好，世界。"), ["你好，", "世界。"])
        let quoted = ReaderTokenizer.splitChunkWords("「こんにちは」と言った")
        XCTAssertEqual(quoted.first, "「こんにちは」")
        XCTAssertEqual(quoted.joined(), "「こんにちは」と言った")

        let tokens = ReaderTokenizer.tokenize("你好，世界。")
        XCTAssertEqual(tokens.map(\.raw), ["你好，", "世界。"])
        XCTAssertEqual(tokens.map(\.normalized), ["你好", "世界"])
    }

    func testSpacedScriptsRemainSingleChunks() {
        XCTAssertEqual(ReaderTokenizer.splitChunkWords("hello,"), ["hello,"])
        XCTAssertEqual(ReaderTokenizer.splitChunkWords("Привет"), ["Привет"])
        XCTAssertEqual(ReaderTokenizer.splitChunkWords("안녕하세요"), ["안녕하세요"])
    }
}
