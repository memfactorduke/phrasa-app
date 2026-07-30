import XCTest
@testable import Phrasa

final class FindLineJumpTests: XCTestCase {
    func testFindLineJumpPresentationSelectsMatchAdvancesOffsetAndAnnouncesLine() throws {
        let body = "alpha line\nbeta line\ngamma line"
        let first = FindLineJumpPresentation.perform(
            body: body,
            query: "line",
            fromUTF16Offset: 0
        )

        XCTAssertEqual(first.status, "Line 1")
        XCTAssertEqual(first.announcement, "Found on line 1")
        let firstJump = try XCTUnwrap(first.jump)
        XCTAssertEqual(firstJump.range.location, 6)
        XCTAssertEqual(firstJump.range.length, 4)
        XCTAssertEqual(first.fromOffset, 10)

        let second = FindLineJumpPresentation.perform(
            body: body,
            query: "line",
            fromUTF16Offset: first.fromOffset
        )
        XCTAssertEqual(second.status, "Line 2")
        let secondJump = try XCTUnwrap(second.jump)
        XCTAssertGreaterThan(secondJump.range.location, firstJump.range.location)
        // Distinct jump ids so the TextKit editor re-applies even for equal ranges.
        XCTAssertNotEqual(firstJump.id, secondJump.id)
    }

    func testFindLineJumpPresentationWrapsAndReportsNoMatch() {
        let body = "alpha\nbeta\ngamma"
        let first = FindLineJumpPresentation.perform(
            body: body,
            query: "beta",
            fromUTF16Offset: 0
        )
        XCTAssertEqual(first.status, "Line 2")
        XCTAssertNotNil(first.jump)

        let wrapped = FindLineJumpPresentation.perform(
            body: body,
            query: "beta",
            fromUTF16Offset: first.fromOffset
        )
        XCTAssertEqual(wrapped.status, "Line 2")
        XCTAssertEqual(wrapped.jump?.range.location, first.jump?.range.location)

        let miss = FindLineJumpPresentation.perform(
            body: body,
            query: "missing",
            fromUTF16Offset: 0
        )
        XCTAssertEqual(miss.status, "No match")
        XCTAssertEqual(miss.announcement, "No match")
        XCTAssertNil(miss.jump)
        XCTAssertEqual(miss.fromOffset, 0)

        let blank = FindLineJumpPresentation.perform(
            body: body,
            query: "   ",
            fromUTF16Offset: 3
        )
        XCTAssertEqual(blank.status, "No match")
        XCTAssertNil(blank.jump)
        XCTAssertEqual(blank.fromOffset, 3)
    }

    func testScriptBodySelectionPolicyClampsAndRestoresRanges() {
        let valid = NSRange(location: 2, length: 3)
        XCTAssertEqual(
            ScriptBodySelectionPolicy.clampedSelection(valid, utf16Length: 10),
            valid
        )
        XCTAssertNil(ScriptBodySelectionPolicy.clampedSelection(valid, utf16Length: 4))
        XCTAssertNil(
            ScriptBodySelectionPolicy.clampedSelection(
                NSRange(location: NSNotFound, length: 0),
                utf16Length: 10
            )
        )
        XCTAssertNil(
            ScriptBodySelectionPolicy.clampedSelection(
                NSRange(location: -1, length: 2),
                utf16Length: 10
            )
        )

        XCTAssertEqual(
            ScriptBodySelectionPolicy.restoredSelection(
                previous: NSRange(location: 8, length: 4),
                utf16Length: 10
            ),
            NSRange(location: 8, length: 2)
        )
        XCTAssertEqual(
            ScriptBodySelectionPolicy.restoredSelection(
                previous: NSRange(location: 40, length: 2),
                utf16Length: 10
            ),
            NSRange(location: 10, length: 0)
        )
    }

    func testFindLineJumpRequestMakeUsesStableRangeAndFreshIdentity() {
        let range = NSRange(location: 4, length: 2)
        let a = FindLineJumpRequest.make(range: range)
        let b = FindLineJumpRequest.make(range: range)
        XCTAssertEqual(a.range, range)
        XCTAssertEqual(b.range, range)
        XCTAssertNotEqual(a.id, b.id)
    }
}
