import PDFKit
import UIKit
import XCTest
@testable import Phrasa

final class ImportExportServiceTests: XCTestCase {
    private let importer = ScriptImportService()
    private let exporter = ScriptExportService()

    func testTextImportCleansContentAndUsesFilenameForTitle() throws {
        let data = Data("\u{feff}First line  \r\n\r\n\r\nSecond line\r\n".utf8)

        let script = try importer.importData(data, filename: "My Script.TXT")

        XCTAssertEqual(script.title, "My Script")
        XCTAssertEqual(script.body, "First line\n\nSecond line")
        XCTAssertEqual(script.source, .upload)
    }

    func testMarkdownImportIsSupported() throws {
        let script = try importer.importData(
            Data("# Opening\n\nHello **world**".utf8),
            filename: "talk.markdown"
        )

        XCTAssertEqual(script.title, "talk")
        XCTAssertEqual(script.body, "# Opening\n\nHello **world**")
    }

    func testImportRejectsFilesOverFifteenMegabytes() {
        let oversizedData = Data(
            repeating: 0,
            count: ImportExportLimits.maximumFileSize + 1
        )

        XCTAssertThrowsError(try importer.importData(oversizedData, filename: "large.txt")) { error in
            XCTAssertEqual(
                error as? ScriptImportError,
                .fileTooLarge(maximumBytes: ImportExportLimits.maximumFileSize)
            )
        }
    }

    func testImportReturnsFriendlyTypedErrors() {
        XCTAssertThrowsError(
            try importer.importData(Data("hello".utf8), filename: "script.pages")
        ) { error in
            guard let importError = error as? ScriptImportError else {
                return XCTFail("Expected a ScriptImportError")
            }
            XCTAssertEqual(importError, .unsupportedFileType("pages"))
            XCTAssertEqual(
                importError.errorDescription,
                "Phrasa cannot import .pages files yet. Choose a text, Markdown, or PDF file."
            )
        }

        XCTAssertThrowsError(
            try importer.importData(Data("  \n\n".utf8), filename: "empty.md")
        ) { error in
            XCTAssertEqual(error as? ScriptImportError, .emptyDocument)
        }
    }

