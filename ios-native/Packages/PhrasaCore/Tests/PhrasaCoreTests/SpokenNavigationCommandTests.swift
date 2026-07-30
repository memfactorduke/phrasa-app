import XCTest
@testable import PhrasaCore

final class SpokenNavigationCommandTests: XCTestCase {

    // MARK: - Positive phrases

    func testDocumentedPreviousParagraphPhrasesMatch() {
        let phrases = [
            "phrasa previous paragraph",
            "phrasa last paragraph",
            "phrasa prior paragraph",
            "phrasa go back paragraph",
            "phrasa back paragraph",
            "Phrasa Previous Paragraph!",
            "please say phrasa previous paragraph",
        ]
        for phrase in phrases {
            XCTAssertEqual(
                SpokenNavigationCommand.match(utterance: phrase),
                .previousParagraph,
                "Expected previous for \(phrase)"
            )
        }
    }

    func testDocumentedNextAndCurrentPhrasesMatch() {
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "phrasa next paragraph"),
            .nextParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "phrasa following paragraph"),
            .nextParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "phrasa forward paragraph"),
            .nextParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "phrasa current paragraph"),
            .currentParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "phrasa this paragraph"),
            .currentParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "phrasa restart paragraph"),
            .currentParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "phrasa repeat paragraph"),
            .currentParagraph
        )
    }

    func testWakeWordASRAliasesMatch() {
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "frasa previous paragraph"),
            .previousParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "frase next paragraph"),
            .nextParagraph
        )
    }

    // MARK: - Near-misses & ordinary script text

    func testBareParagraphLanguageWithoutPrefixDoesNotMatch() {
        let nearMisses = [
            "previous paragraph",
            "next paragraph",
            "current paragraph",
            "last paragraph",
            "go back paragraph",
            "the previous paragraph introduces our thesis",
            "in the next paragraph we explain the method",
            "restart this paragraph carefully",
            "forward paragraph later",
        ]
        for phrase in nearMisses {
            XCTAssertNil(
                SpokenNavigationCommand.match(utterance: phrase),
                "Must not match ordinary/script text: \(phrase)"
            )
        }
    }

    func testIncompleteOrWrongSuffixDoesNotMatch() {
        let incomplete = [
            "phrasa",
            "phrasa previous",
            "phrasa next",
            "phrasa paragraph",
            "phrasa previous line",
            "phrasa next section",
            "phrasa previous paragraphs",
            "phrasa go back",
            "phrasa previous paragraph please continue", // command must be suffix
        ]
        for phrase in incomplete {
            XCTAssertNil(
                SpokenNavigationCommand.match(utterance: phrase),
                "Incomplete/wrong form must not match: \(phrase)"
            )
        }
    }

    func testScriptContainingOrdinaryWordsNeverTriggersMidSentence() {
        let scripty = [
            "we move to the previous paragraph of the brief",
            "authors often end a paragraph then start the next paragraph",
            "please read the current paragraph aloud",
            "phrasa is mentioned but not a command here",
        ]
        for phrase in scripty {
            XCTAssertNil(SpokenNavigationCommand.match(utterance: phrase))
        }
    }

    // MARK: - Cooldown / repeat

    func testCooldownBlocksRapidRepeatThenAllows() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(SpokenNavigationCommand.allowsCommand(lastFiredAt: nil, now: t0))
        XCTAssertFalse(
            SpokenNavigationCommand.allowsCommand(
                lastFiredAt: t0,
                now: t0.addingTimeInterval(0.5)
            )
        )
        XCTAssertTrue(
            SpokenNavigationCommand.allowsCommand(
                lastFiredAt: t0,
                now: t0.addingTimeInterval(SpokenNavigationCommand.cooldownSeconds)
            )
        )
        XCTAssertTrue(
            SpokenNavigationCommand.allowsCommand(
                lastFiredAt: t0,
                now: t0.addingTimeInterval(SpokenNavigationCommand.cooldownSeconds + 0.01)
            )
        )
    }

    // MARK: - Paragraph boundaries

    func testParagraphTargetsResolveBoundaries() {
        let body = """
        alpha bravo charlie

        delta echo foxtrot

        golf hotel india
        """
        let tokens = ReaderTokenizer.tokenize(body)
        XCTAssertEqual(Set(tokens.map(\.paragraph)), [0, 1, 2])

        let p0 = tokens.first(where: { $0.paragraph == 0 })!.index
        let p1 = tokens.first(where: { $0.paragraph == 1 })!.index
        let p2 = tokens.first(where: { $0.paragraph == 2 })!.index
        let midP1 = tokens.last(where: { $0.paragraph == 1 })!.index

        // Mid paragraph 1 → previous lands at start of paragraph 0.
        XCTAssertEqual(
            SpokenNavigationCommand.targetTokenIndex(
                intent: .previousParagraph,
                tokens: tokens,
                currentIndex: midP1
            ),
            p0
        )
        // Mid paragraph 1 → next lands at start of paragraph 2.
        XCTAssertEqual(
            SpokenNavigationCommand.targetTokenIndex(
                intent: .nextParagraph,
                tokens: tokens,
                currentIndex: midP1
            ),
            p2
        )
        // Current reseats to start of containing paragraph.
        XCTAssertEqual(
            SpokenNavigationCommand.targetTokenIndex(
                intent: .currentParagraph,
                tokens: tokens,
                currentIndex: midP1
            ),
            p1
        )
        // Previous at first paragraph → start of paragraph 0 (not past start).
        XCTAssertEqual(
            SpokenNavigationCommand.targetTokenIndex(
                intent: .previousParagraph,
                tokens: tokens,
                currentIndex: p0 + 1
            ),
            p0
        )
        // Next at last paragraph → nil (no-op).
        XCTAssertNil(
            SpokenNavigationCommand.targetTokenIndex(
                intent: .nextParagraph,
                tokens: tokens,
                currentIndex: p2
            )
        )
    }

    func testEmptyTokensYieldNilTargets() {
        XCTAssertNil(
            SpokenNavigationCommand.targetTokenIndex(
                intent: .previousParagraph,
                tokens: [],
                currentIndex: 0
            )
        )
    }

    // MARK: - Transcription variants (normalize path)

    func testPunctuationAndCaseTranscriptionVariants() {
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "PHRASA, PREVIOUS PARAGRAPH."),
            .previousParagraph
        )
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "  phrasa   next   paragraph  "),
            .nextParagraph
        )
        // Accent-stripped path still exact on letters.
        XCTAssertEqual(
            SpokenNavigationCommand.match(
                normalizedWords: ReaderTokenizer.normalizeUtterance("Phrasá previous paragraph")
            ),
            .previousParagraph
        )
    }

    func testLongerPhraseWinsOverShorterSuffix() {
        // "go back paragraph" is longer than "back paragraph"; both map previous.
        XCTAssertEqual(
            SpokenNavigationCommand.match(utterance: "noise phrasa go back paragraph"),
            .previousParagraph
        )
    }
}
