import XCTest
@testable import PhrasaCore

/// Practical local measurements for a ~2,000-word script.
///
/// Timings are recorded for the release report. Assertions only fail on
/// pathological multi-second stalls so CI stays free of flaky wall-clock noise.
final class LargeScriptPerformanceTests: XCTestCase {
    private static let wordCount = 2_000

    private func makeTwoThousandWordScript() -> String {
        // Stable whitespace-delimited corpus with occasional paragraph breaks.
        var parts: [String] = []
        parts.reserveCapacity(Self.wordCount + Self.wordCount / 40)
        for index in 0..<Self.wordCount {
            if index > 0, index % 40 == 0 {
                parts.append("\n\n")
            }
            parts.append("word\(index % 97)")
        }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: " \n\n ", with: "\n\n")
    }

    func testTokenizeTwoThousandWordScriptCompletesWithoutPathologicalStall() {
        let body = makeTwoThousandWordScript()
        let started = CFAbsoluteTimeGetCurrent()
        let tokens = ReaderTokenizer.tokenize(body)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertGreaterThanOrEqual(tokens.count, 1_900)
        XCTAssertLessThanOrEqual(tokens.count, 2_100)
        // Pathological only: multi-second tokenize on a short script is a real defect.
        XCTAssertLessThan(elapsed, 2.0, "tokenize 2k words stalled (\(elapsed)s)")
        print(String(format: "PERF tokenize_2000_words=%.3fms tokens=%d", elapsed * 1_000, tokens.count))
    }

    func testAlignmentEngineHotPathOnTwoThousandTokensStaysBounded() {
        let body = makeTwoThousandWordScript()
        let tokens = ReaderTokenizer.tokenize(body)
        let spoken = tokens.prefix(200).map(\.normalized).filter { !$0.isEmpty }
        let engine = AlignmentEngine(tokens: tokens)

        let started = CFAbsoluteTimeGetCurrent()
        // Stream a clean prefix as a rolling recognition window (same shape as live speech).
        var recent: [String] = []
        var lastCursor = -1
        for word in spoken {
            recent.append(word)
            if recent.count > 4 { recent.removeFirst(recent.count - 4) }
            let result = engine.observe(recent)
            lastCursor = result.cursor
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertGreaterThan(lastCursor, 50, "clean 200-word prefix should advance cursor substantially")
        XCTAssertLessThan(elapsed, 3.0, "alignment hot path stalled (\(elapsed)s)")
        print(
            String(
                format: "PERF alignment_200_steps_on_2000_tokens=%.3fms cursor=%d",
                elapsed * 1_000,
                lastCursor
            )
        )
    }

    func testNormalizeHotPathScalesLinearlyForLargeCorpus() {
        let words = (0..<5_000).map { "Word-\($0)-Café" }
        let started = CFAbsoluteTimeGetCurrent()
        var normalizedCount = 0
        for word in words {
            let normalized = ReaderTokenizer.normalizeWord(word)
            if !normalized.isEmpty { normalizedCount += 1 }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(normalizedCount, words.count)
        XCTAssertLessThan(elapsed, 1.0, "normalize 5k words stalled (\(elapsed)s)")
        print(String(format: "PERF normalize_5000_words=%.3fms", elapsed * 1_000))
    }
}
