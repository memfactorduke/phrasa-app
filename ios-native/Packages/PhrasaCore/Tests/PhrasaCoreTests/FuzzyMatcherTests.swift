import XCTest
@testable import PhrasaCore

final class FuzzyMatcherTests: XCTestCase {
    func testIdenticalWordsAndEditDistanceErrorsMatch() {
        XCTAssertTrue(FuzzyMatcher.wordsSimilar("hello", "hello"))
        XCTAssertTrue(FuzzyMatcher.wordsSimilar("teleprompter", "telepromper"))
        XCTAssertTrue(FuzzyMatcher.wordsSimilar("recording", "recordng"))
        XCTAssertEqual(FuzzyMatcher.levenshteinDistance("kitten", "sitting"), 3)
    }

    func testProductionHomophoneCorpusMatchesPhonetically() {
        let pairs = [
            ("there", "their"), ("write", "right"), ("to", "too"),
            ("made", "maid"), ("plain", "plane"), ("piece", "peace"),
            ("whole", "hole"), ("through", "threw"), ("break", "brake"),
            ("great", "grate"), ("flour", "flower"), ("sail", "sale"),
            ("meet", "meat"), ("pair", "pear"), ("tale", "tail"),
            ("steel", "steal"), ("course", "coarse"),
        ]
        for (lhs, rhs) in pairs {
            XCTAssertTrue(FuzzyMatcher.wordsSimilar(lhs, rhs), "Expected \(lhs) and \(rhs) to match")
        }
    }

    func testUnrelatedAndEmptyWordsDoNotMatch() {
        XCTAssertFalse(FuzzyMatcher.wordsSimilar("cat", "dog"))
        XCTAssertFalse(FuzzyMatcher.wordsSimilar("camera", "podcast"))
        XCTAssertFalse(FuzzyMatcher.wordsSimilar("", ""))
        XCTAssertFalse(FuzzyMatcher.wordsSimilar("a", ""))
    }

    func testDigitPairsRequireExactIdentity() {
        XCTAssertFalse(FuzzyMatcher.wordsSimilar("chapter2", "chapter3"))
        XCTAssertFalse(FuzzyMatcher.wordsSimilar("covid19", "covid20"))
        XCTAssertTrue(FuzzyMatcher.wordsSimilar("chapter2", "chapter2"))
        XCTAssertTrue(FuzzyMatcher.containsDigit("covid19"))
        XCTAssertFalse(FuzzyMatcher.containsDigit("covid"))
    }

    func testPositionalWeightsMatchWebEngine() {
        XCTAssertEqual(FuzzyMatcher.wordWeight(""), 0)
        XCTAssertEqual(FuzzyMatcher.wordWeight("the"), 0.35)
        XCTAssertEqual(FuzzyMatcher.wordWeight("where"), 0.35)
        XCTAssertEqual(FuzzyMatcher.wordWeight("fox"), 0.7)
        XCTAssertEqual(FuzzyMatcher.wordWeight("word"), 1.0)
        XCTAssertEqual(FuzzyMatcher.wordWeight("teleprompter"), 1.3)
        // Digit-bearing tokens stay high-weight so they dominate ranking.
        XCTAssertEqual(FuzzyMatcher.wordWeight("chapter2"), 1.3)
        XCTAssertEqual(FuzzyMatcher.wordWeight("room3"), 1.3)
    }
}