    func testPDFImportExtractsText() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let pdfData = renderer.pdfData { context in
            context.beginPage()
            ("A PDF script" as NSString).draw(
                at: CGPoint(x: 40, y: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
        }

        let script = try importer.importData(pdfData, filename: "Imported.pdf")

        XCTAssertEqual(script.title, "Imported")
        XCTAssertTrue(script.body.contains("A PDF script"))
    }

    func testInvalidPDFReturnsTypedError() {
        XCTAssertThrowsError(
            try importer.importData(Data("not a PDF".utf8), filename: "broken.pdf")
        ) { error in
            XCTAssertEqual(error as? ScriptImportError, .unreadablePDF)
        }
    }

    func testPlainTextExportIncludesOutlineAndSafeFilename() throws {
        let script = ScriptDocument(
            title: "Launch: Script/One",
            body: "Welcome everyone.",
            outline: [
                OutlinePoint(text: "Opening", note: "Slow down"),
                OutlinePoint(text: "Close")
            ]
        )

        let exported = exporter.plainText(script: script)
        let text = try XCTUnwrap(String(data: exported.data, encoding: .utf8))

        XCTAssertEqual(exported.suggestedFilename, "Launch- Script-One.txt")
        XCTAssertEqual(exported.mimeType, "text/plain")
        XCTAssertEqual(
            text,
            "Launch: Script/One\n\nWelcome everyone.\n\n---\nOutline:\n- Opening (Slow down)\n- Close\n"
        )
    }

    func testPlainTextExportIncludesNoteOnlyOutlinePoints() throws {
        let script = ScriptDocument(
            title: "Notes",
            body: "Main script",
            outline: [OutlinePoint(text: "   ", note: "Pause for applause")]
        )

        let exported = exporter.plainText(script: script)
        let text = try XCTUnwrap(String(data: exported.data, encoding: .utf8))

        XCTAssertTrue(text.contains("Outline:\n- Note: Pause for applause"))
    }

    func testScriptJSONExportIsVersionedAndPreservesScript() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let script = ScriptDocument(
            title: "Demo",
            body: "Read this",
            createdAt: date,
            updatedAt: date
        )

        let exported = try exporter.scriptJSON(script: script, exportedAt: date)
        let envelope = try jsonDecoder().decode(ScriptExportEnvelope.self, from: exported.data)

        XCTAssertEqual(exported.suggestedFilename, "Demo.json")
        XCTAssertEqual(exported.mimeType, "application/json")
        XCTAssertEqual(envelope.format, "phrasa-script")
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.exportedAt, date)
        XCTAssertEqual(envelope.script, script)
    }

    func testLibraryBackupPreservesCompleteSnapshot() throws {
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let folder = ScriptFolder(name: "Keynotes", createdAt: date)
        let script = ScriptDocument(
            title: "Annual talk",
            body: "Hello",
            folderID: folder.id,
            tags: ["work"],
            createdAt: date,
            updatedAt: date
        )
        var settings = ReaderSettings()
        settings.fontSize = 58
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [folder],
            settings: settings,
            seeded: true
        )

        let exported = try exporter.libraryBackup(snapshot: snapshot, exportedAt: date)
        let envelope = try jsonDecoder().decode(LibraryExportEnvelope.self, from: exported.data)

        XCTAssertEqual(exported.suggestedFilename, "phrasa-library-2024-01-01.json")
        XCTAssertEqual(envelope.format, "phrasa-library")
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.exportedAt, date)
        XCTAssertEqual(envelope.schemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(envelope.scripts, snapshot.scripts)
        XCTAssertEqual(envelope.folders, snapshot.folders)
        XCTAssertEqual(envelope.settings, snapshot.settings)
        XCTAssertEqual(envelope.seeded, snapshot.seeded)
    }

    func testLibraryBackupCanBeRestored() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let script = ScriptDocument(
            title: "Recovered",
            body: "Still here",
            createdAt: date,
            updatedAt: date
        )
        let folder = ScriptFolder(name: "Archive", createdAt: date)
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [folder],
            settings: ReaderSettings(),
            seeded: true
        )
        let export = try exporter.libraryBackup(snapshot: snapshot)

        let restored = try LibraryBackupImportService().importData(export.data)

        XCTAssertEqual(restored.scripts, [script])
        XCTAssertEqual(restored.folders, [folder])
        XCTAssertTrue(restored.seeded)
    }

    func testLibraryBackupLargerThanSingleDocumentLimitStillRoundTrips() throws {
        let largeBody = String(
            repeating: "x",
            count: ImportExportLimits.maximumFileSize + 1_024
        )
        let snapshot = LibrarySnapshot(
            scripts: [ScriptDocument(title: "Long archive", body: largeBody)],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )

        let export = try exporter.libraryBackup(snapshot: snapshot)

        XCTAssertGreaterThan(export.data.count, ImportExportLimits.maximumFileSize)
        XCTAssertLessThanOrEqual(
            export.data.count,
            ImportExportLimits.maximumLibraryBackupSize
        )
        let restored = try LibraryBackupImportService().importData(export.data)
        XCTAssertEqual(restored.scripts.first?.body, largeBody)
    }

    func testLibraryBackupWithoutScriptsStillRestoresFoldersAndSettings() throws {
        let folder = ScriptFolder(
            name: "Future talks",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var settings = ReaderSettings()
        settings.theme = .paper
        settings.speedWPM = 212
        let snapshot = LibrarySnapshot(
            scripts: [],
            folders: [folder],
            settings: settings,
            seeded: true
        )
        let export = try exporter.libraryBackup(snapshot: snapshot)

        let restored = try LibraryBackupImportService().importData(export.data)

        XCTAssertTrue(restored.scripts.isEmpty)
        XCTAssertEqual(restored.folders, [folder])
        XCTAssertEqual(restored.settings.theme, .paper)
        XCTAssertEqual(restored.settings.speedWPM, 212)
        XCTAssertTrue(restored.seeded)
    }

    func testLibraryBackupPreservesFractionalDatesSoTheNewerMergeCandidateWins() throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 100.5)
        let backupUpdatedAt = Date(timeIntervalSince1970: 100.9)
        let scriptID = UUID()
        let backupScript = ScriptDocument(
            id: scriptID,
            title: "Newer backup",
            body: "Keep this version",
            createdAt: Date(timeIntervalSince1970: 50.25),
            updatedAt: backupUpdatedAt
        )
        let export = try exporter.libraryBackup(snapshot: LibrarySnapshot(
            scripts: [backupScript],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        ))

        let restored = try LibraryBackupImportService().importData(export.data)
        let restoredScript = try XCTUnwrap(restored.scripts.first)

        XCTAssertEqual(
            restoredScript.updatedAt.timeIntervalSince1970,
            backupUpdatedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(restoredScript.updatedAt, localUpdatedAt)
    }

    func testLibraryBackupNormalizesInvalidRelationshipsAndDuplicatesBeforeSharing() throws {
        let repeatedPoint = OutlinePoint(text: "Repeated ID")
        let script = ScriptDocument(
            title: "Legacy edge cases",
            folderID: UUID(),
            tags: ["important", "important"],
            outline: [repeatedPoint, repeatedPoint]
        )
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )

        let export = try exporter.libraryBackup(snapshot: snapshot)
        let restored = try LibraryBackupImportService().importData(export.data)
        let restoredScript = try XCTUnwrap(restored.scripts.first)

        XCTAssertNil(restoredScript.folderID)
        XCTAssertEqual(restoredScript.tags, ["important"])
        XCTAssertEqual(restoredScript.outline.count, 2)
        XCTAssertEqual(Set(restoredScript.outline.map(\.id)).count, 2)
    }

    func testLibraryRestoreRejectsUnrelatedJSON() {
        XCTAssertThrowsError(
            try LibraryBackupImportService().importData(Data(#"{"scripts":[]}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? LibraryBackupImportError, .invalidBackup)
        }
    }

    func testLibraryRestoreRejectsDuplicateScriptIDs() throws {
        let script = ScriptDocument(title: "Duplicate")
        let snapshot = LibrarySnapshot(
            scripts: [script, script],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )

        try assertInvalidLibraryStructure(snapshot)
    }

    func testLibraryRestoreRejectsDuplicateFolderIDs() throws {
        let folder = ScriptFolder(name: "Duplicate")
        let snapshot = LibrarySnapshot(
            scripts: [ScriptDocument(title: "Script")],
            folders: [folder, folder],
            settings: ReaderSettings(),
            seeded: true
        )

        try assertInvalidLibraryStructure(snapshot)
    }

    func testLibraryRestoreRejectsDanglingFolderReferences() throws {
        let script = ScriptDocument(title: "Orphan", folderID: UUID())
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )

        try assertInvalidLibraryStructure(snapshot)
    }

    func testLibraryRestoreRejectsDuplicateOutlinePointIDs() throws {
        let point = OutlinePoint(text: "Repeated")
        let script = ScriptDocument(title: "Outline", outline: [point, point])
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )

        try assertInvalidLibraryStructure(snapshot)
    }

    func testLibraryRestoreRejectsDuplicateTags() throws {
        let script = ScriptDocument(title: "Tags", tags: ["work", "work"])
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )

        try assertInvalidLibraryStructure(snapshot)
    }

    func testLibraryRestoreRejectsNonpositiveSchemaVersions() throws {
        for version in [0, -1] {
            let snapshot = LibrarySnapshot(
                schemaVersion: version,
                scripts: [ScriptDocument(title: "Old")],
                folders: [],
                settings: ReaderSettings(),
                seeded: true
            )
            let export = try exporter.libraryBackup(snapshot: snapshot)

            XCTAssertThrowsError(try LibraryBackupImportService().importData(export.data)) { error in
                XCTAssertEqual(error as? LibraryBackupImportError, .unsupportedVersion)
            }
        }
    }

    private func assertInvalidLibraryStructure(
        _ snapshot: LibrarySnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let malformedData = try LibraryBackupJSONCoding.makeEncoder().encode(
            LibraryExportEnvelope(snapshot: snapshot, exportedAt: .now)
        )
        XCTAssertThrowsError(
            try LibraryBackupImportService().importData(malformedData),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? LibraryBackupImportError,
                .invalidLibraryStructure,
                file: file,
                line: line
            )
        }
    }

    private func jsonDecoder() -> JSONDecoder {
        LibraryBackupJSONCoding.makeDecoder()
    }
}
