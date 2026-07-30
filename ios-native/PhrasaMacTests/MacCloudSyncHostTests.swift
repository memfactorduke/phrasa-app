import Foundation
import SQLite3
import XCTest
import PhrasaDomain
import PhrasaPersistence
import PhrasaSync
@testable import PhrasaMac

/// Deterministic Mac host/adapter parity for PhrasaSync prepare/apply.
@MainActor
final class MacCloudSyncHostTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhrasaMacCloudSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - Draft barrier

    func testStagedDraftBlocksPrepareUntilDurableSave() async throws {
        let original = ScriptDocument(
            title: "Talk",
            body: "Durable baseline",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let (store, persistence) = try await makeClaimableSQLiteStore(scripts: [original])

        var staged = original
        staged.body = "Unsaved staged wording"
        XCTAssertTrue(store.stageEditorDraft(
            staged,
            changedAt: Date(timeIntervalSince1970: 200),
            editorOriginID: UUID()
        ))

        XCTAssertFalse(store.cloudSyncHostDirtyState.eligibility.isEligible)
        let deferred = try await store.prepareCloudSync(for: UUID())
        guard case .deferred(let reason) = deferred else {
            return XCTFail("Staged draft must block prepare")
        }
        XCTAssertEqual(reason, .editorContentNotPersisted(scriptCount: 1))

        let diskWhileDirty = try await persistence.load()
        XCTAssertEqual(diskWhileDirty.scripts.first?.body, original.body)

        let saved = await store.update(staged, editorOriginID: nil)
        XCTAssertTrue(saved)
        XCTAssertTrue(store.cloudSyncHostDirtyState.eligibility.isEligible)

        let ready = try await store.prepareCloudSync(for: UUID())
        guard case .ready(let input) = ready else {
            return XCTFail("Durable save must clear the draft barrier")
        }
        XCTAssertEqual(input.library.scripts.first?.body, staged.body)
        let diskAfterSave = try await persistence.load()
        XCTAssertEqual(diskAfterSave.scripts.first?.body, staged.body)
    }

    func testFailedSaveRemainsDirtyAndBlocksPushPull() async throws {
        let original = ScriptDocument(
            title: "Draft",
            body: "Baseline",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let base = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: .init(),
            seeded: true
        )
        let persistence = ControllableMacLibraryPersistence(snapshot: base)
        let store = MacLibraryStore(persistence: persistence)
        await store.load()
        XCTAssertTrue(store.isLoaded)

        var edited = original
        edited.body = "Will not stick on disk"
        await persistence.failNext(.upsert)
        let saved = await store.update(edited)
        XCTAssertFalse(saved)
        XCTAssertFalse(store.cloudSyncHostDirtyState.eligibility.isEligible)
        XCTAssertEqual(store.script(id: original.id)?.body, edited.body)

        let deferred = try await store.prepareCloudSync(for: UUID())
        guard case .deferred(let reason) = deferred else {
            return XCTFail("Failed save must keep the host dirty")
        }
        XCTAssertEqual(reason, .editorContentNotPersisted(scriptCount: 1))

        // Shared engine must refuse push/pull with the same dirty signal.
        // Matching account IDs so the live preflight (not accountChanged) is
        // the gate under test after prepare already deferred for dirty state.
        let accountID = UUID()
        do {
            _ = try await LibrarySyncEngine.synchronize(
                accountID: accountID,
                input: CloudSyncInput(
                    library: store.exportSnapshot(),
                    state: .empty(accountID: accountID)
                ),
                repository: InMemoryCloudLibraryRepository(accountID: accountID),
                preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                }
            )
            XCTFail("Engine must not push staged-failed content")
        } catch {
            XCTAssertEqual(
                error as? CloudSyncEligibilityError,
                .deferred(.editorContentNotPersisted(scriptCount: 1))
            )
        }

        let disk = try await persistence.load()
        XCTAssertEqual(disk.scripts.first?.body, original.body)
    }

    // MARK: - Interleaved edit during apply

    func testInterleavedLocalEditDuringApplyBecomesConflictCopy() async throws {
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
        let persistence = ControllableMacLibraryPersistence(snapshot: base)
        let store = MacLibraryStore(persistence: persistence)
        await store.load()

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

        await persistence.blockNext(.applyCloudSync)
        let applyTask = Task { @MainActor in
            try await store.applyCloudSyncResult(result)
        }
        await persistence.waitUntilBlocked(.applyCloudSync)

        var localEdit = original
        localEdit.body = "Typed while persistence was awaiting"
        XCTAssertTrue(store.stageEditorDraft(
            localEdit,
            changedAt: Date(timeIntervalSince1970: 200),
            editorOriginID: UUID()
        ))
        await persistence.resumeBlockedOperation()
        try await applyTask.value

        let visible = store.exportSnapshot()
        XCTAssertEqual(visible.scripts.first(where: { $0.id == original.id }), cloudCopy)
        let conflict = try XCTUnwrap(visible.scripts.first(where: { $0.id != original.id }))
        XCTAssertEqual(conflict.body, localEdit.body)
        XCTAssertTrue(conflict.title.contains("Local conflict"))
        XCTAssertEqual(
            conflict.id,
            CloudScriptConflictCopy.make(local: localEdit, accountID: accountID).id
        )
        let persisted = try await persistence.load()
        XCTAssertEqual(Set(persisted.scripts.map(\.id)), Set(visible.scripts.map(\.id)))
    }

    // MARK: - Deletion vs remote edit

    func testLocalDeletionVersusRemoteEditResurrectsEditedRemote() async throws {
        let original = ScriptDocument(
            title: "Shared",
            body: "baseline",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let (store, _) = try await makeClaimableSQLiteStore(scripts: [original])
        let accountID = UUID()

        // First prepare claims ownership + establishes a syncable baseline.
        let prepared = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let claimInput) = prepared else {
            return XCTFail("Expected ready claim prepare")
        }
        XCTAssertNotNil(claimInput.state.currentAccountRecords[original.id])
        // Seed last-sync fingerprint as if a prior successful sync occurred.
        let syncedRecord = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: original.id,
            lastSyncedUpdatedAt: original.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(original)
        )
        try await store.applyCloudSyncResult(
            CloudSyncResult(
                baseLibrary: claimInput.library,
                mergedLibrary: claimInput.library,
                summary: CloudSyncSummary(
                    uploadedScripts: 1,
                    downloadedScripts: 0,
                    completedAt: Date(timeIntervalSince1970: 20)
                ),
                persistenceUpdate: CloudSyncPersistenceUpdate(
                    accountID: accountID,
                    records: [syncedRecord],
                    folderRecords: [],
                    tombstones: [],
                    clearedTombstoneIDs: [],
                    folderTombstones: [],
                    clearedFolderTombstoneIDs: [],
                    expectedMutationRevision: claimInput.state.mutationRevision
                )
            )
        )

        await store.delete(original.id)
        XCTAssertNil(store.script(id: original.id))

        let afterDelete = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let deleteInput) = afterDelete else {
            return XCTFail("Expected ready prepare after durable delete")
        }
        XCTAssertNotNil(deleteInput.state.tombstonesByScriptID[original.id])
        XCTAssertFalse(deleteInput.library.scripts.contains(where: { $0.id == original.id }))

        // Remote was edited after the last shared baseline. Local tombstone must
        // not discard the divergent cloud content — remote edit wins and clears
        // the tombstone (deletion-vs-remote-edit parity with iOS/engine).
        var remoteEdited = original
        remoteEdited.body = "remote edited after local delete"
        remoteEdited.updatedAt = Date(timeIntervalSince1970: 40)
        let repo = InMemoryCloudLibraryRepository(
            accountID: accountID,
            scripts: [remoteEdited]
        )
        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: deleteInput,
            repository: repo,
            preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                },
            now: { Date(timeIntervalSince1970: 50) }
        )
        XCTAssertEqual(
            result.mergedLibrary.scripts.first(where: { $0.id == original.id })?.body,
            remoteEdited.body
        )
        XCTAssertTrue(result.persistenceUpdate.clearedTombstoneIDs.contains(original.id))
        XCTAssertFalse(result.persistenceUpdate.tombstones.contains(where: { $0.scriptID == original.id }))

        try await store.applyCloudSyncResult(result)
        XCTAssertEqual(store.script(id: original.id)?.body, remoteEdited.body)
        let reopenedPrepare = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let reopened) = reopenedPrepare else {
            return XCTFail("Expected ready prepare after resurrection apply")
        }
        XCTAssertNil(reopened.state.tombstonesByScriptID[original.id])
    }

    func testLocalDeletionOfExactRemoteBaselineDeletesCloudCopy() async throws {
        let original = ScriptDocument(
            title: "Exact",
            body: "baseline",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let (store, _) = try await makeClaimableSQLiteStore(scripts: [original])
        let accountID = UUID()
        let prepared = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let claimInput) = prepared else {
            return XCTFail("Expected claim prepare")
        }
        let syncedRecord = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: original.id,
            lastSyncedUpdatedAt: original.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(original)
        )
        try await store.applyCloudSyncResult(
            CloudSyncResult(
                baseLibrary: claimInput.library,
                mergedLibrary: claimInput.library,
                summary: CloudSyncSummary(
                    uploadedScripts: 1,
                    downloadedScripts: 0,
                    completedAt: Date(timeIntervalSince1970: 20)
                ),
                persistenceUpdate: CloudSyncPersistenceUpdate(
                    accountID: accountID,
                    records: [syncedRecord],
                    folderRecords: [],
                    tombstones: [],
                    clearedTombstoneIDs: [],
                    folderTombstones: [],
                    clearedFolderTombstoneIDs: [],
                    expectedMutationRevision: claimInput.state.mutationRevision
                )
            )
        )
        await store.delete(original.id)
        let afterDelete = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let deleteInput) = afterDelete else {
            return XCTFail("Expected ready prepare after delete")
        }
        // Remote still matches last-sync fingerprint → tombstone wins.
        let repo = InMemoryCloudLibraryRepository(
            accountID: accountID,
            scripts: [original]
        )
        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: deleteInput,
            repository: repo,
            preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                },
            now: { Date(timeIntervalSince1970: 50) }
        )
        XCTAssertFalse(result.mergedLibrary.scripts.contains(where: { $0.id == original.id }))
        XCTAssertTrue(result.persistenceUpdate.tombstones.contains(where: { $0.scriptID == original.id }))
        try await store.applyCloudSyncResult(result)
        XCTAssertNil(store.script(id: original.id))
        let remoteAfter = try await repo.fetchScripts(accountID: accountID, updatedAfter: nil)
        XCTAssertFalse(remoteAfter.contains(where: { $0.id == original.id }))
    }

    // MARK: - Conflict copy via engine + apply

    func testDivergentLocalAndRemoteProducesDeterministicConflictCopyOnApply() async throws {
        let baseline = ScriptDocument(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Shared",
            body: "baseline",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let (store, _) = try await makeClaimableSQLiteStore(scripts: [baseline])
        let accountID = UUID()

        let claim = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let claimInput) = claim else {
            return XCTFail("Expected claim prepare")
        }
        XCTAssertNotNil(claimInput.state.currentAccountRecords[baseline.id])
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: baseline.id,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
        )
        try await store.applyCloudSyncResult(
            CloudSyncResult(
                baseLibrary: claimInput.library,
                mergedLibrary: claimInput.library,
                summary: CloudSyncSummary(
                    uploadedScripts: 1,
                    downloadedScripts: 0,
                    completedAt: Date(timeIntervalSince1970: 15)
                ),
                persistenceUpdate: CloudSyncPersistenceUpdate(
                    accountID: accountID,
                    records: [record],
                    folderRecords: [],
                    tombstones: [],
                    clearedTombstoneIDs: [],
                    folderTombstones: [],
                    clearedFolderTombstoneIDs: [],
                    expectedMutationRevision: claimInput.state.mutationRevision
                )
            )
        )

        var local = baseline
        local.body = "local edit"
        local.updatedAt = Date(timeIntervalSince1970: 20)
        let localSaved = await store.update(local)
        XCTAssertTrue(localSaved)

        var remote = baseline
        remote.body = "remote edit"
        remote.updatedAt = Date(timeIntervalSince1970: 30)

        let ready = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let input) = ready else {
            return XCTFail("Expected ready prepare for conflict merge")
        }
        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: input,
            repository: InMemoryCloudLibraryRepository(
                accountID: accountID,
                scripts: [remote]
            ),
            preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                },
            now: { Date(timeIntervalSince1970: 100) }
        )
        let expectedConflict = CloudScriptConflictCopy.make(local: local, accountID: accountID)
        XCTAssertEqual(
            Set(result.mergedLibrary.scripts.map(\.id)),
            [remote.id, expectedConflict.id]
        )

        try await store.applyCloudSyncResult(result)
        XCTAssertEqual(store.script(id: baseline.id)?.body, "remote edit")
        XCTAssertEqual(store.script(id: expectedConflict.id)?.body, "local edit")
        XCTAssertTrue(store.cloudSyncHostDirtyState.eligibility.isEligible)
    }

    // MARK: - Account change / quarantine / stale generation

    func testAccountChangeQuarantinesBulkRestoredRowsAndSecondAccountCannotClaim() async throws {
        let script = ScriptDocument(title: "Restored backup row", body: "private")
        let folder = ScriptFolder(name: "Restored folder")
        // Bulk replace (backup restore) quarantines unowned rows.
        let (store, _) = try await makeSQLiteStore(
            scripts: [script],
            folders: [folder],
            quarantineViaReplace: true
        )

        let accountA = UUID()
        let accountB = UUID()

        let afterRestoreA = try await store.prepareCloudSync(for: accountA)
        guard case .ready(let quarantinedA) = afterRestoreA else {
            return XCTFail("Expected ready prepare after restore")
        }
        XCTAssertNil(quarantinedA.state.currentAccountRecords[script.id])
        XCTAssertTrue(quarantinedA.state.scriptIDsOwnedByOtherAccounts.contains(script.id))
        XCTAssertTrue(quarantinedA.state.folderIDsOwnedByOtherAccounts.contains(folder.id))

        let afterRestoreB = try await store.prepareCloudSync(for: accountB)
        guard case .ready(let quarantinedB) = afterRestoreB else {
            return XCTFail("Expected ready prepare for second account")
        }
        XCTAssertTrue(quarantinedB.state.scriptIDsOwnedByOtherAccounts.contains(script.id))
        XCTAssertNil(quarantinedB.state.currentAccountRecords[script.id])

        // Foreign content must never upload for account B.
        let engineResult = try await LibrarySyncEngine.synchronize(
            accountID: accountB,
            input: quarantinedB,
            repository: InMemoryCloudLibraryRepository(accountID: accountB),
            preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                }
        )
        XCTAssertEqual(engineResult.summary.uploadedScripts, 0)
        XCTAssertGreaterThanOrEqual(engineResult.summary.excludedLocalScriptCount, 1)
        XCTAssertTrue(engineResult.mergedLibrary.scripts.contains(where: { $0.id == script.id }))
    }

    func testStaleMutationRevisionRejectsApplyAndKeepsLocalEdit() async throws {
        let original = ScriptDocument(
            title: "Original",
            body: "before",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let (store, persistence) = try await makeClaimableSQLiteStore(scripts: [original])
        let accountID = UUID()

        let prepared = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let input) = prepared else {
            return XCTFail("Expected ready prepare")
        }

        var localEdit = original
        localEdit.body = "local newer"
        localEdit.updatedAt = Date(timeIntervalSince1970: 20)
        let editSaved = await store.update(localEdit)
        XCTAssertTrue(editSaved)

        var remote = original
        remote.body = "stale cloud merge"
        remote.updatedAt = Date(timeIntervalSince1970: 15)
        do {
            try await store.applyCloudSyncResult(
                CloudSyncResult(
                    baseLibrary: input.library,
                    mergedLibrary: LibrarySnapshot(
                        scripts: [remote],
                        folders: [],
                        settings: .init(),
                        seeded: true
                    ),
                    summary: CloudSyncSummary(
                        uploadedScripts: 0,
                        downloadedScripts: 1,
                        completedAt: Date(timeIntervalSince1970: 30)
                    ),
                    persistenceUpdate: CloudSyncPersistenceUpdate(
                        accountID: accountID,
                        records: [],
                        folderRecords: [],
                        tombstones: [],
                        clearedTombstoneIDs: [],
                        folderTombstones: [],
                        clearedFolderTombstoneIDs: [],
                        expectedMutationRevision: input.state.mutationRevision
                    )
                )
            )
            XCTFail("Stale generation must fail closed")
        } catch {
            XCTAssertEqual(error as? CloudSyncApplicationError, .localLibraryChanged)
        }

        XCTAssertEqual(store.script(id: original.id)?.body, "local newer")
        let disk = try await persistence.load()
        XCTAssertEqual(disk.scripts.first?.body, "local newer")
    }

    func testSynchronizationLaneRejectsStaleGeneration() {
        var lane = CloudSynchronizationLane()
        let first = lane.begin(accountID: UUID())
        let second = lane.begin(accountID: first.accountID)
        XCTAssertTrue(lane.isActive(second))
        XCTAssertFalse(lane.isActive(first))
        XCTAssertNil(
            lane.resolvedCompletionStatus(
                .succeeded(CloudSyncSummary(
                    uploadedScripts: 0,
                    downloadedScripts: 0,
                    completedAt: Date(timeIntervalSince1970: 1)
                )),
                for: first,
                currentAccountID: first.accountID
            )
        )
        let status = lane.resolvedCompletionStatus(
            .failed("stale loser"),
            for: second,
            currentAccountID: second.accountID
        )
        XCTAssertEqual(status, .failed("stale loser"))
    }

    // MARK: - Pre-provenance / first-account / no silent adoption

    /// Ownership-schema migration quarantines pre-provenance rows. First
    /// account claims only newly created unowned rows; second account claims
    /// neither legacy nor first-account content. Explicit protectedLocalContent
    /// is non-empty for quarantine — never silent adoption.
    func testPreProvenanceQuarantineFirstAccountClaimAndSecondAccountIsolation() async throws {
        let dbURL = temporaryDirectory.appendingPathComponent("pre-provenance-\(UUID().uuidString).sqlite3")
        let legacyScript = ScriptDocument(
            title: "Legacy pre-provenance script",
            body: "existed before ownership schema",
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let legacyFolder = ScriptFolder(
            name: "Legacy pre-provenance folder",
            createdAt: Date(timeIntervalSince1970: 40)
        )

        // Seed claimable rows, then strip ownership tables + marker so reopen
        // runs migrateCloudOwnershipIfNeeded and quarantines them.
        let fixture = SQLitePersistenceClient(fileURL: dbURL)
        try await fixture.replace(
            with: LibrarySnapshot(
                scripts: [],
                folders: [],
                settings: .init(),
                seeded: true
            )
        )
        try await fixture.upsert(legacyScript)
        try await fixture.saveFolders([legacyFolder])
        let fixtureDB = try openSQLite(at: dbURL)
        try executeSQL(fixtureDB, "DELETE FROM cloud_script_sync_state")
        try executeSQL(fixtureDB, "DELETE FROM cloud_folder_sync_state")
        try executeSQL(
            fixtureDB,
            "DELETE FROM metadata WHERE key = '\(LibrarySchema.ownershipSchemaKey)'"
        )
        sqlite3_close(fixtureDB)

        let store = MacLibraryStore(
            persistence: LibraryPersistenceFactory.makeShipping(fileURL: dbURL)
        )
        await store.load()
        XCTAssertTrue(store.isLoaded)

        // Newly created unowned rows after provenance exists stay claimable.
        let createdScript = await store.createScript(
            title: "Post-upgrade unowned",
            body: "claimable"
        )
        let newScript = try XCTUnwrap(createdScript)
        let createdFolder = await store.createFolder(name: "Post-upgrade folder")
        let newFolder = try XCTUnwrap(createdFolder)

        let accountA = UUID()
        let accountB = UUID()

        let firstPrepare = try await store.prepareCloudSync(for: accountA)
        guard case .ready(let firstInput) = firstPrepare else {
            return XCTFail("Expected ready prepare for first account")
        }

        // Legacy/pre-provenance: quarantined for every real account.
        XCTAssertNil(firstInput.state.currentAccountRecords[legacyScript.id])
        XCTAssertTrue(firstInput.state.scriptIDsOwnedByOtherAccounts.contains(legacyScript.id))
        XCTAssertNil(firstInput.state.currentAccountFolderRecords[legacyFolder.id])
        XCTAssertTrue(firstInput.state.folderIDsOwnedByOtherAccounts.contains(legacyFolder.id))

        // Newly unowned: first account claims, not auto-quarantined.
        XCTAssertEqual(
            firstInput.state.currentAccountRecords[newScript.id]?.accountID,
            accountA
        )
        XCTAssertFalse(firstInput.state.scriptIDsOwnedByOtherAccounts.contains(newScript.id))
        XCTAssertEqual(
            firstInput.state.currentAccountFolderRecords[newFolder.id]?.accountID,
            accountA
        )
        XCTAssertFalse(firstInput.state.folderIDsOwnedByOtherAccounts.contains(newFolder.id))

        // Explicit adoption-required / quarantine surface (never silent claim).
        let protected = firstInput.protectedLocalContent
        XCTAssertTrue(protected.adoptionRequiredOrQuarantined)
        XCTAssertEqual(protected.scriptCount, 1)
        XCTAssertEqual(protected.folderCount, 1)
        XCTAssertEqual(firstInput.excludedLocalScriptCount, 1)
        XCTAssertEqual(firstInput.excludedLocalFolderCount, 1)

        let accountARepo = InMemoryCloudLibraryRepository(accountID: accountA)
        let firstSync = try await LibrarySyncEngine.synchronize(
            accountID: accountA,
            input: firstInput,
            repository: accountARepo,
            preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                }
        )
        XCTAssertEqual(firstSync.summary.uploadedScripts, 1)
        XCTAssertEqual(firstSync.summary.excludedLocalScriptCount, 1)
        XCTAssertEqual(firstSync.summary.excludedLocalFolderCount, 1)
        // Quarantined legacy remains on the device library but never uploads.
        XCTAssertTrue(firstSync.mergedLibrary.scripts.contains(where: { $0.id == legacyScript.id }))
        let uploadedA = try await accountARepo.fetchScripts(accountID: accountA, updatedAfter: nil)
        XCTAssertEqual(Set(uploadedA.map(\.id)), [newScript.id])
        XCTAssertFalse(uploadedA.contains(where: { $0.id == legacyScript.id }))

        // Second account: cannot claim legacy quarantine or first-account rows.
        let secondPrepare = try await store.prepareCloudSync(for: accountB)
        guard case .ready(let secondInput) = secondPrepare else {
            return XCTFail("Expected ready prepare for second account")
        }
        XCTAssertNil(secondInput.state.currentAccountRecords[legacyScript.id])
        XCTAssertNil(secondInput.state.currentAccountRecords[newScript.id])
        XCTAssertTrue(secondInput.state.scriptIDsOwnedByOtherAccounts.contains(legacyScript.id))
        XCTAssertTrue(secondInput.state.scriptIDsOwnedByOtherAccounts.contains(newScript.id))
        XCTAssertTrue(secondInput.state.folderIDsOwnedByOtherAccounts.contains(legacyFolder.id))
        XCTAssertTrue(secondInput.state.folderIDsOwnedByOtherAccounts.contains(newFolder.id))
        XCTAssertEqual(secondInput.protectedLocalContent.scriptCount, 2)
        XCTAssertEqual(secondInput.protectedLocalContent.folderCount, 2)
        XCTAssertTrue(secondInput.protectedLocalContent.adoptionRequiredOrQuarantined)

        let secondSync = try await LibrarySyncEngine.synchronize(
            accountID: accountB,
            input: secondInput,
            repository: InMemoryCloudLibraryRepository(accountID: accountB),
            preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                }
        )
        XCTAssertEqual(secondSync.summary.uploadedScripts, 0)
        XCTAssertEqual(secondSync.summary.excludedLocalScriptCount, 2)
        XCTAssertEqual(secondSync.summary.excludedLocalFolderCount, 2)
    }

    func testBulkRestoreSurfacesExplicitQuarantineAndNeverSilentAdoption() async throws {
        let script = ScriptDocument(title: "Restored private", body: "backup body")
        let folder = ScriptFolder(name: "Restored private folder")
        let (store, _) = try await makeSQLiteStore(
            scripts: [script],
            folders: [folder],
            quarantineViaReplace: true
        )
        let account = UUID()
        let outcome = try await store.prepareCloudSync(for: account)
        guard case .ready(let input) = outcome else {
            return XCTFail("Expected ready prepare after bulk restore")
        }
        XCTAssertTrue(input.protectedLocalContent.adoptionRequiredOrQuarantined)
        XCTAssertEqual(input.protectedLocalContent.scriptCount, 1)
        XCTAssertEqual(input.protectedLocalContent.folderCount, 1)
        XCTAssertNil(input.state.currentAccountRecords[script.id])
        XCTAssertTrue(input.state.scriptIDsOwnedByOtherAccounts.contains(script.id))

        let repo = InMemoryCloudLibraryRepository(accountID: account)
        let result = try await LibrarySyncEngine.synchronize(
            accountID: account,
            input: input,
            repository: repo,
            preflight: CloudSyncPreflight.requireLiveHost {
                    await MainActor.run { store.cloudSyncHostDirtyState }
                }
        )
        XCTAssertEqual(result.summary.uploadedScripts, 0)
        XCTAssertEqual(result.summary.excludedLocalScriptCount, 1)
        let remote = try await repo.fetchScripts(accountID: account, updatedAfter: nil)
        XCTAssertTrue(remote.isEmpty, "Quarantined restore must never silently upload")
    }

    func testFirstAccountClaimsOnlyNewlyUnownedRows() async throws {
        let claimable = ScriptDocument(title: "Fresh local", body: "mine")
        let (store, _) = try await makeClaimableSQLiteStore(scripts: [claimable])
        let accountA = UUID()
        let accountB = UUID()

        let first = try await store.prepareCloudSync(for: accountA)
        guard case .ready(let firstInput) = first else {
            return XCTFail("Expected first-account claim prepare")
        }
        XCTAssertEqual(firstInput.state.currentAccountRecords[claimable.id]?.accountID, accountA)
        XCTAssertTrue(firstInput.protectedLocalContent.isEmpty)
        XCTAssertFalse(firstInput.protectedLocalContent.adoptionRequiredOrQuarantined)

        let second = try await store.prepareCloudSync(for: accountB)
        guard case .ready(let secondInput) = second else {
            return XCTFail("Expected second-account prepare")
        }
        XCTAssertNil(secondInput.state.currentAccountRecords[claimable.id])
        XCTAssertTrue(secondInput.state.scriptIDsOwnedByOtherAccounts.contains(claimable.id))
        XCTAssertEqual(secondInput.protectedLocalContent.scriptCount, 1)
        XCTAssertTrue(secondInput.protectedLocalContent.adoptionRequiredOrQuarantined)
    }

    // MARK: - Timestamp OCC precision (Mac store / adapter boundary)

    func testTimestampOCCPrecisionSurvivesMacStoreApplyAndPrepare() async throws {
        // Sub-millisecond separation must remain distinct at microsecond OCC.
        let baseMicros: Int64 = 1_700_000_000_123_456
        let halfMillisecondLater: Int64 = baseMicros + 500 // 0.5 ms
        let base = dateFromMicroseconds(baseMicros)
        let halfMsLater = dateFromMicroseconds(halfMillisecondLater)
        XCTAssertFalse(
            CloudTimestampPrecision.matches(base, halfMsLater),
            "0.5ms gap must not collapse to the same OCC microsecond"
        )
        XCTAssertTrue(
            CloudTimestampPrecision.matches(base, CloudTimestampPrecision.normalized(base)),
            "Server/microsecond normalization must be identity for µs-aligned values"
        )

        let original = ScriptDocument(
            title: "OCC script",
            body: "baseline",
            updatedAt: base
        )
        let (store, persistence) = try await makeClaimableSQLiteStore(scripts: [original])
        let accountID = UUID()

        let claim = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let claimInput) = claim else {
            return XCTFail("Expected claim prepare")
        }

        // Apply a last-sync baseline at high precision (server-normalized form).
        let syncedAt = CloudTimestampPrecision.normalized(base)
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: original.id,
            lastSyncedUpdatedAt: syncedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(original)
        )
        try await store.applyCloudSyncResult(
            CloudSyncResult(
                baseLibrary: claimInput.library,
                mergedLibrary: claimInput.library,
                summary: CloudSyncSummary(
                    uploadedScripts: 1,
                    downloadedScripts: 0,
                    completedAt: Date(timeIntervalSince1970: 2_000)
                ),
                persistenceUpdate: CloudSyncPersistenceUpdate(
                    accountID: accountID,
                    records: [record],
                    folderRecords: [],
                    tombstones: [],
                    clearedTombstoneIDs: [],
                    folderTombstones: [],
                    clearedFolderTombstoneIDs: [],
                    expectedMutationRevision: claimInput.state.mutationRevision
                )
            )
        )

        let reopened = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let after) = reopened else {
            return XCTFail("Expected prepare after OCC baseline apply")
        }
        let stored = try XCTUnwrap(after.state.currentAccountRecords[original.id]?.lastSyncedUpdatedAt)
        XCTAssertTrue(
            CloudTimestampPrecision.matches(stored, syncedAt),
            "SQLite/Mac boundary must preserve microsecond OCC baseline"
        )
        XCTAssertFalse(
            CloudTimestampPrecision.matches(stored, halfMsLater),
            "Sub-ms newer remote must remain distinguishable from stored baseline"
        )

        let disk = try await persistence.load()
        XCTAssertEqual(
            CloudTimestampPrecision.microseconds(try XCTUnwrap(disk.scripts.first).updatedAt),
            CloudTimestampPrecision.microseconds(base)
        )
    }

    func testSubMillisecondOCCPreventsStaleDeleteAndAllowsMatchingBaseline() async throws {
        let olderMicros: Int64 = 1_700_000_000_500_000
        let newerMicros: Int64 = olderMicros + 750 // 0.75 ms newer
        let older = dateFromMicroseconds(olderMicros)
        let newer = dateFromMicroseconds(newerMicros)
        XCTAssertFalse(CloudTimestampPrecision.matches(older, newer))

        let accountID = UUID()
        let remoteAtNewer = ScriptDocument(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Remote",
            body: "cloud",
            updatedAt: newer
        )
        let repo = InMemoryCloudLibraryRepository(accountID: accountID, scripts: [remoteAtNewer])

        // Stale expected (older by sub-ms) must fail closed — no silent delete.
        do {
            try await repo.deleteScript(
                expected: ScriptDocument(
                    id: remoteAtNewer.id,
                    title: remoteAtNewer.title,
                    body: remoteAtNewer.body,
                    updatedAt: older
                ),
                accountID: accountID
            )
            XCTFail("Stale sub-ms OCC baseline must not delete newer remote")
        } catch {
            XCTAssertEqual(error as? CloudRepositoryError, .newerRemoteEdit)
        }
        let stillPresent = try await repo.fetchScript(id: remoteAtNewer.id, accountID: accountID)
        XCTAssertNotNil(stillPresent)

        // Exact microsecond match (after server normalization) succeeds.
        let normalized = CloudTimestampPrecision.normalized(newer)
        XCTAssertTrue(CloudTimestampPrecision.matches(normalized, newer))
        try await repo.deleteScript(
            expected: ScriptDocument(
                id: remoteAtNewer.id,
                title: remoteAtNewer.title,
                body: remoteAtNewer.body,
                updatedAt: normalized
            ),
            accountID: accountID
        )
        let afterMatchDelete = try await repo.fetchScript(
            id: remoteAtNewer.id,
            accountID: accountID
        )
        XCTAssertNil(afterMatchDelete)
    }

    func testMacApplyDoesNotSpuriouslyFailWhenTimestampsNormalizeEqually() async throws {
        let micros: Int64 = 1_700_000_000_999_001
        let raw = dateFromMicroseconds(micros)
        let normalized = CloudTimestampPrecision.normalized(raw)
        XCTAssertTrue(CloudTimestampPrecision.matches(raw, normalized))

        let original = ScriptDocument(
            title: "Normalize equal",
            body: "body",
            updatedAt: raw
        )
        let (store, _) = try await makeClaimableSQLiteStore(scripts: [original])
        let accountID = UUID()
        let prepared = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let input) = prepared else {
            return XCTFail("Expected ready prepare")
        }

        var remote = original
        remote.updatedAt = normalized
        // Same content fingerprint path; apply must succeed with matching revision.
        try await store.applyCloudSyncResult(
            CloudSyncResult(
                baseLibrary: input.library,
                mergedLibrary: LibrarySnapshot(
                    scripts: [remote],
                    folders: [],
                    settings: input.library.settings,
                    seeded: true
                ),
                summary: CloudSyncSummary(
                    uploadedScripts: 0,
                    downloadedScripts: 1,
                    completedAt: Date(timeIntervalSince1970: 3_000)
                ),
                persistenceUpdate: CloudSyncPersistenceUpdate(
                    accountID: accountID,
                    records: [
                        CloudScriptSyncRecord(
                            accountID: accountID,
                            scriptID: remote.id,
                            lastSyncedUpdatedAt: normalized,
                            lastSyncedFingerprint: CloudScriptFingerprint.make(remote)
                        )
                    ],
                    folderRecords: [],
                    tombstones: [],
                    clearedTombstoneIDs: [],
                    folderTombstones: [],
                    clearedFolderTombstoneIDs: [],
                    expectedMutationRevision: input.state.mutationRevision
                )
            )
        )
        XCTAssertEqual(
            CloudTimestampPrecision.microseconds(try XCTUnwrap(store.script(id: original.id)).updatedAt),
            micros
        )
    }

    // MARK: - User settings last-write / local-store parity

    /// Engine settings use explicit preference resolution (not script-style
    /// three-way merge). At the Mac host boundary, a successful apply installs
    /// the merged settings; a stale mutation revision after a local
    /// `saveSettings` cannot overwrite the newer local preferences.
    func testUserSettingsApplyRemoteWinsAndStaleRemoteCannotOverwriteNewerLocal() async throws {
        let script = ScriptDocument(
            title: "Settings host",
            body: "body",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let (store, persistence) = try await makeClaimableSQLiteStore(scripts: [script])
        let accountID = UUID()

        var localSettings = store.settings
        localSettings.speedWPM = 120
        localSettings.theme = .paper
        let savedLocal = await store.saveSettings(localSettings)
        XCTAssertTrue(savedLocal)

        let prepared = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let input) = prepared else {
            return XCTFail("Expected ready prepare before settings merge")
        }

        // Newer remote settings included in a successful merge apply win on host.
        var remoteSettings = ReaderSettings()
        remoteSettings.speedWPM = 200
        remoteSettings.theme = .contrast
        remoteSettings.normalize()
        try await store.applyCloudSyncResult(
            CloudSyncResult(
                baseLibrary: input.library,
                mergedLibrary: LibrarySnapshot(
                    scripts: input.library.scripts,
                    folders: input.library.folders,
                    settings: remoteSettings,
                    seeded: true
                ),
                summary: CloudSyncSummary(
                    uploadedScripts: 0,
                    downloadedScripts: 0,
                    completedAt: Date(timeIntervalSince1970: 40)
                ),
                persistenceUpdate: CloudSyncPersistenceUpdate(
                    accountID: accountID,
                    records: [],
                    folderRecords: [],
                    tombstones: [],
                    clearedTombstoneIDs: [],
                    folderTombstones: [],
                    clearedFolderTombstoneIDs: [],
                    expectedMutationRevision: input.state.mutationRevision
                )
            )
        )
        XCTAssertEqual(store.settings.speedWPM, 200)
        XCTAssertEqual(store.settings.theme, .contrast)
        let diskAfterRemote = try await persistence.load()
        XCTAssertEqual(diskAfterRemote.settings.speedWPM, 200)

        // Local newer settings after prepare: stale apply must fail closed.
        let preparedAgain = try await store.prepareCloudSync(for: accountID)
        guard case .ready(let input2) = preparedAgain else {
            return XCTFail("Expected second prepare")
        }
        var newerLocal = store.settings
        newerLocal.speedWPM = 165
        newerLocal.theme = .stage
        let savedNewerLocal = await store.saveSettings(newerLocal)
        XCTAssertTrue(savedNewerLocal)
        XCTAssertEqual(store.settings.speedWPM, 165)

        var olderRemote = ReaderSettings()
        olderRemote.speedWPM = 90
        olderRemote.theme = .sepia
        olderRemote.normalize()
        do {
            try await store.applyCloudSyncResult(
                CloudSyncResult(
                    baseLibrary: input2.library,
                    mergedLibrary: LibrarySnapshot(
                        scripts: input2.library.scripts,
                        folders: input2.library.folders,
                        settings: olderRemote,
                        seeded: true
                    ),
                    summary: CloudSyncSummary(
                        uploadedScripts: 0,
                        downloadedScripts: 0,
                        completedAt: Date(timeIntervalSince1970: 50)
                    ),
                    persistenceUpdate: CloudSyncPersistenceUpdate(
                        accountID: accountID,
                        records: [],
                        folderRecords: [],
                        tombstones: [],
                        clearedTombstoneIDs: [],
                        folderTombstones: [],
                        clearedFolderTombstoneIDs: [],
                        expectedMutationRevision: input2.state.mutationRevision
                    )
                )
            )
            XCTFail("Stale generation must not install older remote settings")
        } catch {
            XCTAssertEqual(error as? CloudSyncApplicationError, .localLibraryChanged)
        }
        XCTAssertEqual(store.settings.speedWPM, 165)
        XCTAssertEqual(store.settings.theme, .stage)
        let diskFinal = try await persistence.load()
        XCTAssertEqual(diskFinal.settings.speedWPM, 165)
        XCTAssertEqual(diskFinal.settings.theme, .stage)
    }

    func testConflictCopySaveFailureReportsRetryAndKeepsVisibleCopy() async throws {
        let original = ScriptDocument(
            title: "Shared",
            body: "Base",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let base = LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: .init(),
            seeded: true
        )
        var cloud = original
        cloud.body = "Cloud edit"
        cloud.updatedAt = Date(timeIntervalSince1970: 200)
        let persistence = ControllableMacLibraryPersistence(snapshot: base)
        let store = MacLibraryStore(persistence: persistence)
        await store.load()
        await persistence.blockNext(.applyCloudSync)
        await persistence.failNext(.upsertCloudConflict)
        let result = CloudSyncResult(
            baseLibrary: base,
            mergedLibrary: LibrarySnapshot(
                scripts: [cloud],
                folders: [],
                settings: .init(),
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
            try await store.applyCloudSyncResult(result)
        }
        await persistence.waitUntilBlocked(.applyCloudSync)
        var local = original
        local.body = "Local edit during commit"
        XCTAssertTrue(store.stageEditorDraft(
            local,
            changedAt: Date(timeIntervalSince1970: 300),
            editorOriginID: UUID()
        ))
        await persistence.resumeBlockedOperation()

        do {
            try await applyTask.value
            XCTFail("Non-durable protected copy must not report success")
        } catch {
            XCTAssertEqual(error as? CloudSyncApplicationError, .localConflictCopyNeedsSaving)
            XCTAssertEqual(
                store.errorMessage,
                CloudSyncApplicationError.localConflictCopyNeedsSaving.errorDescription
            )
        }

        let visible = store.exportSnapshot()
        XCTAssertEqual(visible.scripts.first(where: { $0.id == original.id }), cloud)
        XCTAssertEqual(
            visible.scripts.first(where: { $0.id != original.id })?.body,
            local.body
        )
        let persisted = try await persistence.load()
        XCTAssertEqual(persisted.scripts, [cloud])
    }

    // MARK: - Helpers

    /// Upsert path: rows remain claimable by the first real account on prepare.
    private func makeClaimableSQLiteStore(
        scripts: [ScriptDocument],
        folders: [ScriptFolder] = []
    ) async throws -> (MacLibraryStore, any LibraryPersistence) {
        let dbURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite3")
        let persistence = LibraryPersistenceFactory.makeShipping(fileURL: dbURL)
        try await persistence.replace(
            with: LibrarySnapshot(
                scripts: [],
                folders: [],
                settings: .init(),
                seeded: true
            )
        )
        if !folders.isEmpty {
            try await persistence.saveFolders(folders)
        }
        for script in scripts {
            try await persistence.upsert(script)
        }
        let store = MacLibraryStore(persistence: persistence)
        await store.load()
        XCTAssertTrue(store.isLoaded)
        return (store, persistence)
    }

    /// Bulk replace path: unowned rows are quarantined (backup restore parity).
    private func makeSQLiteStore(
        scripts: [ScriptDocument],
        folders: [ScriptFolder] = [],
        quarantineViaReplace: Bool = true
    ) async throws -> (MacLibraryStore, any LibraryPersistence) {
        let dbURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite3")
        let persistence = LibraryPersistenceFactory.makeShipping(fileURL: dbURL)
        if quarantineViaReplace {
            try await persistence.replace(
                with: LibrarySnapshot(
                    scripts: scripts,
                    folders: folders,
                    settings: .init(),
                    seeded: true
                )
            )
        } else {
            return try await makeClaimableSQLiteStore(scripts: scripts, folders: folders)
        }
        let store = MacLibraryStore(persistence: persistence)
        await store.load()
        XCTAssertTrue(store.isLoaded)
        return (store, persistence)
    }

    private func dateFromMicroseconds(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    private func openSQLite(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(
                domain: "MacCloudSyncHostTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "failed to open \(url.lastPathComponent)"]
            )
        }
        return database
    }

    private func executeSQL(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "sqlite error \(status)"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "MacCloudSyncHostTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

// MARK: - Controllable persistence double

private actor ControllableMacLibraryPersistence: LibraryPersistence {
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
