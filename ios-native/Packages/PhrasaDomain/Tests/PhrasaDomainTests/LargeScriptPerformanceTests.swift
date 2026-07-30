import XCTest
@testable import PhrasaDomain

/// Practical measurements for large-script domain hot paths.
/// Assertions fail only on pathological stalls, not tight wall-clock SLAs.
final class LargeScriptPerformanceTests: XCTestCase {
    private static let wordCount = 2_000

    private func makeBody() -> String {
        (0..<Self.wordCount).map { "word\($0 % 89)" }.joined(separator: " ")
    }

    func testContentSignatureForTwoThousandWordScriptIsStableAndBounded() {
        let script = ScriptDocument(title: "Keynote", body: makeBody())
        let started = CFAbsoluteTimeGetCurrent()
        let first = ScriptContentSignature.make(script)
        let second = ScriptContentSignature.make(title: script.title, body: script.body)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64) // SHA-256 hex
        XCTAssertLessThan(elapsed, 1.0, "content signature stalled (\(elapsed)s)")
        print(String(format: "PERF content_signature_2000_words=%.3fms", elapsed * 1_000))
    }

    func testResumeBookmarkValidationOnLargeScriptStaysBounded() {
        let script = ScriptDocument(title: "Keynote", body: makeBody())
        let bookmark = ResumeBookmark(
            scriptID: script.id,
            focusTokenIndex: 900,
            speedProgress: 0.45,
            contentSignature: ScriptContentSignature.make(script),
            mode: .speed,
            speedWPM: 160
        )

        let started = CFAbsoluteTimeGetCurrent()
        let valid = bookmark.validated(against: script)
        var edited = script
        edited.body += " appendix"
        let invalid = bookmark.validated(against: edited)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(valid?.focusTokenIndex, 900)
        XCTAssertNil(invalid)
        XCTAssertEqual(
            bookmark.effectiveSpeedProgress(tokenCount: Self.wordCount),
            0.45,
            accuracy: 0.0001
        )
        XCTAssertLessThan(elapsed, 1.0, "resume validation stalled (\(elapsed)s)")
        print(String(format: "PERF resume_validate_2000_words=%.3fms", elapsed * 1_000))
    }

    func testFindLineMatchingOnTwoThousandWordBodyStaysBounded() {
        let paragraphs = (0..<40).map { paragraph in
            let words = (0..<50).map { "line\(paragraph)w\($0)" }.joined(separator: " ")
            return "Section \(paragraph) marker-\(paragraph) \(words)"
        }
        let body = paragraphs.joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(
            body.split(whereSeparator: \.isWhitespace).count,
            1_900
        )

        let started = CFAbsoluteTimeGetCurrent()
        let first = FindLineMatching.firstMatchRange(in: body, query: "marker-25")
        let second = FindLineMatching.firstMatchRange(
            in: body,
            query: "marker-25",
            fromUTF16Offset: (first?.location ?? 0) + 1
        )
        let line = FindLineMatching.lineNumber(in: body, utf16Offset: first?.location ?? 0)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertNotNil(first)
        // Wrap search should eventually re-find the only occurrence.
        XCTAssertEqual(second?.location, first?.location)
        XCTAssertEqual(line, 26)
        XCTAssertLessThan(elapsed, 1.0, "find-line on 2k-word body stalled (\(elapsed)s)")
        print(String(format: "PERF find_line_2000_words=%.3fms line=%d", elapsed * 1_000, line))
    }
}
