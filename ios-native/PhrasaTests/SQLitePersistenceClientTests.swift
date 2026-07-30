import SQLite3
import XCTest
@testable import Phrasa

final class SQLitePersistenceClientTests: XCTestCase {
    func testJSONScriptFingerprintRoundTripsAndLegacyUpdateCannotEraseIt() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-script-fingerprint-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = UUID()
        let script = ScriptDocument(title: "Durable script baseline")
        let fingerprint = CloudScriptFingerprint.make(script)
        let store = PersistenceClient(fileURL: url)
        try await store.replace(with: .empty)
        try await store.upsert(script)
        let prepared = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: []
        )
        try await store.applyCloudSync(
            snapshot: LibrarySnapshot(
                scripts: [script],
                folders: [],
                settings: .init(),
                seeded: true
            ),
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [CloudScriptSyncRecord(
                    accountID: accountID,
                    scriptID: script.id,
                    lastSyncedUpdatedAt: script.updatedAt,
                    lastSyncedFingerprint: fingerprint
                )],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: prepared.mutationRevision
            )
        )

        let reopened = PersistenceClient(fileURL: url)
        let loadedState = try await reopened.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: []
        )
        XCTAssertEqual(
            loadedState.currentAccountRecords[script.id]?.lastSyncedFingerprint,
            fingerprint
        )
        try await reopened.applyCloudSync(
            snapshot: try await reopened.load(),
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [CloudScriptSyncRecord(
                    accountID: accountID,
                    scriptID: script.id,
                    lastSyncedUpdatedAt: nil
                )],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: loadedState.mutationRevision
            )
        )
        let preservedState = try await PersistenceClient(fileURL: url).prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: []
        )
        XCTAssertEqual(
            preservedState.currentAccountRecords[script.id]?.lastSyncedFingerprint,
            fingerprint
        )
    }

    func testSQLiteAddsAndPersistsScriptFingerprintForLegacySyncTable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-script-fingerprint-upgrade-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let accountID = UUID()
        let scriptID = UUID()
        let legacyDatabase = try openDatabase(at: url)
        try execute(legacyDatabase, """
            CREATE TABLE cloud_script_sync_state(
                account_id TEXT NOT NULL,
                script_id TEXT NOT NULL,
                last_synced_updated REAL,
                PRIMARY KEY(account_id, script_id)
            )
            """)
        try execute(legacyDatabase, """
            INSERT INTO cloud_script_sync_state(account_id,script_id,last_synced_updated)
            VALUES('\(accountID.uuidString)','\(scriptID.uuidString)',10)
            """)
        sqlite3_close(legacyDatabase)

        let upgraded = SQLitePersistenceClient(fileURL: url)
        _ = try await upgraded.load()
        let legacyState = try await upgraded.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: []
        )
        XCTAssertNil(
            legacyState.currentAccountRecords[scriptID]?.lastSyncedFingerprint
        )

        let fingerprint = "content-fingerprint-v1"
        try await upgraded.applyCloudSync(
            snapshot: .empty,
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [CloudScriptSyncRecord(
                    accountID: accountID,
                    scriptID: scriptID,
                    lastSyncedUpdatedAt: Date(timeIntervalSince1970: 20),
                    lastSyncedFingerprint: fingerprint
                )],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: legacyState.mutationRevision
            )
        )

        let reopened = SQLitePersistenceClient(fileURL: url)
        let persistedState = try await reopened.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: []
        )
        XCTAssertEqual(
            persistedState.currentAccountRecords[scriptID]?.lastSyncedFingerprint,
            fingerprint
        )
    }

    func testJSONFolderBaselineRoundTripsWithoutLosingTimestampPrecision() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-folder-baseline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = UUID()
        let folder = ScriptFolder(
            name: "Exact cloud baseline",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123_456)
        )
        let legacyFolder = ScriptFolder(name: "Legacy baseline-free record")
        let store = PersistenceClient(fileURL: url)
        try await store.replace(with: .empty)
        try await store.saveFolders([folder, legacyFolder])
        let prepared = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: [folder.id, legacyFolder.id]
        )
        try await store.applyCloudSync(
            snapshot: LibrarySnapshot(
                scripts: [],
                folders: [folder, legacyFolder],
                settings: .init(),
                seeded: true
            ),
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [],
                folderRecords: [
                    CloudFolderSyncRecord(
                        accountID: accountID,
                        folderID: folder.id,
                        hasSynced: true,
                        lastSyncedName: folder.name,
                        lastSyncedCreatedAt: folder.createdAt
                    ),
                    // This is the exact shape older JSON envelopes decode to.
                    CloudFolderSyncRecord(
                        accountID: accountID,
                        folderID: legacyFolder.id,
                        hasSynced: true
                    )
                ],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: prepared.mutationRevision
            )
        )

        let reopened = PersistenceClient(fileURL: url)
        let loaded = try await reopened.load()
        let state = try await reopened.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: [folder.id, legacyFolder.id]
        )
        let baseline = try XCTUnwrap(
            state.currentAccountFolderRecords[folder.id]?.lastSyncedFolder
        )
        XCTAssertEqual(baseline.name, folder.name)
        XCTAssertEqual(
            baseline.createdAt.timeIntervalSince1970,
            folder.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        let loadedFolder = try XCTUnwrap(
            loaded.folders.first(where: { $0.id == folder.id })
        )
        XCTAssertEqual(
            loadedFolder.createdAt.timeIntervalSince1970,
            folder.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertNil(
            state.currentAccountFolderRecords[legacyFolder.id]?.lastSyncedFolder
        )
    }

    func testSQLiteAddsFolderBaselineColumnsToLegacySyncTable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-folder-baseline-upgrade-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let accountID = UUID()
        let folderID = UUID()
        let legacyDatabase = try openDatabase(at: url)
        try execute(legacyDatabase, """
            CREATE TABLE cloud_folder_sync_state(
                account_id TEXT NOT NULL,
                folder_id TEXT NOT NULL,
                has_synced INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(account_id, folder_id)
            )
            """)
        try execute(legacyDatabase, """
            INSERT INTO cloud_folder_sync_state(account_id,folder_id,has_synced)
            VALUES('\(accountID.uuidString)','\(folderID.uuidString)',1)
            """)
        sqlite3_close(legacyDatabase)

        let upgraded = SQLitePersistenceClient(fileURL: url)
        _ = try await upgraded.load()
        let state = try await upgraded.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: []
        )
        let legacyRecord = try XCTUnwrap(state.currentAccountFolderRecords[folderID])
        XCTAssertTrue(legacyRecord.hasSynced)
        XCTAssertNil(legacyRecord.lastSyncedFolder)
    }

    func testSQLiteFolderBaselineRoundTripsAndUpdatesAtomically() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-folder-baseline-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let accountID = UUID()
        let folder = ScriptFolder(
            name: "First remote name",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.654_321)
        )
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: .empty)
        try await store.saveFolders([folder])
        let prepared = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: [folder.id]
        )
        try await store.applyCloudSync(
            snapshot: LibrarySnapshot(
                scripts: [],
                folders: [folder],
                settings: .init(),
                seeded: true
            ),
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [],
                folderRecords: [CloudFolderSyncRecord(
                    accountID: accountID,
                    folderID: folder.id,
                    hasSynced: true,
                    lastSyncedName: folder.name,
                    lastSyncedCreatedAt: folder.createdAt
                )],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: prepared.mutationRevision
            )
        )
        let renamed = ScriptFolder(
            id: folder.id,
            name: "New remote name",
            createdAt: folder.createdAt
        )
        let renamedState = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: [folder.id]
        )
        try await store.applyCloudSync(
            snapshot: LibrarySnapshot(
                scripts: [],
                folders: [renamed],
                settings: .init(),
                seeded: true
            ),
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [],
                folderRecords: [CloudFolderSyncRecord(
                    accountID: accountID,
                    folderID: renamed.id,
                    hasSynced: true,
                    lastSyncedName: renamed.name,
                    lastSyncedCreatedAt: renamed.createdAt
                )],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: renamedState.mutationRevision
            )
        )

        let reopened = SQLitePersistenceClient(fileURL: url)
        let state = try await reopened.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: [folder.id]
        )
        let baseline = try XCTUnwrap(
            state.currentAccountFolderRecords[folder.id]?.lastSyncedFolder
        )
        XCTAssertEqual(baseline.name, renamed.name)
        XCTAssertEqual(
            baseline.createdAt.timeIntervalSince1970,
            folder.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testJSONCloudApplyRejectsAnInterveningLocalMutation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-json-sync-revision-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = UUID()
        let original = ScriptDocument(
            title: "Original",
            body: "Sync started here",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let store = PersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: .init(),
            seeded: true
        ))
        let prepared = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [original.id],
            localFolderIDs: []
        )
        var localEdit = original
        localEdit.body = "Newer local edit"
        localEdit.updatedAt = Date(timeIntervalSince1970: 200)
        try await store.upsert(localEdit)

        do {
            try await store.applyCloudSync(
                snapshot: LibrarySnapshot(
                    scripts: [original],
                    folders: [],
                    settings: .init(),
                    seeded: true
                ),
                update: emptyPersistenceUpdate(
                    accountID: accountID,
                    expectedMutationRevision: prepared.mutationRevision
                )
            )
            XCTFail("A stale cloud merge must not replace a newer JSON write")
        } catch {
            XCTAssertTrue(error is CloudSyncApplicationError)
        }

        let reloaded = try await store.load()
        let reloadedScript = try XCTUnwrap(reloaded.scripts.first)
        XCTAssertEqual(reloadedScript.id, localEdit.id)
        XCTAssertEqual(reloadedScript.body, localEdit.body)
        XCTAssertEqual(
            reloadedScript.updatedAt.timeIntervalSince1970,
            localEdit.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testSQLiteCloudApplyRejectsAnInterveningLocalMutation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-sqlite-sync-revision-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let accountID = UUID()
        let original = ScriptDocument(
            title: "Original",
            body: "Sync started here",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: .init(),
            seeded: true
        ))
        let prepared = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [original.id],
            localFolderIDs: []
        )
        var localEdit = original
        localEdit.body = "Newer local edit"
        localEdit.updatedAt = Date(timeIntervalSince1970: 200)
        try await store.upsert(localEdit)

        do {
            try await store.applyCloudSync(
                snapshot: LibrarySnapshot(
                    scripts: [original],
                    folders: [],
                    settings: .init(),
                    seeded: true
                ),
                update: emptyPersistenceUpdate(
                    accountID: accountID,
                    expectedMutationRevision: prepared.mutationRevision
                )
            )
            XCTFail("A stale cloud merge must not replace a newer SQLite write")
        } catch {
            XCTAssertTrue(error is CloudSyncApplicationError)
        }

        let reloaded = try await store.load()
        let persisted = try XCTUnwrap(reloaded.scripts.first)
        XCTAssertEqual(persisted.id, localEdit.id)
        XCTAssertEqual(persisted.title, localEdit.title)
        XCTAssertEqual(persisted.body, localEdit.body)
        XCTAssertEqual(persisted.source, localEdit.source)
        XCTAssertEqual(persisted.folderID, localEdit.folderID)
        XCTAssertEqual(persisted.tags, localEdit.tags)
        XCTAssertEqual(persisted.outline, localEdit.outline)
        XCTAssertEqual(persisted.lastOpenedAt, localEdit.lastOpenedAt)
        XCTAssertEqual(
            persisted.createdAt.timeIntervalSince1970,
            localEdit.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            persisted.updatedAt.timeIntervalSince1970,
            localEdit.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testSQLiteSaveSettingsRollsBackWhenSeededWriteFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-settings-atomic-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        var originalSettings = ReaderSettings()
        originalSettings.speedWPM = 140
        try await store.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: originalSettings,
            seeded: true
        ))
        let database = try openDatabase(at: url)
        try execute(database, """
            CREATE TRIGGER fail_seeded_update
            BEFORE UPDATE OF value ON metadata
            WHEN OLD.key = 'seeded'
            BEGIN
              SELECT RAISE(ABORT, 'forced seeded write failure');
            END
            """)
        sqlite3_close(database)
        var changedSettings = originalSettings
        changedSettings.speedWPM = 220

        do {
            try await store.saveSettings(changedSettings, seeded: false)
            XCTFail("The injected seeded write failure should abort both settings writes")
        } catch {
            // Expected: the transaction must roll back the earlier settings row.
        }

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.settings.speedWPM, originalSettings.speedWPM)
        XCTAssertTrue(reloaded.seeded)
    }

    func testSnapshotOnlyJSONQuarantinesExistingRowsButAllowsNewRowsAfterRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-legacy-json-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacyScript = ScriptDocument(title: "Existing account A script")
        let legacyFolder = ScriptFolder(name: "Existing account A folder")
        let original = LibrarySnapshot(
            scripts: [legacyScript],
            folders: [legacyFolder],
            settings: ReaderSettings(),
            seeded: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original).write(to: url, options: .atomic)

        // Loading the old snapshot-only format upgrades it to the provenance
        // envelope and persists a quarantine owner before returning.
        let upgradingStore = PersistenceClient(fileURL: url)
        _ = try await upgradingStore.load()

        let newScript = ScriptDocument(title: "Created after the upgrade")
        let newFolder = ScriptFolder(name: "Created after the upgrade")
        try await upgradingStore.upsert(newScript)
        try await upgradingStore.saveFolders([legacyFolder, newFolder])

        // Reopen to prove both the quarantine and the post-upgrade distinction
        // are durable rather than properties of one actor instance.
        let reopened = PersistenceClient(fileURL: url)
        let accountB = UUID()
        let state = try await reopened.prepareCloudSync(
            accountID: accountB,
            localScriptIDs: [legacyScript.id, newScript.id],
            localFolderIDs: [legacyFolder.id, newFolder.id]
        )

        XCTAssertNil(state.currentAccountRecords[legacyScript.id])
        XCTAssertTrue(state.scriptIDsOwnedByOtherAccounts.contains(legacyScript.id))
        XCTAssertEqual(state.currentAccountRecords[newScript.id]?.accountID, accountB)
        XCTAssertNil(state.currentAccountFolderRecords[legacyFolder.id])
        XCTAssertTrue(state.folderIDsOwnedByOtherAccounts.contains(legacyFolder.id))
        XCTAssertEqual(state.currentAccountFolderRecords[newFolder.id]?.accountID, accountB)
    }

    func testSQLiteOwnershipMigrationQuarantinesOldRowsAndLeavesNewRowsClaimable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-ownership-upgrade-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let oldScript = ScriptDocument(title: "Downloaded for account A")
        let oldFolder = ScriptFolder(name: "Account A private folder")

        let fixtureStore = SQLitePersistenceClient(fileURL: url)
        try await fixtureStore.replace(with: LibrarySnapshot(
            scripts: [oldScript],
            folders: [oldFolder],
            settings: ReaderSettings(),
            seeded: true
        ))
        let fixtureDatabase = try openDatabase(at: url)
        try execute(fixtureDatabase, "DELETE FROM cloud_script_sync_state")
        try execute(fixtureDatabase, "DELETE FROM cloud_folder_sync_state")
        try execute(
            fixtureDatabase,
            "DELETE FROM metadata WHERE key = 'cloud_ownership_schema'"
        )
        sqlite3_close(fixtureDatabase)

        let upgraded = SQLitePersistenceClient(fileURL: url)
        _ = try await upgraded.load()
        let newScript = ScriptDocument(title: "New after provenance upgrade")
        let newFolder = ScriptFolder(name: "New after provenance upgrade")
        try await upgraded.upsert(newScript)
        try await upgraded.saveFolders([oldFolder, newFolder])

        let reopened = SQLitePersistenceClient(fileURL: url)
        let accountB = UUID()
        let state = try await reopened.prepareCloudSync(
            accountID: accountB,
            localScriptIDs: [oldScript.id, newScript.id],
            localFolderIDs: [oldFolder.id, newFolder.id]
        )

        XCTAssertNil(state.currentAccountRecords[oldScript.id])
        XCTAssertTrue(state.scriptIDsOwnedByOtherAccounts.contains(oldScript.id))
        XCTAssertEqual(state.currentAccountRecords[newScript.id]?.accountID, accountB)
        XCTAssertNil(state.currentAccountFolderRecords[oldFolder.id])
        XCTAssertTrue(state.folderIDsOwnedByOtherAccounts.contains(oldFolder.id))
        XCTAssertEqual(state.currentAccountFolderRecords[newFolder.id]?.accountID, accountB)
    }

    func testBulkReplaceQuarantinesUnownedSQLiteContent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-bulk-restore-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let importedScript = ScriptDocument(title: "Restored from a backup")
        let importedFolder = ScriptFolder(name: "Restored private folder")
        let store = SQLitePersistenceClient(fileURL: url)

        try await store.replace(with: LibrarySnapshot(
            scripts: [importedScript],
            folders: [importedFolder],
            settings: ReaderSettings(),
            seeded: true
        ))
        let state = try await store.prepareCloudSync(
            accountID: UUID(),
            localScriptIDs: [importedScript.id],
            localFolderIDs: [importedFolder.id]
        )

        XCTAssertTrue(state.scriptIDsOwnedByOtherAccounts.contains(importedScript.id))
        XCTAssertTrue(state.folderIDsOwnedByOtherAccounts.contains(importedFolder.id))
        XCTAssertTrue(state.currentAccountRecords.isEmpty)
        XCTAssertTrue(state.currentAccountFolderRecords.isEmpty)
    }

    func testInitializationFailureDoesNotPoisonARepairAndRetry() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-schema-retry-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let malformedDatabase = try openDatabase(at: url)
        try execute(malformedDatabase, """
            CREATE TABLE cloud_folder_sync_state(
                account_id TEXT NOT NULL,
                has_synced INTEGER NOT NULL DEFAULT 0
            )
            """)
        sqlite3_close(malformedDatabase)
        let store = SQLitePersistenceClient(fileURL: url)

        do {
            _ = try await store.load()
            XCTFail("Malformed schema should fail initialization")
        } catch {
            XCTAssertNotNil(error as? SQLitePersistenceClient.DatabaseError)
        }

        let repairedDatabase = try openDatabase(at: url)
        try execute(repairedDatabase, "DROP TABLE cloud_folder_sync_state")
        sqlite3_close(repairedDatabase)

        _ = try await store.load()
        let accountID = UUID()
        let state = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: []
        )
        XCTAssertEqual(state.accountID, accountID)
    }

    @MainActor
    func testConfirmedFreshStartPreservesRawCorruptDatabaseBeforeReset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-recovery-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("library.sqlite3")
        let legacyURL = directory.appendingPathComponent("missing-expo.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptData = Data("this is not a SQLite database".utf8)
        try corruptData.write(to: url)
        let persistence = SQLitePersistenceClient(fileURL: url)
        let library = LibraryStore(
            persistence: persistence,
            legacyMigrator: LegacyExpoMigrator(databaseURL: legacyURL)
        )

        await library.load()

        XCTAssertFalse(library.isLoaded)
        XCTAssertTrue(library.canStartFreshAfterCorruption)
        XCTAssertEqual(try Data(contentsOf: url), corruptData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Recovery").path
            )
        )

        let didReset = await library.startFreshAfterCorruption()

        XCTAssertTrue(didReset)
        XCTAssertTrue(library.isLoaded)
        XCTAssertEqual(library.scripts.map(\.title), ["Welcome to Phrasa"])
        let recoveryRoot = directory.appendingPathComponent("Recovery", isDirectory: true)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        )
        let recoveryDirectory = try XCTUnwrap(recoveryDirectories.first)
        let preservedURL = recoveryDirectory.appendingPathComponent(url.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: preservedURL), corruptData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecoveryClassificationExcludesOperationalAndFutureSchemaErrors() {
        let store = SQLitePersistenceClient()

        XCTAssertTrue(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.read("corrupt")))
        XCTAssertTrue(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.read("database disk image is malformed")))
        XCTAssertTrue(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.invalidData("bad row")))
        XCTAssertTrue(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.execute("file is not a database")))
        XCTAssertFalse(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.read("database is locked")))
        XCTAssertFalse(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.read("disk I/O error")))
        XCTAssertFalse(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.read("out of memory")))
        XCTAssertFalse(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.execute("database or disk is full")))
        XCTAssertFalse(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.open("permission denied")))
        XCTAssertFalse(store.canRecoverLibrary(after: SQLitePersistenceClient.DatabaseError.unsupportedSchema("schema 2")))
    }

    @MainActor
    func testFutureOwnershipSchemaDoesNotOfferDestructiveRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-future-schema-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("library.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try openDatabase(at: url)
        try execute(database, "CREATE TABLE metadata(key TEXT PRIMARY KEY NOT NULL,value BLOB NOT NULL)")
        try execute(database, "INSERT INTO metadata(key,value) VALUES('cloud_ownership_schema','2')")
        sqlite3_close(database)
        let library = LibraryStore(persistence: SQLitePersistenceClient(fileURL: url))

        await library.load()

        XCTAssertFalse(library.isLoaded)
        XCTAssertFalse(library.canStartFreshAfterCorruption)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecoveryMoveFailureRollsEveryMovedFileBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-recovery-rollback-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("library.sqlite3")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseData = Data("damaged main".utf8)
        let walData = Data("damaged wal".utf8)
        try databaseData.write(to: url)
        try walData.write(to: walURL)
        let mover = FailingSecondRecoveryMove()
        let store = SQLitePersistenceClient(
            fileURL: url,
            recoveryMoveItem: { source, destination in
                try mover.moveItem(at: source, to: destination)
            }
        )

        do {
            _ = try await store.preserveCorruptLibraryAndReset()
            XCTFail("The injected second move must abort recovery")
        } catch {
            XCTAssertNotNil(error as? SQLitePersistenceClient.LibraryRecoveryError)
        }

        XCTAssertEqual(try Data(contentsOf: url), databaseData)
        XCTAssertEqual(try Data(contentsOf: walURL), walData)
    }

    func testScriptReadThrowsWhenSQLiteStepFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-step-error-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [ScriptDocument(title: "Valid first row", body: "Keep me")],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        ))

        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE script_rows AS SELECT 1 AS ordinal, * FROM scripts")
        try execute(database, "INSERT INTO script_rows SELECT 2 AS ordinal, * FROM scripts")
        try execute(database, "DROP TABLE scripts")
        try execute(database, """
            CREATE VIEW scripts AS
            SELECT id, title,
                CASE WHEN ordinal = 2
                    THEN abs(CAST('-9223372036854775808' AS INTEGER))
                    ELSE body
                END AS body,
                source, folder_id, tags, outline, last_opened, created, updated
            FROM script_rows
            """)

        do {
            _ = try await store.load()
            XCTFail("A failed SQLite step must not return a partial library")
        } catch {
            guard let databaseError = error as? SQLitePersistenceClient.DatabaseError,
                  case .read = databaseError else {
                return XCTFail("Expected a read error, got \(error)")
            }
        }
    }

    func testMetadataReadRequiresDoneAfterItsRow() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-meta-step-error-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        ))

        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE metadata_rows AS SELECT 1 AS ordinal, * FROM metadata")
        try execute(database, "INSERT INTO metadata_rows SELECT 2 AS ordinal, key, value FROM metadata WHERE key = 'settings'")
        try execute(database, "DROP TABLE metadata")
        try execute(database, """
            CREATE VIEW metadata AS
            SELECT key,
                CASE WHEN ordinal = 2
                    THEN abs(CAST('-9223372036854775808' AS INTEGER))
                    ELSE value
                END AS value
            FROM metadata_rows
            """)

        do {
            _ = try await store.load()
            XCTFail("Metadata must reach SQLITE_DONE after the matching row")
        } catch {
            guard let databaseError = error as? SQLitePersistenceClient.DatabaseError,
                  case .read = databaseError else {
                return XCTFail("Expected a read error, got \(error)")
            }
        }
    }

    @MainActor
    func testLibraryStoreFolderAssignmentAndDeletionStayPersisted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-store-\(UUID().uuidString).sqlite3")
        let persistence = SQLitePersistenceClient(fileURL: url)
        try await persistence.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        ))
        let library = LibraryStore(persistence: persistence)
        await library.load()

        let createdFolder = await library.createFolder(name: "Keynotes")
        let folder = try XCTUnwrap(createdFolder)
        let createdScript = await library.createScript(title: "Annual talk", folderID: folder.id)
        let script = try XCTUnwrap(createdScript)
        XCTAssertEqual(library.script(id: script.id)?.folderID, folder.id)

        let accountID = UUID()
        let syncState = try await persistence.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: [folder.id]
        )
        try await persistence.applyCloudSync(
            snapshot: library.exportSnapshot(),
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [],
                folderRecords: [CloudFolderSyncRecord(
                    accountID: accountID,
                    folderID: folder.id,
                    hasSynced: true,
                    lastSyncedName: folder.name,
                    lastSyncedCreatedAt: folder.createdAt
                )],
                tombstones: [],
                clearedTombstoneIDs: [],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: syncState.mutationRevision
            )
        )

        let moved = await library.moveScript(script.id, to: nil)
        XCTAssertTrue(moved)
        XCTAssertNil(library.script(id: script.id)?.folderID)

        _ = await library.moveScript(script.id, to: folder.id)
        await library.deleteFolder(folder.id)
        XCTAssertNil(library.script(id: script.id)?.folderID)
        XCTAssertTrue(library.folders.isEmpty)

        let reopened = SQLitePersistenceClient(fileURL: url)
        let reloaded = try await reopened.load()
        XCTAssertNil(reloaded.scripts.first(where: { $0.id == script.id })?.folderID)
        XCTAssertTrue(reloaded.folders.isEmpty)
        let deletionState = try await reopened.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: []
        )
        XCTAssertNotNil(deletionState.tombstonesByFolderID[folder.id])
        XCTAssertEqual(
            deletionState.currentAccountFolderRecords[folder.id]?.hasSynced,
            true
        )
    }

    func testRoundTripAndSingleScriptMutation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-db-\(UUID().uuidString).sqlite3")
        let store = SQLitePersistenceClient(fileURL: url)
        let first = ScriptDocument(title: "First", body: "one two three")
        let second = ScriptDocument(title: "Second", body: "four five")
        let folder = ScriptFolder(name: "Stage")
        var settings = ReaderSettings()
        settings.speedWPM = 172

        try await store.replace(with: LibrarySnapshot(
            scripts: [first, second],
            folders: [folder],
            settings: settings,
            seeded: true
        ))

        var loaded = try await store.load()
        XCTAssertEqual(Set(loaded.scripts.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(loaded.folders.map(\.id), [folder.id])
        XCTAssertEqual(loaded.folders.map(\.name), [folder.name])
        XCTAssertEqual(loaded.folders[0].createdAt.timeIntervalSince1970, folder.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.settings.speedWPM, 172)
        XCTAssertTrue(loaded.seeded)

        var edited = first
        edited.body = "changed without rewriting the other document"
        try await store.upsert(edited)
        try await store.deleteScript(id: second.id)
        loaded = try await store.load()
        XCTAssertEqual(loaded.scripts.count, 1)
        let persisted = try XCTUnwrap(loaded.scripts.first)
        XCTAssertEqual(persisted.id, edited.id)
        XCTAssertEqual(persisted.title, edited.title)
        XCTAssertEqual(persisted.body, edited.body)
        XCTAssertEqual(persisted.source, edited.source)
        XCTAssertEqual(persisted.folderID, edited.folderID)
        XCTAssertEqual(persisted.tags, edited.tags)
        XCTAssertEqual(persisted.outline, edited.outline)
        XCTAssertEqual(persisted.createdAt.timeIntervalSince1970, edited.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(persisted.updatedAt.timeIntervalSince1970, edited.updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSettingsAndFoldersSaveIndependently() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-db-\(UUID().uuidString).sqlite3")
        let store = SQLitePersistenceClient(fileURL: url)
        var settings = ReaderSettings()
        settings.theme = .sepia
        let folders = [ScriptFolder(name: "Keynotes"), ScriptFolder(name: "Videos")]

        try await store.saveSettings(settings, seeded: true)
        try await store.saveFolders(folders)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.settings.theme, .sepia)
        XCTAssertEqual(Set(loaded.folders.map(\.id)), Set(folders.map(\.id)))
        XCTAssertTrue(loaded.seeded)
    }

    func testCloudOwnershipIsDurableAndCannotMoveBetweenAccounts() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-sync-ownership-\(UUID().uuidString).sqlite3")
        let accountA = UUID()
        let accountB = UUID()
        let script = ScriptDocument(title: "Account A script")
        let folder = ScriptFolder(name: "Account A private project")
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        ))
        try await store.upsert(script)
        try await store.saveFolders([folder])

        let stateA = try await store.prepareCloudSync(
            accountID: accountA,
            localScriptIDs: [script.id],
            localFolderIDs: [folder.id]
        )
        XCTAssertEqual(stateA.currentAccountRecords[script.id]?.accountID, accountA)
        XCTAssertNil(stateA.currentAccountRecords[script.id]?.lastSyncedUpdatedAt)
        XCTAssertEqual(stateA.currentAccountFolderRecords[folder.id]?.accountID, accountA)
        XCTAssertEqual(stateA.currentAccountFolderRecords[folder.id]?.hasSynced, false)

        // Reopen the database to prove the claim is persisted rather than
        // living only in the current process or auth session.
        let reopened = SQLitePersistenceClient(fileURL: url)
        let stateB = try await reopened.prepareCloudSync(
            accountID: accountB,
            localScriptIDs: [script.id],
            localFolderIDs: [folder.id]
        )
        XCTAssertNil(stateB.currentAccountRecords[script.id])
        XCTAssertTrue(stateB.scriptIDsOwnedByOtherAccounts.contains(script.id))
        XCTAssertNil(stateB.currentAccountFolderRecords[folder.id])
        XCTAssertTrue(stateB.folderIDsOwnedByOtherAccounts.contains(folder.id))
    }

    func testCloudConflictCopyIsAtomicallyOwnedByTheOriginatingAccount() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-conflict-owner-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let accountA = UUID()
        let accountB = UUID()
        let conflict = ScriptDocument(title: "Private local conflict")
        let store = SQLitePersistenceClient(fileURL: url)

        try await store.upsertCloudConflict(conflict, accountID: accountA)

        let stateA = try await store.prepareCloudSync(
            accountID: accountA,
            localScriptIDs: [conflict.id],
            localFolderIDs: []
        )
        XCTAssertEqual(stateA.currentAccountRecords[conflict.id]?.accountID, accountA)

        let reopened = SQLitePersistenceClient(fileURL: url)
        let stateB = try await reopened.prepareCloudSync(
            accountID: accountB,
            localScriptIDs: [conflict.id],
            localFolderIDs: []
        )
        XCTAssertNil(stateB.currentAccountRecords[conflict.id])
        XCTAssertTrue(stateB.scriptIDsOwnedByOtherAccounts.contains(conflict.id))
    }

    func testCloudConflictCannotOverwriteADifferentAccountsDocument() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-conflict-foreign-owner-\(UUID().uuidString).sqlite3")
        defer { removeSQLiteFiles(at: url) }
        let accountA = UUID()
        let accountB = UUID()
        let original = ScriptDocument(
            title: "Account A protected copy",
            body: "Private A content"
        )
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.upsertCloudConflict(original, accountID: accountA)
        var attemptedOverwrite = original
        attemptedOverwrite.title = "Account B overwrite"
        attemptedOverwrite.body = "Private B content"

        do {
            try await store.upsertCloudConflict(attemptedOverwrite, accountID: accountB)
            XCTFail("A different account must not overwrite an owned local document")
        } catch {
            XCTAssertNotNil(error as? SQLitePersistenceClient.DatabaseError)
        }

        let reopened = SQLitePersistenceClient(fileURL: url)
        let persisted = try await reopened.load()
        let persistedOriginal = try XCTUnwrap(
            persisted.scripts.first(where: { $0.id == original.id })
        )
        XCTAssertEqual(persistedOriginal.title, original.title)
        XCTAssertEqual(persistedOriginal.body, original.body)
        XCTAssertEqual(persistedOriginal.source, original.source)
        XCTAssertEqual(persistedOriginal.folderID, original.folderID)
        XCTAssertEqual(persistedOriginal.tags, original.tags)
        XCTAssertEqual(persistedOriginal.outline, original.outline)
        XCTAssertEqual(
            persistedOriginal.createdAt.timeIntervalSince1970,
            original.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            persistedOriginal.updatedAt.timeIntervalSince1970,
            original.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        let stateA = try await reopened.prepareCloudSync(
            accountID: accountA,
            localScriptIDs: [original.id],
            localFolderIDs: []
        )
        XCTAssertEqual(stateA.currentAccountRecords[original.id]?.accountID, accountA)
        let stateB = try await reopened.prepareCloudSync(
            accountID: accountB,
            localScriptIDs: [original.id],
            localFolderIDs: []
        )
        XCTAssertNil(stateB.currentAccountRecords[original.id])
        XCTAssertTrue(stateB.scriptIDsOwnedByOtherAccounts.contains(original.id))
    }

    func testScriptDeletionTombstoneSurvivesRelaunchAndCloudApplyIsAtomic() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-sync-delete-\(UUID().uuidString).sqlite3")
        let accountID = UUID()
        let script = ScriptDocument(title: "Delete me")
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        ))
        try await store.upsert(script)
        _ = try await store.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: []
        )
        try await store.deleteScript(id: script.id)

        let reopened = SQLitePersistenceClient(fileURL: url)
        let state = try await reopened.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [],
            localFolderIDs: []
        )
        let tombstone = try XCTUnwrap(state.tombstonesByScriptID[script.id])
        XCTAssertLessThanOrEqual(tombstone.deletedAt, .now)
        let libraryAfterDeletion = try await reopened.load()
        XCTAssertTrue(libraryAfterDeletion.scripts.isEmpty)

        let newerCloudCopy = ScriptDocument(
            id: script.id,
            title: "Newer cloud edit",
            updatedAt: tombstone.deletedAt.addingTimeInterval(10)
        )
        let merged = LibrarySnapshot(
            scripts: [newerCloudCopy],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        try await reopened.applyCloudSync(
            snapshot: merged,
            update: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: [CloudScriptSyncRecord(
                    accountID: accountID,
                    scriptID: script.id,
                    lastSyncedUpdatedAt: newerCloudCopy.updatedAt
                )],
                folderRecords: [],
                tombstones: [],
                clearedTombstoneIDs: [script.id],
                folderTombstones: [],
                clearedFolderTombstoneIDs: [],
                expectedMutationRevision: state.mutationRevision
            )
        )

        let finalStore = SQLitePersistenceClient(fileURL: url)
        let finalLibrary = try await finalStore.load()
        let finalScript = try XCTUnwrap(finalLibrary.scripts.first)
        XCTAssertEqual(finalLibrary.scripts.count, 1)
        XCTAssertEqual(finalScript.id, newerCloudCopy.id)
        XCTAssertEqual(finalScript.title, newerCloudCopy.title)
        XCTAssertEqual(finalScript.body, newerCloudCopy.body)
        XCTAssertEqual(finalScript.source, newerCloudCopy.source)
        XCTAssertEqual(finalScript.folderID, newerCloudCopy.folderID)
        XCTAssertEqual(finalScript.tags, newerCloudCopy.tags)
        XCTAssertEqual(finalScript.outline, newerCloudCopy.outline)
        XCTAssertEqual(
            finalScript.createdAt.timeIntervalSince1970,
            newerCloudCopy.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            finalScript.updatedAt.timeIntervalSince1970,
            newerCloudCopy.updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        let finalState = try await finalStore.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: []
        )
        XCTAssertNil(finalState.tombstonesByScriptID[script.id])
        let finalTimestamp = try XCTUnwrap(
            finalState.currentAccountRecords[script.id]?.lastSyncedUpdatedAt
        )
        XCTAssertEqual(
            finalTimestamp.timeIntervalSince1970,
            newerCloudCopy.updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLitePersistenceClientTests", code: 1)
        }
        return database
    }

    private func emptyPersistenceUpdate(
        accountID: UUID,
        expectedMutationRevision: UInt64
    ) -> CloudSyncPersistenceUpdate {
        CloudSyncPersistenceUpdate(
            accountID: accountID,
            records: [],
            folderRecords: [],
            tombstones: [],
            clearedTombstoneIDs: [],
            folderTombstones: [],
            clearedFolderTombstoneIDs: [],
            expectedMutationRevision: expectedMutationRevision
        )
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "SQLitePersistenceClientTests",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
            )
        }
    }

    private func removeSQLiteFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

private final class FailingSecondRecoveryMove: @unchecked Sendable {
    private let lock = NSLock()
    private var attempt = 0

    func moveItem(at source: URL, to destination: URL) throws {
        lock.lock()
        attempt += 1
        let shouldFail = attempt == 2
        lock.unlock()
        if shouldFail {
            throw NSError(
                domain: "FailingSecondRecoveryMove",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Injected second move failure"]
            )
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
