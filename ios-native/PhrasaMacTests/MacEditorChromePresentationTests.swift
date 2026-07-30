import XCTest
@testable import PhrasaMac

final class MacEditorChromePresentationTests: XCTestCase {
    func testSectionPickerHidesVisibleTitleSoChromeDoesNotStackSectionLetters() {
        // Proven layout defect: Picker("Section") + segmented style painted a
        // squeezed vertical "Section" label between Folder and Script/Outline
        // at ~1180×740. The title must remain VoiceOver-only.
        XCTAssertTrue(MacEditorChromePresentation.sectionPickerHidesVisibleLabel)
        XCTAssertFalse(MacEditorChromePresentation.sectionPickerTitle.isEmpty)
        XCTAssertEqual(
            MacEditorChromePresentation.sectionPickerAccessibilityLabel,
            MacEditorChromePresentation.sectionPickerTitle
        )
        XCTAssertEqual(MacEditorChromePresentation.sectionScriptOption, "Script")
        XCTAssertEqual(MacEditorChromePresentation.sectionOutlineOption, "Outline")
        // Visible chrome must not reintroduce the old short title that stacked.
        XCTAssertNotEqual(MacEditorChromePresentation.sectionPickerTitle, "Section")
    }

    func testFolderPickerKeepsAccessibleTitleContract() {
        XCTAssertTrue(MacEditorChromePresentation.folderPickerShowsVisibleLabel)
        XCTAssertEqual(MacEditorChromePresentation.folderPickerTitle, "Folder")
        XCTAssertEqual(
            MacEditorChromePresentation.folderPickerAccessibilityLabel,
            MacEditorChromePresentation.folderPickerTitle
        )
    }
}
