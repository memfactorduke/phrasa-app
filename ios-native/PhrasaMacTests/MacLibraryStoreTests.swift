import XCTest
import PhrasaDomain
import PhrasaPersistence
@testable import PhrasaMac

@MainActor
final class MacLibraryStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: MacLibraryStore!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhrasaMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let dbURL = temporaryDirectory.appendingPathComponent("library.sqlite3")
        let persistence = LibraryPersistenceFactory.makeShipping(fileURL: dbURL)
        store = MacLibraryStore(persistence: persistence)
        await store.load()
        XCTAssertTrue(store.isLoaded)
    }

    override func tearDown() async throws {
        store = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSeedWelcomeScriptOnFirstLaunch() {
        XCTAssertFalse(store.scripts.isEmpty)
        XCTAssertEqual(store.scripts.first?.title, ScriptDocument.welcome.title)
    }

    func testCreateEditDeleteAndSearch() async {
        let created = await store.createScript(title: "Keynote", body: "Hello world #demo")
        XCTAssertNotNil(created)
        guard var script = created else { return }

        script.body = "Updated body for the Mac store"
        script.tags = ["demo", "mac"]
        let saved = await store.update(script)
        XCTAssertTrue(saved)

        let matches = store.filteredScripts(search: "#mac", folderFilter: nil)
        XCTAssertTrue(matches.contains(where: { $0.id == script.id }))

        let titleMatches = store.filteredScripts(search: "Keynote", folderFilter: nil)
        XCTAssertTrue(titleMatches.contains(where: { $0.id == script.id }))

        await store.delete(script.id)
        XCTAssertNil(store.script(id: script.id))
    }

    func testFolderMoveAndFilter() async {
        let folder = await store.createFolder(name: "Talks")
        XCTAssertNotNil(folder)
        guard let folder else { return }

        let script = await store.createScript(title: "Stage", body: "Lines")
        XCTAssertNotNil(script)
        guard let script else { return }

        let moved = await store.moveScript(script.id, to: folder.id)
        XCTAssertTrue(moved)

        let inFolder = store.filteredScripts(search: "", folderFilter: folder.id)
        XCTAssertEqual(inFolder.map(\.id), [script.id])

        let outside = store.filteredScripts(search: "", folderFilter: UUID())
        XCTAssertTrue(outside.isEmpty)
    }

    func testFailedFolderMovePreservesVisibleAndDurableStateAndOffersRecovery() async {
        let sourceFolder = ScriptFolder(name: "Current")
        let targetFolder = ScriptFolder(name: "Talks")
        let script = ScriptDocument(
            title: "Stage",
            body: "Lines",
            folderID: sourceFolder.id
        )
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [sourceFolder, targetFolder],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = FailableMacMovePersistence(snapshot: snapshot)
        let failingStore = MacLibraryStore(persistence: persistence)
        await failingStore.load()
        await persistence.failNextUpsert()
        let revisionBefore = failingStore.editorDocumentChange(id: script.id)?.revision

        let moved = await failingStore.moveScript(script.id, to: targetFolder.id)
        let durableAfterFailure = await persistence.currentSnapshot()

        XCTAssertFalse(moved)
        XCTAssertEqual(failingStore.script(id: script.id)?.folderID, sourceFolder.id)
        XCTAssertEqual(
            durableAfterFailure.scripts.first?.folderID,
            sourceFolder.id
        )
        XCTAssertEqual(
            failingStore.editorDocumentChange(id: script.id)?.revision,
            revisionBefore,
            "A failed durable move must not publish a false metadata change."
        )
        XCTAssertTrue(failingStore.errorMessage?.contains("Couldn’t move “Stage”") == true)
        XCTAssertTrue(failingStore.errorMessage?.contains("remains in “Current”") == true)
        XCTAssertTrue(failingStore.errorMessage?.contains("Try moving it again") == true)

        failingStore.clearError()
        let retryMoved = await failingStore.moveScript(script.id, to: targetFolder.id)
        let durableAfterRetry = await persistence.currentSnapshot()
        XCTAssertTrue(retryMoved)
        XCTAssertEqual(failingStore.script(id: script.id)?.folderID, targetFolder.id)
        XCTAssertEqual(
            durableAfterRetry.scripts.first?.folderID,
            targetFolder.id
        )
    }

    func testFailedEditorFlushBlocksMacNavigationAndKeepsCurrentSelection() async {
        let current = ScriptDocument(title: "Current", body: "Original")
        let controller = MacEditorAutosaveController(
            initial: current,
            debounceDelay: .seconds(60)
        ) { _ in false }
        var edited = current
        edited.body = "Unsaved draft"
        controller.record(edited)

        let decision = await MacEditorOpenGate.resolve(
            currentScriptID: current.id,
            flush: { await controller.flush() }
        )

        XCTAssertEqual(decision, .stayOnCurrent(current.id))
        XCTAssertEqual(controller.state, .failed)
    }

    func testAutosaveControllerCoalescesAndFlushes() async {
        let initial = ScriptDocument(title: "Draft", body: "One")
        var writes: [ScriptDocument] = []
        let controller = MacEditorAutosaveController(
            initial: initial,
            debounceDelay: .milliseconds(20)
        ) { document in
            writes.append(document)
            return true
        }

        var draft = initial
        draft.body = "Two"
        controller.record(draft)
        draft.body = "Three"
        controller.record(draft)
        let ok = await controller.flush()
        XCTAssertTrue(ok)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.body, "Three")
        XCTAssertEqual(controller.state, .saved)
    }

    func testAutosaveRetainsFailedDraftForRetry() async {
        let initial = ScriptDocument(title: "Draft", body: "One")
        var shouldFail = true
        let controller = MacEditorAutosaveController(
            initial: initial,
            debounceDelay: .milliseconds(5)
        ) { _ in
            if shouldFail {
                shouldFail = false
                return false
            }
            return true
        }

        var draft = initial
        draft.body = "Two"
        controller.record(draft)
        _ = await controller.flush()
        XCTAssertEqual(controller.state, .failed)

        controller.retry()
        _ = await controller.flush()
        XCTAssertEqual(controller.state, .saved)
    }

    func testImportExportRoundTripBoundaries() throws {
        let importer = MacScriptImportService()
        let txt = try importer.importData(
            Data("Hello from Mac import.\n\nSecond paragraph.".utf8),
            filename: "notes.txt"
        )
        XCTAssertEqual(txt.title, "notes")
        XCTAssertTrue(txt.body.contains("Hello from Mac import."))

        let markdown = try importer.importData(
            Data("# Title\n\nBody".utf8),
            filename: "talk.md"
        )
        XCTAssertEqual(markdown.source, .upload)

        XCTAssertThrowsError(
            try importer.importData(Data("x".utf8), filename: "photo.png")
        ) { error in
            XCTAssertEqual(error as? MacScriptImportError, .unsupportedFileType("png"))
        }

        let oversized = Data(repeating: 0x61, count: MacImportExportLimits.maximumFileSize + 1)
        XCTAssertThrowsError(try importer.importData(oversized, filename: "big.txt"))

        let exporter = MacScriptExportService()
        let plain = exporter.plainText(script: txt)
        XCTAssertTrue(plain.suggestedFilename.hasSuffix(".txt"))
        XCTAssertTrue(String(decoding: plain.data, as: UTF8.self).contains("Hello from Mac import."))

        let json = try exporter.scriptJSON(script: txt)
        XCTAssertTrue(json.suggestedFilename.hasSuffix(".json"))
    }

    func testLibraryBackupExportAndRestore() async throws {
        let second = await store.createScript(title: "Backup me", body: "Payload")
        XCTAssertNotNil(second)

        let exporter = MacScriptExportService()
        let backup = try exporter.libraryBackup(snapshot: store.exportSnapshot())
        let restoredSnapshot = try MacLibraryBackupImportService().importData(backup.data)
        XCTAssertTrue(restoredSnapshot.scripts.contains(where: { $0.title == "Backup me" }))

        // Replace into a fresh store to prove durability boundary.
        let otherURL = temporaryDirectory.appendingPathComponent("restore.sqlite3")
        let other = MacLibraryStore(
            persistence: LibraryPersistenceFactory.makeShipping(fileURL: otherURL)
        )
        await other.load()
        let ok = await other.restore(restoredSnapshot, mode: .replace)
        XCTAssertTrue(ok)
        XCTAssertTrue(other.scripts.contains(where: { $0.title == "Backup me" }))
    }

    func testMergeRestorePreservesDivergentSameIDContentAsBackupCopy() async {
        guard var current = store.scripts.first else {
            return XCTFail("Expected welcome script")
        }
        current.body = "Current words"
        current.updatedAt = Date(timeIntervalSince1970: 100)
        let saved = await store.update(current)
        XCTAssertTrue(saved)

        var backupVersion = current
        backupVersion.body = "Divergent backup words"
        backupVersion.updatedAt = Date(timeIntervalSince1970: 10_000)
        let backup = LibrarySnapshot(
            scripts: [backupVersion],
            folders: [],
            settings: store.settings,
            seeded: true
        )

        let restored = await store.restore(backup, mode: .merge)
        XCTAssertTrue(restored)
        XCTAssertEqual(store.script(id: current.id)?.body, "Current words")
        let backupCopy = store.scripts.first { $0.id != current.id }
        XCTAssertEqual(backupCopy?.body, "Divergent backup words")
        XCTAssertEqual(backupCopy?.title, "\(current.title) — Backup copy")
    }

    func testRestoreRefusesWhileAnEditorDraftIsStaged() async {
        guard let current = store.scripts.first else {
            return XCTFail("Expected welcome script")
        }
        var draft = current
        draft.body = "Unsaved editor words"
        XCTAssertTrue(store.stageEditorDraft(draft, editorOriginID: UUID()))

        let restored = await store.restore(store.exportSnapshot(), mode: .replace)
        XCTAssertFalse(restored)
        XCTAssertEqual(store.script(id: current.id)?.body, "Unsaved editor words")
        XCTAssertTrue(store.errorMessage?.contains("editor draft") == true)
    }

    func testDuplicateAndSettingsNormalize() async {
        guard let original = store.scripts.first else {
            XCTFail("Expected seed script")
            return
        }
        let copy = await store.duplicate(original.id)
        XCTAssertNotNil(copy)
        XCTAssertEqual(copy?.title, original.title + " (copy)")

        var settings = store.settings
        settings.speedWPM = 10
        settings.mirrorHorizontal = true
        settings.mirrorVertical = true
        let saved = await store.saveSettings(settings)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.settings.speedWPM, 40)
        // Vertical mirror wins exclusivity after normalize.
        XCTAssertTrue(store.settings.mirrorVertical)
        XCTAssertFalse(store.settings.mirrorHorizontal)
    }

    func testExternalChangePolicyIgnoresOwnOrigin() {
        let origin = UUID()
        let script = ScriptDocument(title: "A", body: "B")
        let own = MacLibraryEditorDocumentChange(
            revision: 1,
            document: script,
            editorOriginID: origin
        )
        XCTAssertEqual(
            MacEditorExternalChangePolicy.decision(for: own, editorOriginID: origin),
            .ignore
        )

        let external = MacLibraryEditorDocumentChange(
            revision: 2,
            document: script,
            editorOriginID: nil
        )
        XCTAssertEqual(
            MacEditorExternalChangePolicy.decision(for: external, editorOriginID: origin),
            .replace(script)
        )
    }
}

