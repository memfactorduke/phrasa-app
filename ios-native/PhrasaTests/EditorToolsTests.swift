import XCTest
@testable import Phrasa

final class EditorToolsTests: XCTestCase {
    @MainActor
    func testAutosaveDoesNotWriteAnUnchangedOpenedDocument() async {
        let initial = ScriptDocument(title: "Opening should not edit", body: "Original")
        var saved: [ScriptDocument] = []
        let controller = EditorAutosaveController(
            initial: initial,
            debounceDelay: .seconds(60)
        ) { document in
            saved.append(document)
            return true
        }

        controller.record(initial)
        let didFlush = await controller.flush()
        XCTAssertTrue(didFlush)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(controller.state, .saved)
    }

    @MainActor
    func testAutosaveCoalescesRapidEditsAndFlushesLatestValue() async {
        let initial = ScriptDocument(title: "Draft", body: "One")
        var saved: [ScriptDocument] = []
        let controller = EditorAutosaveController(
            initial: initial,
            debounceDelay: .seconds(60)
        ) { document in
            saved.append(document)
            return true
        }
        var first = initial
        first.body = "Two"
        var latest = first
        latest.body = "Three"

        controller.record(first)
        controller.record(latest)

        let didFlush = await controller.flush()
        XCTAssertTrue(didFlush)
        XCTAssertEqual(saved.map(\.body), ["Three"])
        XCTAssertEqual(controller.state, .saved)
    }

    @MainActor
    func testAutosaveRetainsFailedDraftForRetry() async {
        let initial = ScriptDocument(title: "Draft", body: "Original")
        var attempts = 0
        let controller = EditorAutosaveController(
            initial: initial,
            debounceDelay: .seconds(60)
        ) { _ in
            attempts += 1
            return attempts > 1
        }
        var edited = initial
        edited.body = "Unsaved but retained"
        controller.record(edited)

        let firstFlush = await controller.flush()
        XCTAssertFalse(firstFlush)
        XCTAssertEqual(controller.state, .failed)

        controller.retry()
        let retryFlush = await controller.flush()
        XCTAssertTrue(retryFlush)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(controller.state, .saved)
    }

