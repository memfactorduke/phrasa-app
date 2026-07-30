import XCTest
@testable import Phrasa

final class TextMetricsTests: XCTestCase {
    func testPrompterFocusAnchorAndGuideShareFullStageVerticalMirror() {
        let height: CGFloat = 800
        let focus = 0.42
        let contentY = PrompterGeometry.contentFocusY(
            height: height,
            focusPosition: focus
        )
        XCTAssertEqual(contentY, height * focus, accuracy: 0.001)
        XCTAssertEqual(
            PrompterGeometry.visibleFocusY(
                height: height,
                focusPosition: focus,
                mirrorVertical: false
            ),
            contentY,
            accuracy: 0.001
        )

        let mirroredVisible = PrompterGeometry.visibleFocusY(
            height: height,
            focusPosition: focus,
            mirrorVertical: true
        )
        XCTAssertEqual(mirroredVisible, height * (1 - focus), accuracy: 0.001)
        XCTAssertEqual(
            PrompterGeometry.displayedY(
                forContentY: contentY,
                height: height,
                mirrorVertical: true
            ),
            mirroredVisible,
            accuracy: 0.001
        )
    }
    func testWordCountIgnoresRepeatedWhitespace() {
        XCTAssertEqual(TextMetrics.wordCount("  one\n two\tthree  "), 3)
    }

    func testReadingTimeUsesRequestedPace() {
        let words = Array(repeating: "word", count: 150).joined(separator: " ")
        XCTAssertEqual(TextMetrics.estimatedDuration(words), 60, accuracy: 0.001)
    }

    func testSettingsNormalizationKeepsMirrorsExclusive() {
        var settings = ReaderSettings()
        settings.mirrorHorizontal = true
        settings.mirrorVertical = true
        settings.fontSize = 900
        settings.normalize()
        XCTAssertFalse(settings.mirrorHorizontal)
        XCTAssertTrue(settings.mirrorVertical)
        XCTAssertEqual(settings.fontSize, 160)
    }
}

final class NativeViewPolicyTests: XCTestCase {
    func testLibrarySelectionKeepsExistingIDsAndClearsMissingScriptsOrFolders() {
        let selectedScriptID = UUID()
        let selectedFolderID = UUID()

        XCTAssertEqual(
            LibrarySelectionPolicy.retainedSelection(
                selectedScriptID,
                availableIDs: [selectedScriptID]
            ),
            selectedScriptID
        )
        XCTAssertNil(
            LibrarySelectionPolicy.retainedSelection(
                selectedScriptID,
                availableIDs: []
            )
        )
        XCTAssertNil(
            LibrarySelectionPolicy.retainedSelection(
                selectedFolderID,
                availableIDs: [UUID()]
            )
        )
    }

    func testRestorePromptUsesNeutralTitleAndCountsEmptyCapableBackupContents() {
        XCTAssertEqual(LibraryRestorePrompt.title, "Restore backup?")
        XCTAssertTrue(
            LibraryRestorePrompt.message(for: .empty)
                .contains("0 scripts and 0 folders")
        )

        let backup = LibrarySnapshot(
            scripts: [ScriptDocument(title: "One")],
            folders: [ScriptFolder(name: "First"), ScriptFolder(name: "Second")],
            settings: ReaderSettings(),
            seeded: true
        )
        XCTAssertTrue(
            LibraryRestorePrompt.message(for: backup)
                .contains("1 script and 2 folders")
        )
    }

    func testOutlineReaderPresentsNoteOnlyPointsAndDropsEmptyPlaceholders() {
        let noteOnly = OutlinePoint(text: "  ", note: "Pause for the reveal")
        let headingAndNote = OutlinePoint(text: "Close", note: "Slow down")
        let empty = OutlinePoint(text: "\n", note: "\t")

        let points = OutlineReaderContent.meaningfulPoints(
            from: [empty, noteOnly, headingAndNote]
        )

        XCTAssertEqual(points.map(\.id), [noteOnly.id, headingAndNote.id])
        XCTAssertEqual(
            OutlineReaderContent.primaryText(for: noteOnly),
            "Pause for the reveal"
        )
        XCTAssertNil(OutlineReaderContent.supportingNote(for: noteOnly))
        XCTAssertEqual(
            OutlineReaderContent.spokenText(for: headingAndNote),
            "Close. Slow down"
        )
    }
}
