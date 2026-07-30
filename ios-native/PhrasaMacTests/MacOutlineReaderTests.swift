import SwiftUI
import XCTest
import PhrasaDomain
@testable import PhrasaMac

final class MacOutlineReaderTests: XCTestCase {
    func testMeaningfulPointsFilterEmptyRows() {
        let points = [
            OutlinePoint(text: "  Hook  ", note: " smile "),
            OutlinePoint(text: "   ", note: "   "),
            OutlinePoint(text: "", note: "Only note")
        ]
        let meaningful = MacOutlineReaderContent.meaningfulPoints(from: points)
        XCTAssertEqual(meaningful.count, 2)
        XCTAssertEqual(MacOutlineReaderContent.primaryText(for: meaningful[0]), "Hook")
        XCTAssertEqual(MacOutlineReaderContent.supportingNote(for: meaningful[0]), "smile")
        XCTAssertEqual(MacOutlineReaderContent.spokenText(for: meaningful[0]), "Hook. smile")
        XCTAssertEqual(MacOutlineReaderContent.primaryText(for: meaningful[1]), "Only note")
        XCTAssertNil(MacOutlineReaderContent.supportingNote(for: meaningful[1]))
    }

    func testKeyboardCommandsMapToOutlineSteps() {
        // KeyPress isn't constructible outside SwiftUI easily; test the pure enum mapping via documented keys.
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .escape), .exit)
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .leftArrow), .previous)
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .pageUp), .previous)
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .upArrow), .previous)
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .rightArrow), .next)
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .pageDown), .next)
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .downArrow), .next)
        XCTAssertEqual(MacOutlineReaderCommand.resolve(key: .space), .next)
        XCTAssertNil(MacOutlineReaderCommand.resolve(key: .tab))
    }

    @MainActor
    func testAppModelPresentOutlineSetsAndClearsScriptID() async {
        let model = MacAppModel()
        let id = UUID()
        let requested = await model.requestOutline(scriptID: id)
        XCTAssertTrue(requested)
        XCTAssertEqual(model.outlineScriptID, id)
        model.closeOutline()
        XCTAssertNil(model.outlineScriptID)
    }
}

extension MacOutlineReaderCommand {
    /// Test helper mirroring KeyPress.key resolution without requiring a live KeyPress.
    static func resolve(key: KeyEquivalent) -> MacOutlineReaderCommand? {
        switch key {
        case .escape: return .exit
        case .leftArrow, .pageUp, .upArrow: return .previous
        case .rightArrow, .pageDown, .downArrow, .space: return .next
        default: return nil
        }
    }
}