    @MainActor
    func testFolderRebaseRemainsTheBaselineAfterAnOlderSaveFinishes() async {
        let oldFolderID = UUID()
        let newFolderID = UUID()
        let initial = ScriptDocument(title: "Draft", body: "Initial", folderID: oldFolderID)
        let recorder = BlockingEditorSaveRecorder()
        let controller = EditorAutosaveController(
            initial: initial,
            debounceDelay: .seconds(60)
        ) { document in
            await recorder.save(document)
        }
        var firstEdit = initial
        firstEdit.body = "First edit"
        controller.record(firstEdit)
        let firstFlush = Task { @MainActor in await controller.flush() }
        await recorder.waitUntilFirstSaveIsBlocked()

        controller.rebase(.folderID(newFolderID))
        await recorder.resumeFirstSave()
        let didFinishFirstSave = await firstFlush.value
        XCTAssertTrue(didFinishFirstSave)

        var deliberateOldFolderSelection = firstEdit
        deliberateOldFolderSelection.folderID = oldFolderID
        controller.record(deliberateOldFolderSelection)
        let didSaveOldFolderSelection = await controller.flush()
        XCTAssertTrue(didSaveOldFolderSelection)

        let saved = await recorder.savedDocuments()
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.last?.folderID, oldFolderID)
    }

    func testProgrammaticDraftAssignmentIsConsumedWithoutStaging() {
        var suppressNextChange = true

        XCTAssertFalse(EditorDraftObservationPolicy.shouldStage(
            suppressNextChange: &suppressNextChange
        ))
        XCTAssertFalse(suppressNextChange)
        XCTAssertTrue(EditorDraftObservationPolicy.shouldStage(
            suppressNextChange: &suppressNextChange
        ))
    }

    @MainActor
    func testStagedEditorDraftDefersCloudSyncUntilDurableFlush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = ScriptDocument(
            title: "Draft",
            body: "Before editing",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let persistence = PersistenceClient(fileURL: fileURL)
        try await persistence.replace(with: LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: .init(),
            seeded: true
        ))
        let library = LibraryStore(persistence: persistence)
        await library.load()
        let autosave = EditorAutosaveController(
            initial: original,
            debounceDelay: .seconds(60)
        ) { document in
            await library.update(document)
        }
        var edited = original
        edited.body = "Latest in-memory edit"
        let changedAt = Date(timeIntervalSince1970: 200)

        XCTAssertTrue(library.stageEditorDraft(edited, changedAt: changedAt, editorOriginID: UUID()))
        autosave.record(edited)

        // Dirty barrier: staged-only content must never enter a sync snapshot.
        let deferred = try await library.prepareCloudSync(for: UUID())
        guard case .deferred(let reason) = deferred else {
            return XCTFail("Expected deferred sync while editor draft is unpersisted")
        }
        XCTAssertEqual(reason, .editorContentNotPersisted(scriptCount: 1))
        XCTAssertFalse(library.cloudSyncHostDirtyState.eligibility.isEligible)
        let diskBeforeFlush = try await persistence.load()
        XCTAssertEqual(diskBeforeFlush.scripts.first?.body, original.body)

        let didFlush = await autosave.flush()
        XCTAssertTrue(didFlush)
        let diskAfterFlush = try await persistence.load()
        XCTAssertEqual(diskAfterFlush.scripts.first?.body, edited.body)

        let ready = try await library.prepareCloudSync(for: UUID())
        guard case .ready(let syncInput) = ready else {
            return XCTFail("Expected ready sync after durable flush")
        }
        XCTAssertEqual(syncInput.library.scripts.first?.body, edited.body)
        XCTAssertTrue(library.cloudSyncHostDirtyState.eligibility.isEligible)
    }

    @MainActor
    func testCloudApplyPreservesAnEditStagedWhileTheCommitWasAwaiting() async throws {
        let original = ScriptDocument(
            title: "Original",
            body: "Sync base",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let base = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: .init(),
            seeded: true
        )
        let persistence = BlockingCloudApplyPersistence(snapshot: base)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        var cloudCopy = original
        cloudCopy.body = "Cloud merge"
        cloudCopy.updatedAt = Date(timeIntervalSince1970: 150)
        let accountID = UUID()
        let result = CloudSyncResult(
            baseLibrary: base,
            mergedLibrary: LibrarySnapshot(
                scripts: [cloudCopy],
                folders: [],
                settings: .init(),
                seeded: true
            ),
            summary: CloudSyncSummary(
                uploadedScripts: 0,
                downloadedScripts: 1,
                completedAt: Date(timeIntervalSince1970: 150)
            ),
            persistenceUpdate: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: 0
            )
        )

        let apply = Task { @MainActor in
            try await library.applyCloudSyncResult(result)
        }
        await persistence.waitUntilApplyIsWaiting()
        var localEdit = original
        localEdit.body = "Typed while persistence was awaiting"
        let editorOriginID = UUID()
        XCTAssertTrue(library.stageEditorDraft(
            localEdit,
            changedAt: Date(timeIntervalSince1970: 200),
            editorOriginID: editorOriginID
        ))
        await persistence.resumeApply()

        try await apply.value

        let visible = library.exportSnapshot()
        XCTAssertEqual(visible.scripts.first(where: { $0.id == original.id }), cloudCopy)
        let conflict = try XCTUnwrap(visible.scripts.first(where: { $0.id != original.id }))
        XCTAssertEqual(conflict.body, localEdit.body)
        XCTAssertTrue(conflict.title.contains("Local conflict"))
        let persisted = try await persistence.load()
        XCTAssertEqual(Set(persisted.scripts.map(\.id)), Set(visible.scripts.map(\.id)))
        XCTAssertEqual(
            persisted.scripts.first(where: { $0.id == conflict.id })?.body,
            localEdit.body
        )
    }

    @MainActor
    func testFolderDeleteSanitizesAndPersistsDraftStagedDuringCommit() async throws {
        let deletedFolder = ScriptFolder(name: "Delete me")
        let originalFolder = ScriptFolder(name: "Original folder")
        let original = ScriptDocument(
            title: "Draft",
            body: "Before",
            folderID: originalFolder.id,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [deletedFolder, originalFolder],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        await persistence.blockNext(.deleteFolder)

        let deleteTask = Task { @MainActor in
            await library.deleteFolder(deletedFolder.id)
        }
        await persistence.waitUntilBlocked(.deleteFolder)
        var interleavedDraft = original
        interleavedDraft.body = "Typed while delete was committing"
        interleavedDraft.folderID = deletedFolder.id
        XCTAssertTrue(library.stageEditorDraft(
            interleavedDraft,
            changedAt: Date(timeIntervalSince1970: 200),
            editorOriginID: UUID()
        ))
        await persistence.resumeBlockedOperation()
        await deleteTask.value

        let visible = try XCTUnwrap(library.script(id: original.id))
        XCTAssertEqual(visible.body, interleavedDraft.body)
        XCTAssertNil(visible.folderID)
        XCTAssertFalse(library.folders.contains(where: { $0.id == deletedFolder.id }))
        let persisted = try await persistence.load()
        let durable = try XCTUnwrap(persisted.scripts.first(where: { $0.id == original.id }))
        XCTAssertEqual(durable.body, interleavedDraft.body)
        XCTAssertNil(durable.folderID)
        XCTAssertFalse(persisted.folders.contains(where: { $0.id == deletedFolder.id }))
    }

    @MainActor
    func testCloudFolderDeleteSanitizesAndPersistsInterleavedDraftFolder() async throws {
        let deletedFolder = ScriptFolder(name: "Cloud-deleted folder")
        let original = ScriptDocument(
            title: "Draft",
            body: "Before",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let base = LibrarySnapshot(
            scripts: [original],
            folders: [deletedFolder],
            settings: ReaderSettings(),
            seeded: true
        )
        let merged = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: base)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        await persistence.blockNext(.applyCloudSync)
        let result = CloudSyncResult(
            baseLibrary: base,
            mergedLibrary: merged,
            summary: CloudSyncSummary(
                uploadedScripts: 0,
                downloadedScripts: 0,
                completedAt: Date(timeIntervalSince1970: 200)
            ),
            persistenceUpdate: CloudSyncPersistenceUpdate(
                accountID: UUID(),
                records: [],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: 0
            )
        )

        let applyTask = Task { @MainActor in
            try await library.applyCloudSyncResult(result)
        }
        await persistence.waitUntilBlocked(.applyCloudSync)
        var interleavedDraft = original
        interleavedDraft.body = "Typed while cloud was committing"
        interleavedDraft.folderID = deletedFolder.id
        XCTAssertTrue(library.stageEditorDraft(
            interleavedDraft,
            changedAt: Date(timeIntervalSince1970: 300),
            editorOriginID: UUID()
        ))
        await persistence.resumeBlockedOperation()
        try await applyTask.value

        let visible = try XCTUnwrap(library.script(id: original.id))
        XCTAssertEqual(visible.body, interleavedDraft.body)
        XCTAssertNil(visible.folderID)
        XCTAssertTrue(library.folders.isEmpty)
        let persisted = try await persistence.load()
        let durable = try XCTUnwrap(persisted.scripts.first(where: { $0.id == original.id }))
        XCTAssertEqual(durable.body, interleavedDraft.body)
        XCTAssertNil(durable.folderID)
        XCTAssertTrue(persisted.folders.isEmpty)
    }

    @MainActor
    func testPostCommitConflictSaveFailureReportsRetryInsteadOfSuccess() async throws {
        let original = ScriptDocument(
            title: "Shared",
            body: "Base",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let base = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        var cloud = original
        cloud.body = "Cloud edit"
        cloud.updatedAt = Date(timeIntervalSince1970: 200)
        let persistence = ControllableLibraryPersistence(snapshot: base)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        await persistence.blockNext(.applyCloudSync)
        await persistence.failNext(.upsertCloudConflict)
        let result = CloudSyncResult(
            baseLibrary: base,
            mergedLibrary: LibrarySnapshot(
                scripts: [cloud],
                folders: [],
                settings: ReaderSettings(),
                seeded: true
            ),
            summary: CloudSyncSummary(
                uploadedScripts: 0,
                downloadedScripts: 1,
                completedAt: Date(timeIntervalSince1970: 200)
            ),
            persistenceUpdate: CloudSyncPersistenceUpdate(
                accountID: UUID(),
                records: [],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: 0
            )
        )

        let applyTask = Task { @MainActor in
            try await library.applyCloudSyncResult(result)
        }
        await persistence.waitUntilBlocked(.applyCloudSync)
        var local = original
        local.body = "Local edit during commit"
        XCTAssertTrue(library.stageEditorDraft(
            local,
            changedAt: Date(timeIntervalSince1970: 300),
            editorOriginID: UUID()
        ))
        await persistence.resumeBlockedOperation()

        do {
            try await applyTask.value
            XCTFail("A non-durable protected copy must not be reported as a successful sync")
        } catch {
            XCTAssertEqual(
                error as? CloudSyncApplicationError,
                .localConflictCopyNeedsSaving
            )
            let message = try XCTUnwrap(
                CloudSyncApplicationError.localConflictCopyNeedsSaving.errorDescription
            )
            XCTAssertEqual(library.errorMessage, message)
        }

        let visible = library.exportSnapshot()
        XCTAssertEqual(visible.scripts.first(where: { $0.id == original.id }), cloud)
        XCTAssertEqual(
            visible.scripts.first(where: { $0.id != original.id })?.body,
            local.body
        )
        let persisted = try await persistence.load()
        XCTAssertEqual(persisted.scripts, [cloud])
    }

    @MainActor
    func testFailedNewScriptWritesNeverPublishPhantomDocuments() async throws {
        let original = ScriptDocument(title: "Original", body: "Durable")
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()

        await persistence.failNext(.upsert)
        let created = await library.createScript(title: "Phantom")
        XCTAssertNil(created)

        await persistence.failNext(.upsert)
        let duplicated = await library.duplicate(original.id)
        XCTAssertNil(duplicated)

        await persistence.failNext(.upsert)
        let imported = await library.addImported(ScriptDocument(title: "Import"))
        XCTAssertNil(imported)

        XCTAssertEqual(library.exportSnapshot(), initial)
        let persistedAfterFailedCreations = try await persistence.load()
        XCTAssertEqual(persistedAfterFailedCreations, initial)
        XCTAssertNotNil(library.errorMessage)
    }

    @MainActor
    func testFailedMetadataAndFolderWritesKeepCommittedVisibleState() async throws {
        let folder = ScriptFolder(name: "Original folder")
        let script = ScriptDocument(title: "Original", body: "Durable")
        let initial = LibrarySnapshot(
            scripts: [script],
            folders: [folder],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()

        await persistence.failNext(.saveFolders)
        let createdFolder = await library.createFolder(name: "Phantom folder")
        XCTAssertNil(createdFolder)

        await persistence.failNext(.saveFolders)
        let renamed = await library.renameFolder(folder.id, to: "Unsaved name")
        XCTAssertFalse(renamed)

        await persistence.failNext(.upsert)
        let moved = await library.moveScript(script.id, to: folder.id)
        XCTAssertFalse(moved)

        var changedSettings = initial.settings
        changedSettings.theme = .sepia
        await persistence.failNext(.saveSettings)
        let savedSettings = await library.saveSettings(changedSettings)
        XCTAssertFalse(savedSettings)

        await persistence.failNext(.upsert)
        let markedOpened = await library.markOpened(script.id)
        XCTAssertFalse(markedOpened)

        XCTAssertEqual(library.exportSnapshot(), initial)
        let persistedAfterFailedMetadata = try await persistence.load()
        XCTAssertEqual(persistedAfterFailedMetadata, initial)
        XCTAssertNotNil(library.errorMessage)
    }

    @MainActor
    func testFailedRestoreLeavesVisibleAndDurableLibrariesUntouched() async throws {
        let original = ScriptDocument(title: "Original", body: "Keep me")
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let backupFolder = ScriptFolder(name: "Backup")
        let backup = LibrarySnapshot(
            scripts: [ScriptDocument(title: "Restored", folderID: backupFolder.id)],
            folders: [backupFolder],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()

        for mode in [LibraryStore.RestoreMode.merge, .replace] {
            await persistence.failNext(.replace)
            let restored = await library.restore(backup, mode: mode)
            XCTAssertFalse(restored)
            XCTAssertEqual(library.exportSnapshot(), initial)
            let persistedAfterFailedRestore = try await persistence.load()
            XCTAssertEqual(persistedAfterFailedRestore, initial)
        }
    }

    @MainActor
    func testMergeRestorePreservesDivergentSameIDContentAsBackupCopy() async throws {
        var current = ScriptDocument(title: "Keynote", body: "Current words")
        current.updatedAt = Date(timeIntervalSince1970: 100)
        let initial = LibrarySnapshot(
            scripts: [current],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()

        var backupVersion = current
        backupVersion.body = "Divergent backup words"
        backupVersion.updatedAt = Date(timeIntervalSince1970: 10_000)
        let backup = LibrarySnapshot(
            scripts: [backupVersion],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )

        let restored = await library.restore(backup, mode: .merge)
        XCTAssertTrue(restored)
        XCTAssertEqual(library.script(id: current.id)?.body, "Current words")
        let backupCopy = library.scripts.first { $0.id != current.id }
        XCTAssertEqual(backupCopy?.body, "Divergent backup words")
        XCTAssertEqual(backupCopy?.title, "Keynote — Backup copy")
    }

    @MainActor
    func testRestoreRefusesWhileAnEditorDraftIsStaged() async throws {
        let current = ScriptDocument(title: "Keynote", body: "Current words")
        let initial = LibrarySnapshot(
            scripts: [current],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()

        var draft = current
        draft.body = "Unsaved editor words"
        XCTAssertTrue(library.stageEditorDraft(draft, editorOriginID: UUID()))

        let restored = await library.restore(initial, mode: .replace)
        XCTAssertFalse(restored)
        XCTAssertEqual(library.script(id: current.id)?.body, "Unsaved editor words")
        XCTAssertTrue(library.errorMessage?.contains("editor draft") == true)
    }

    @MainActor
    func testEditorUpdateRetainsItsOptimisticDraftWhenPersistenceFails() async throws {
        let original = ScriptDocument(title: "Original", body: "Durable")
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        var edited = original
        edited.body = "Retain for Retry"

        await persistence.failNext(.upsert)
        let saved = await library.update(edited)
        XCTAssertFalse(saved)

        XCTAssertEqual(library.script(id: original.id)?.body, edited.body)
        let persistedAfterFailedEditorSave = try await persistence.load()
        XCTAssertEqual(persistedAfterFailedEditorSave, initial)
    }

    @MainActor
    func testOpenedMetadataSurvivesAnEditorDraftCapturedBeforeMarkOpenedFinished() async throws {
        let original = ScriptDocument(title: "Draft", body: "Before opening")
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        let staleEditorBaseline = original

        let didMarkOpened = await library.markOpened(original.id)
        XCTAssertTrue(didMarkOpened)
        let openedChange = try XCTUnwrap(library.editorDocumentChange(id: original.id))
        XCTAssertNil(openedChange.editorOriginID)
        let openedAt = try XCTUnwrap(openedChange.document?.lastOpenedAt)

        let editorOriginID = UUID()
        var edited = staleEditorBaseline
        edited.body = "Edited after opening"
        XCTAssertTrue(library.stageEditorDraft(edited, editorOriginID: editorOriginID))
        let didSaveEdit = await library.update(edited, editorOriginID: editorOriginID)
        XCTAssertTrue(didSaveEdit)

        XCTAssertEqual(library.script(id: original.id)?.lastOpenedAt, openedAt)
        let persisted = try await persistence.load()
        XCTAssertEqual(persisted.scripts.first?.body, edited.body)
        XCTAssertEqual(persisted.scripts.first?.lastOpenedAt, openedAt)
    }

    @MainActor
    func testMarkOpenedRebasesMetadataWithoutCancelingABlockedPendingBodySave() async throws {
        let original = ScriptDocument(title: "Draft", body: "Durable baseline")
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        let editorOriginID = UUID()
        let autosave = EditorAutosaveController(
            initial: original,
            debounceDelay: .seconds(60)
        ) { document in
            await library.update(document, editorOriginID: editorOriginID)
        }
        await persistence.blockNext(.upsert)
        let markOpenedTask = Task { @MainActor in
            await library.markOpened(original.id)
        }
        await persistence.waitUntilBlocked(.upsert)

        var pendingDraft = original
        pendingDraft.body = "Body typed while markOpened was saving"
        XCTAssertTrue(library.stageEditorDraft(
            pendingDraft,
            editorOriginID: editorOriginID
        ))
        autosave.record(pendingDraft)
        let pendingSaveTask = Task { @MainActor in await autosave.flush() }
        for _ in 0..<10 { await Task.yield() }
        await persistence.resumeBlockedOperation()

        let didMarkOpened = await markOpenedTask.value
        XCTAssertTrue(didMarkOpened)
        let didSavePendingBody = await pendingSaveTask.value
        XCTAssertTrue(didSavePendingBody)

        let persisted = try await persistence.load()
        XCTAssertEqual(persisted.scripts.first?.body, pendingDraft.body)
        XCTAssertNotNil(persisted.scripts.first?.lastOpenedAt)
    }

    @MainActor
    func testDurableMutationFIFOComposesConcurrentFolderCreates() async throws {
        let initial = LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        await persistence.blockNext(.saveFolders)

        let firstTask = Task { @MainActor in await library.createFolder(name: "First") }
        await persistence.waitUntilBlocked(.saveFolders)
        XCTAssertTrue(library.folders.isEmpty)
        let secondTask = Task { @MainActor in await library.createFolder(name: "Second") }
        for _ in 0..<5 { await Task.yield() }
        await persistence.resumeBlockedOperation()

        let first = await firstTask.value
        let second = await secondTask.value
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(Set(library.folders.map(\.name)), ["First", "Second"])
        let persisted = try await persistence.load()
        XCTAssertEqual(
            Set(persisted.folders.map(\.name)),
            ["First", "Second"]
        )
    }

    @MainActor
    func testPrepareCloudSyncWaitsForEarlierDurableMutation() async throws {
        let initial = LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        await persistence.blockNext(.saveFolders)

        let createTask = Task { @MainActor in await library.createFolder(name: "Before sync") }
        await persistence.waitUntilBlocked(.saveFolders)
        let prepareTask = Task { @MainActor in
            try await library.prepareCloudSync(for: UUID())
        }
        for _ in 0..<5 { await Task.yield() }
        await persistence.resumeBlockedOperation()

        let createdFolder = await createTask.value
        let folder = try XCTUnwrap(createdFolder)
        let outcome = try await prepareTask.value
        guard case .ready(let input) = outcome else {
            return XCTFail("Expected ready prepare after durable mutation finished")
        }
        XCTAssertEqual(input.library.folders.map(\.id), [folder.id])
    }

    @MainActor
    func testCloudApplyAndFollowingLocalWriteStayFIFOOrdered() async throws {
        let original = ScriptDocument(
            title: "Original",
            body: "Device",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        var cloudCopy = original
        cloudCopy.body = "Cloud"
        cloudCopy.updatedAt = Date(timeIntervalSince1970: 200)
        let merged = LibrarySnapshot(
            scripts: [cloudCopy],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        await persistence.blockNext(.applyCloudSync)
        let result = CloudSyncResult(
            baseLibrary: initial,
            mergedLibrary: merged,
            summary: CloudSyncSummary(
                uploadedScripts: 0,
                downloadedScripts: 1,
                completedAt: Date(timeIntervalSince1970: 200)
            ),
            persistenceUpdate: CloudSyncPersistenceUpdate(
                accountID: UUID(),
                records: [],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: 0
            )
        )

        let applyTask = Task { @MainActor in try await library.applyCloudSyncResult(result) }
        await persistence.waitUntilBlocked(.applyCloudSync)
        let createTask = Task { @MainActor in await library.createScript(title: "After sync") }
        for _ in 0..<5 { await Task.yield() }
        await persistence.resumeBlockedOperation()

        try await applyTask.value
        let createdScript = await createTask.value
        let created = try XCTUnwrap(createdScript)
        let persisted = try await persistence.load()
        XCTAssertEqual(library.script(id: original.id)?.body, cloudCopy.body)
        XCTAssertNotNil(library.script(id: created.id))
        XCTAssertEqual(Set(persisted.scripts.map(\.id)), [original.id, created.id])
    }

    func testEditorExternalChangePolicyIgnoresItsOwnOriginAndReplacesExternalDocuments() {
        let editorOriginID = UUID()
        let remote = ScriptDocument(title: "Cloud title", body: "Cloud body")

        XCTAssertEqual(
            EditorExternalChangePolicy.decision(
                for: LibraryEditorDocumentChange(
                    revision: 1,
                    document: remote,
                    editorOriginID: editorOriginID
                ),
                editorOriginID: editorOriginID
            ),
            .ignore
        )
        XCTAssertEqual(
            EditorExternalChangePolicy.decision(
                for: LibraryEditorDocumentChange(
                    revision: 2,
                    document: remote,
                    editorOriginID: nil
                ),
                editorOriginID: editorOriginID
            ),
            .replace(remote)
        )
        XCTAssertEqual(
            EditorExternalChangePolicy.decision(
                for: LibraryEditorDocumentChange(
                    revision: 3,
                    document: nil,
                    editorOriginID: nil
                ),
                editorOriginID: editorOriginID
            ),
            .replace(nil)
        )
        XCTAssertEqual(
            EditorExternalChangePolicy.decision(
                for: LibraryEditorDocumentChange(
                    revision: 4,
                    document: remote,
                    editorOriginID: nil,
                    scope: .metadata(.folderID(nil))
                ),
                editorOriginID: editorOriginID
            ),
            .rebase(.folderID(nil))
        )
    }

    @MainActor
    func testExternalSyncReplacementCancelsStaleDraftAndKeepsConflictCopy() async throws {
        let original = ScriptDocument(
            title: "Shared script",
            body: "Baseline",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        let editorOriginID = UUID()
        let autosave = EditorAutosaveController(
            initial: original,
            debounceDelay: .seconds(60)
        ) { document in
            await library.update(document, editorOriginID: editorOriginID)
        }
        var staleLocalDraft = original
        staleLocalDraft.body = "Unsaved local wording"
        staleLocalDraft.updatedAt = Date(timeIntervalSince1970: 150)
        XCTAssertTrue(library.stageEditorDraft(
            staleLocalDraft,
            changedAt: staleLocalDraft.updatedAt,
            editorOriginID: editorOriginID
        ))
        autosave.record(staleLocalDraft)
        let syncBase = library.exportSnapshot()
        var remote = original
        remote.body = "Newer cloud wording"
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        var conflictCopy = staleLocalDraft
        conflictCopy.id = UUID()
        conflictCopy.title = "Shared script — Local conflict"
        let merged = LibrarySnapshot(
            scripts: [remote, conflictCopy],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let result = CloudSyncResult(
            baseLibrary: syncBase,
            mergedLibrary: merged,
            summary: CloudSyncSummary(
                uploadedScripts: 1,
                downloadedScripts: 1,
                completedAt: Date(timeIntervalSince1970: 200)
            ),
            persistenceUpdate: CloudSyncPersistenceUpdate(
                accountID: UUID(),
                records: [],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: 0
            )
        )

        try await library.applyCloudSyncResult(result)
        let change = try XCTUnwrap(library.editorDocumentChange(id: original.id))
        XCTAssertEqual(
            EditorExternalChangePolicy.decision(
                for: change,
                editorOriginID: editorOriginID
            ),
            .replace(remote)
        )
        autosave.cancelPending()
        let staleControllerIsEmpty = await autosave.flush()
        XCTAssertTrue(staleControllerIsEmpty)

        let persisted = try await persistence.load()
        XCTAssertEqual(persisted.scripts.first(where: { $0.id == original.id }), remote)
        XCTAssertEqual(persisted.scripts.first(where: { $0.id == conflictCopy.id }), conflictCopy)
    }

    @MainActor
    func testEditorSaveQueuedBehindExternalReplacementCannotOverwriteCloudContent() async throws {
        let original = ScriptDocument(
            title: "Shared script",
            body: "Baseline",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let initial = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let persistence = ControllableLibraryPersistence(snapshot: initial)
        let library = LibraryStore(persistence: persistence)
        await library.load()
        let editorOriginID = UUID()
        var staleDraft = original
        staleDraft.body = "Stale editor wording"
        let stagedAt = Date(timeIntervalSince1970: 150)
        XCTAssertTrue(library.stageEditorDraft(
            staleDraft,
            changedAt: stagedAt,
            editorOriginID: editorOriginID
        ))
        let syncBase = library.exportSnapshot()

        var remote = original
        remote.body = "Durable cloud wording"
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        let merged = LibrarySnapshot(
            scripts: [remote],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let result = CloudSyncResult(
            baseLibrary: syncBase,
            mergedLibrary: merged,
            summary: CloudSyncSummary(
                uploadedScripts: 0,
                downloadedScripts: 1,
                completedAt: Date(timeIntervalSince1970: 200)
            ),
            persistenceUpdate: CloudSyncPersistenceUpdate(
                accountID: UUID(),
                records: [],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: 0
            )
        )
        await persistence.blockNext(.applyCloudSync)

        let applyTask = Task { @MainActor in
            try await library.applyCloudSyncResult(result)
        }
        await persistence.waitUntilBlocked(.applyCloudSync)
        let staleSaveTask = Task { @MainActor in
            await library.update(staleDraft, editorOriginID: editorOriginID)
        }
        for _ in 0..<10 { await Task.yield() }
        await persistence.resumeBlockedOperation()

        try await applyTask.value
        let staleSaveSucceeded = await staleSaveTask.value

        XCTAssertFalse(staleSaveSucceeded)
        XCTAssertEqual(library.script(id: original.id), remote)
        let persisted = try await persistence.load()
        XCTAssertEqual(persisted.scripts, [remote])
    }

    func testDocumentInsightsCountsUserVisibleCharactersAndParagraphs() {
        let text = "Hello 👨‍👩‍👧‍👦 world\n\nSecond line"
        let insights = DocumentInsights(text: text, wordsPerMinute: 120)

        XCTAssertEqual(insights.wordCount, 5)
        XCTAssertEqual(insights.characterCount, text.count)
        XCTAssertEqual(insights.charactersExcludingWhitespace, 21)
        XCTAssertEqual(insights.paragraphCount, 2)
        XCTAssertEqual(insights.estimatedDuration, 2.5, accuracy: 0.001)
    }

    func testDocumentInsightsHandlesEmptyTextAndInvalidPace() {
        let insights = DocumentInsights(text: "", wordsPerMinute: 0)

        XCTAssertEqual(insights.wordCount, 0)
        XCTAssertEqual(insights.characterCount, 0)
        XCTAssertEqual(insights.paragraphCount, 0)
        XCTAssertEqual(insights.estimatedDuration, 0)
    }

    func testFindIsCaseInsensitiveByDefault() {
        let matches = FindReplaceEngine.matches(query: "hello", in: "Hello HELLO hello")
        XCTAssertEqual(matches.count, 3)
    }

    func testCaseSensitiveAndWholeWordOptions() {
        let options = FindReplaceOptions(isCaseSensitive: true, matchesWholeWords: true)
        let matches = FindReplaceEngine.matches(
            query: "cat",
            in: "cat Cat concatenate cat2 _cat cat.",
            options: options
        )

        XCTAssertEqual(matches.count, 2)
    }

    func testQueryIsLiteralRatherThanRegularExpression() {
        let matches = FindReplaceEngine.matches(query: "a.b", in: "a.b aab a.b")
        XCTAssertEqual(matches.count, 2)
    }

    func testReplaceAllTreatsDollarAndBackslashLiterally() {
        let result = FindReplaceEngine.replacingAll(
            query: "name",
            with: #"$1\draft"#,
            in: "Name and name"
        )

        XCTAssertEqual(result.text, #"$1\draft and $1\draft"#)
        XCTAssertEqual(result.replacementCount, 2)
    }

    func testReplacingOneMatchUsesUTF16RangeSafely() throws {
        let text = "👋 hello hello"
        let matches = FindReplaceEngine.matches(query: "hello", in: text)
        let second = try XCTUnwrap(matches.last)
        let result = FindReplaceEngine.replacing(match: second, with: "world", in: text)

        XCTAssertEqual(result.text, "👋 hello world")
        XCTAssertEqual(result.replacementCount, 1)
    }

    func testWholeWordMatchingSupportsAccentedLetters() {
        let options = FindReplaceOptions(matchesWholeWords: true)
        let matches = FindReplaceEngine.matches(
            query: "café",
            in: "CAFÉ caféine café.",
            options: options
        )

        XCTAssertEqual(matches.count, 2)
    }
}

private actor BlockingEditorSaveRecorder {
    private var documents: [ScriptDocument] = []
    private var firstSaveIsBlocked = false
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?

    func save(_ document: ScriptDocument) async -> Bool {
        documents.append(document)
        if documents.count == 1 {
            firstSaveIsBlocked = true
            await withCheckedContinuation { continuation in
                firstSaveContinuation = continuation
            }
        }
        return true
    }

    func waitUntilFirstSaveIsBlocked() async {
        while !firstSaveIsBlocked { await Task.yield() }
    }

    func resumeFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }

    func savedDocuments() -> [ScriptDocument] { documents }
}

private actor BlockingCloudApplyPersistence: LibraryPersistence {
    private var snapshot: LibrarySnapshot
    private var isApplyWaiting = false
    private var applyContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> LibrarySnapshot { snapshot }

    func replace(with snapshot: LibrarySnapshot) async throws {
        self.snapshot = snapshot
    }

    func upsert(_ script: ScriptDocument) async throws {
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
        isApplyWaiting = true
        await withCheckedContinuation { continuation in
            applyContinuation = continuation
        }
        self.snapshot = snapshot
    }

    func waitUntilApplyIsWaiting() async {
        while !isApplyWaiting { await Task.yield() }
    }

    func resumeApply() {
        let continuation = applyContinuation
        applyContinuation = nil
        continuation?.resume()
    }
}

private actor ControllableLibraryPersistence: LibraryPersistence {
    enum Operation: Hashable, Sendable {
        case replace
        case upsert
        case upsertCloudConflict
        case deleteFolder
        case saveFolders
        case saveSettings
        case prepareCloudSync
        case applyCloudSync
    }

    private struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "The test write failed before it became durable." }
    }

    private var snapshot: LibrarySnapshot
    private var failures: Set<Operation> = []
    private var operationToBlock: Operation?
    private var blockedOperation: Operation?
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
    }

    func failNext(_ operation: Operation) {
        failures.insert(operation)
    }

    func blockNext(_ operation: Operation) {
        operationToBlock = operation
    }

    func waitUntilBlocked(_ operation: Operation) async {
        while blockedOperation != operation { await Task.yield() }
    }

    func resumeBlockedOperation() {
        let continuation = blockedContinuation
        blockedContinuation = nil
        continuation?.resume()
    }

    func load() async throws -> LibrarySnapshot { snapshot }

    func replace(with snapshot: LibrarySnapshot) async throws {
        try await intercept(.replace)
        self.snapshot = snapshot
    }

    func upsert(_ script: ScriptDocument) async throws {
        try await intercept(.upsert)
        if let index = snapshot.scripts.firstIndex(where: { $0.id == script.id }) {
            snapshot.scripts[index] = script
        } else {
            snapshot.scripts.append(script)
        }
    }

    func upsertCloudConflict(_ script: ScriptDocument, accountID: UUID) async throws {
        try await intercept(.upsertCloudConflict)
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
        try await intercept(.deleteFolder)
        snapshot.folders.removeAll { $0.id == id }
        for script in updatedScripts {
            if let index = snapshot.scripts.firstIndex(where: { $0.id == script.id }) {
                snapshot.scripts[index] = script
            }
        }
    }

    func saveSettings(_ settings: ReaderSettings, seeded: Bool) async throws {
        try await intercept(.saveSettings)
        snapshot.settings = settings
        snapshot.seeded = seeded
    }

    func saveFolders(_ folders: [ScriptFolder]) async throws {
        try await intercept(.saveFolders)
        snapshot.folders = folders
    }

    func prepareCloudSync(
        accountID: UUID,
        localScriptIDs: Set<UUID>,
        localFolderIDs: Set<UUID>
    ) async throws -> CloudLocalSyncState {
        try await intercept(.prepareCloudSync)
        return .empty(accountID: accountID)
    }

    func applyCloudSync(
        snapshot: LibrarySnapshot,
        update: CloudSyncPersistenceUpdate
    ) async throws {
        try await intercept(.applyCloudSync)
        self.snapshot = snapshot
    }

    private func intercept(_ operation: Operation) async throws {
        if operationToBlock == operation {
            operationToBlock = nil
            blockedOperation = operation
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
            blockedOperation = nil
        }
        if failures.remove(operation) != nil {
            throw InjectedFailure()
        }
    }
}
