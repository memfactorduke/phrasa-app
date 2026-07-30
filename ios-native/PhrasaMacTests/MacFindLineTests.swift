import XCTest
@testable import PhrasaMac

final class MacFindLineTests: XCTestCase {
    func testFindsCaseInsensitiveMatchAndLineNumber() {
        let body = "First line\nSecond LINE here\nThird"
        let range = MacFindLineService.firstMatchRange(in: body, query: "line", fromUTF16Offset: 0)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.location, 6)

        let second = MacFindLineService.firstMatchRange(
            in: body,
            query: "line",
            fromUTF16Offset: (range?.location ?? 0) + 1
        )
        XCTAssertNotNil(second)
        XCTAssertEqual(
            MacFindLineService.lineNumber(in: body, utf16Offset: second!.location),
            2
        )
    }

    func testWrapsAroundWhenPastLastMatch() {
        let body = "alpha beta gamma"
        let first = MacFindLineService.firstMatchRange(in: body, query: "beta", fromUTF16Offset: 0)
        XCTAssertNotNil(first)
        let wrapped = MacFindLineService.firstMatchRange(
            in: body,
            query: "beta",
            fromUTF16Offset: body.utf16.count
        )
        XCTAssertEqual(wrapped?.location, first?.location)
    }

    func testEmptyQueryReturnsNil() {
        XCTAssertNil(MacFindLineService.firstMatchRange(in: "hello", query: "   "))
    }

    func testMissingQueryReturnsNil() {
        XCTAssertNil(MacFindLineService.firstMatchRange(in: "hello world", query: "zebra"))
    }
}