private actor FailableMacMovePersistence: LibraryPersistence {
    private struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "Simulated durable move failure." }
    }

    private var snapshot: LibrarySnapshot
    private var shouldFailNextUpsert = false

    init(snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
    }

    func failNextUpsert() {
        shouldFailNextUpsert = true
    }

    func currentSnapshot() -> LibrarySnapshot {
        snapshot
    }

    func load() async throws -> LibrarySnapshot {
        snapshot
    }

    func replace(with snapshot: LibrarySnapshot) async throws {
        self.snapshot = snapshot
    }

    func upsert(_ script: ScriptDocument) async throws {
        if shouldFailNextUpsert {
            shouldFailNextUpsert = false
            throw InjectedFailure()
        }
        if let index = snapshot.scripts.firstIndex(where: { $0.id == script.id }) {
            snapshot.scripts[index] = script
        } else {
            snapshot.scripts.append(script)
        }
    }

    func deleteScript(id: UUID) async throws {
        snapshot.scripts.removeAll { $0.id == id }
    }

    func deleteFolder(id: UUID, updatedScripts: [ScriptDocument]) async throws {
        snapshot.folders.removeAll { $0.id == id }
        for script in updatedScripts {
            if let index = snapshot.scripts.firstIndex(where: { $0.id == script.id }) {
                snapshot.scripts[index] = script
            }
        }
    }

    func saveSettings(_ settings: ReaderSettings, seeded: Bool) async throws {
        snapshot.settings = settings
        snapshot.seeded = seeded
    }

    func saveFolders(_ folders: [ScriptFolder]) async throws {
        snapshot.folders = folders
    }

    func prepareCloudSync(
        accountID: UUID,
        localScriptIDs: Set<UUID>,
        localFolderIDs: Set<UUID>
    ) async throws -> CloudLocalSyncState {
        .empty(accountID: accountID)
    }

    func applyCloudSync(
        snapshot: LibrarySnapshot,
        update: CloudSyncPersistenceUpdate
    ) async throws {
        self.snapshot = snapshot
    }
}
