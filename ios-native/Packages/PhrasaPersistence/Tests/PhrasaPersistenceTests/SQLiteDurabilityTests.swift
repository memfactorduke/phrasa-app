import Foundation
import SQLite3
import XCTest
import PhrasaDomain
@testable import PhrasaPersistence

final class SQLiteDurabilityTests: XCTestCase {
    func testShippingFactoryReturnsRecoverableSQLiteStore() {
        let shipping: any LibraryPersistence & LibraryRecoveryPersistence =
            LibraryPersistenceFactory.makeShipping(fileURL: temporarySQLiteURL())
        // Shipping path must expose recovery; the JSON test double does not.
        XCTAssertTrue(shipping is SQLitePersistenceClient)
        XCTAssertTrue(
            shipping.canRecoverLibrary(
                after: SQLitePersistenceClient.DatabaseError.invalidData("probe")
            )
        )
    }

    func testJSONTestDoubleIsExplicitlyConstructible() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-json-double-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryPersistenceFactory.makeJSONTestDouble(fileURL: url)
        let script = ScriptDocument(title: "Test double only", body: "body")
        try await store.replace(with: LibrarySnapshot(
            scripts: [script],
            folders: [],
            settings: .init(),
            seeded: true
        ))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.scripts.first?.title, "Test double only")
    }

    func testSQLiteWritesSchemaVersionOnFirstOpen() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        _ = try await store.load()

        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        let version = try metaString(database, key: LibrarySchema.versionMetadataKey)
        XCTAssertEqual(version, String(LibrarySchema.currentVersion))
    }

    func testSQLiteRejectsNewerUnsupportedSchema() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: .empty)

        let database = try openDatabase(at: url)
        try execute(
            database,
            """
            INSERT OR REPLACE INTO metadata(key,value)
            VALUES('\(LibrarySchema.versionMetadataKey)','\(LibrarySchema.currentVersion + 1)')
            """
        )
        sqlite3_close(database)

        let reopened = SQLitePersistenceClient(fileURL: url)
        do {
            _ = try await reopened.load()
            XCTFail("Newer schema must not open silently")
        } catch let error as SQLitePersistenceClient.DatabaseError {
            if case .unsupportedSchema = error {
                // expected
            } else {
                XCTFail("Expected unsupportedSchema, got \(error)")
            }
        }
    }

    func testUpsertRoundTripIsAtomicAcrossRelaunch() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let script = ScriptDocument(
            title: "Durable",
            body: "Commit before publish",
            tags: ["a", "b"],
            outline: [OutlinePoint(text: "Point", note: "Note")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.5),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100.25)
        )
        let store = LibraryPersistenceFactory.makeShipping(fileURL: url)
        try await store.upsert(script)
        let reopened = LibraryPersistenceFactory.makeShipping(fileURL: url)
        let loaded = try await reopened.load()
        let persisted = try XCTUnwrap(loaded.scripts.first)
        XCTAssertEqual(persisted.id, script.id)
        XCTAssertEqual(persisted.title, script.title)
        XCTAssertEqual(persisted.body, script.body)
        XCTAssertEqual(persisted.tags, script.tags)
        XCTAssertEqual(persisted.outline, script.outline)
        XCTAssertEqual(
            persisted.createdAt.timeIntervalSince1970,
            script.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            persisted.updatedAt.timeIntervalSince1970,
            script.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testDeleteScriptPersistsTombstoneAndSurvivesRelaunch() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let script = ScriptDocument(title: "To delete")
        let account = UUID()
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.upsert(script)
        try await store.deleteScript(id: script.id)
        let reopened = SQLitePersistenceClient(fileURL: url)
        let loaded = try await reopened.load()
        XCTAssertTrue(loaded.scripts.isEmpty)
        let state = try await reopened.prepareCloudSync(
            accountID: account,
            localScriptIDs: [],
            localFolderIDs: []
        )
        XCTAssertNotNil(state.tombstonesByScriptID[script.id])
    }

    func testCloudApplyRejectsStaleMutationRevision() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let original = ScriptDocument(
            title: "Original",
            body: "before",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [original],
            folders: [],
            settings: .init(),
            seeded: true
        ))
        let prepared = try await store.prepareCloudSync(
            accountID: UUID(),
            localScriptIDs: [original.id],
            localFolderIDs: []
        )
        var edit = original
        edit.body = "local newer"
        edit.updatedAt = Date(timeIntervalSince1970: 20)
        try await store.upsert(edit)

        do {
            try await store.applyCloudSync(
                snapshot: LibrarySnapshot(
                    scripts: [original],
                    folders: [],
                    settings: .init(),
                    seeded: true
                ),
                update: CloudSyncPersistenceUpdate(
                    accountID: prepared.accountID,
                    records: [],
                    folderRecords: [],
                    tombstones: [],
                    clearedTombstoneIDs: [],
                    folderTombstones: [],
                    clearedFolderTombstoneIDs: [],
                    expectedMutationRevision: prepared.mutationRevision
                )
            )
            XCTFail("Stale revision must fail")
        } catch {
            XCTAssertEqual(error as? CloudSyncApplicationError, .localLibraryChanged)
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.scripts.first?.body, "local newer")
    }

    func testReplaceQuarantinesUnownedRows() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let script = ScriptDocument(title: "Restored backup row")
        let folder = ScriptFolder(name: "Restored folder")
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [script],
            folders: [folder],
            settings: .init(),
            seeded: true
        ))
        let account = UUID()
        let state = try await store.prepareCloudSync(
            accountID: account,
            localScriptIDs: [script.id],
            localFolderIDs: [folder.id]
        )
        // Quarantined IDs stay foreign to any real account.
        XCTAssertNil(state.currentAccountRecords[script.id])
        XCTAssertTrue(state.scriptIDsOwnedByOtherAccounts.contains(script.id))
        XCTAssertNil(state.currentAccountFolderRecords[folder.id])
        XCTAssertTrue(state.folderIDsOwnedByOtherAccounts.contains(folder.id))
    }

    /// Local settings last-write-wins at the shipping SQLite boundary: a later
    /// `saveSettings` replaces earlier preferences; `load` after relaunch keeps
    /// the last durable write. (Cloud preference direction lives in PhrasaSync.)
    func testUserSettingsLastWriteWinsAcrossRelaunch() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: .init(),
            seeded: true
        ))

        var first = ReaderSettings()
        first.speedWPM = 120
        first.theme = .paper
        first.normalize()
        try await store.saveSettings(first, seeded: true)

        var second = ReaderSettings()
        second.speedWPM = 180
        second.theme = .contrast
        second.normalize()
        try await store.saveSettings(second, seeded: true)

        let reopened = SQLitePersistenceClient(fileURL: url)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.settings.speedWPM, 180)
        XCTAssertEqual(loaded.settings.theme, .contrast)

        // An intervening replace with older settings must not leave a hybrid:
        // replace is a full snapshot write (last write of the library blob).
        var older = ReaderSettings()
        older.speedWPM = 90
        older.theme = .sepia
        older.normalize()
        try await reopened.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: older,
            seeded: true
        ))
        let afterOlderReplace = try await SQLitePersistenceClient(fileURL: url).load()
        XCTAssertEqual(afterOlderReplace.settings.speedWPM, 90)

        // Final local save wins again.
        var newest = ReaderSettings()
        newest.speedWPM = 155
        newest.theme = .stage
        newest.normalize()
        try await SQLitePersistenceClient(fileURL: url).saveSettings(newest, seeded: true)
        let final = try await SQLitePersistenceClient(fileURL: url).load()
        XCTAssertEqual(final.settings.speedWPM, 155)
        XCTAssertEqual(final.settings.theme, .stage)
    }

    /// `speedCountdown` must survive the shipping SQLite save → relaunch → load path
    /// for every supported value (Off / 5s / 15s).
    func testSpeedCountdownSurvivesSQLiteSaveAndReload() async throws {
        for countdown in SpeedCountdown.allCases {
            let url = temporarySQLiteURL()
            defer { removeSQLiteFiles(at: url) }
            let store = SQLitePersistenceClient(fileURL: url)
            try await store.replace(with: LibrarySnapshot(
                scripts: [],
                folders: [],
                settings: .init(),
                seeded: true
            ))

            var settings = ReaderSettings()
            settings.speedCountdown = countdown
            settings.speedWPM = 155
            settings.normalize()
            try await store.saveSettings(settings, seeded: true)

            let reopened = SQLitePersistenceClient(fileURL: url)
            let loaded = try await reopened.load()
            XCTAssertEqual(
                loaded.settings.speedCountdown,
                countdown,
                "speedCountdown \(countdown) must survive SQLite save/reload"
            )
            XCTAssertEqual(loaded.settings.speedWPM, 155)
        }
    }

    /// A pre-countdown settings blob written directly into metadata (field absent)
    /// must decode to the product default on the real SQLite load path.
    func testLegacySQLiteSettingsWithoutSpeedCountdownDefaultToFive() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        try await store.replace(with: LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: .init(),
            seeded: true
        ))

        let legacyJSON = """
        {
          "mode":"speed", "scrollStyle":"continuous", "font":"hyperlegible",
          "fontSize":56, "lineHeight":1.45, "horizontalMargin":0.12,
          "alignment":"leading", "theme":"stage", "mirrorHorizontal":false,
          "mirrorVertical":false, "focusPosition":0.25, "speedWPM":140,
          "recognitionLanguage":"en-US", "showPacing":true
        }
        """
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        try bindMetaBlob(
            database,
            key: LibrarySchema.settingsMetadataKey,
            data: Data(legacyJSON.utf8)
        )

        let reopened = SQLitePersistenceClient(fileURL: url)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.settings.speedCountdown, .fiveSeconds)
    }

    func testPreserveCorruptLibraryMovesFilesAndAllowsFreshOpen() async throws {
        let url = temporarySQLiteURL()
        defer {
            removeSQLiteFiles(at: url)
            let recoveryRoot = url.deletingLastPathComponent().appendingPathComponent("Recovery")
            try? FileManager.default.removeItem(at: recoveryRoot)
        }
        try Data("not-a-database".utf8).write(to: url)
        let store = SQLitePersistenceClient(fileURL: url)
        do {
            _ = try await store.load()
            XCTFail("Corrupt file should fail to load")
        } catch {
            XCTAssertTrue(store.canRecoverLibrary(after: error))
        }
        let recovery = try await store.preserveCorruptLibraryAndReset()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let fresh = try await store.load()
        XCTAssertEqual(fresh.scripts, [])
        let versionDatabase = try openDatabase(at: url)
        defer { sqlite3_close(versionDatabase) }
        let version = try metaString(versionDatabase, key: LibrarySchema.versionMetadataKey)
        XCTAssertEqual(version, String(LibrarySchema.currentVersion))
    }

    // MARK: - helpers

    private func temporarySQLiteURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-persist-\(UUID().uuidString).sqlite3")
    }

    private func removeSQLiteFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLiteDurabilityTests", code: 1)
        }
        return database
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "SQLiteDurabilityTests",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
            )
        }
    }

    private func metaString(_ database: OpaquePointer, key: String) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM metadata WHERE key = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "SQLiteDurabilityTests", code: 2)
        }
        sqlite3_bind_text(
            statement,
            1,
            key,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
    }

    private func bindMetaBlob(_ database: OpaquePointer, key: String, data: Data) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR REPLACE INTO metadata(key,value) VALUES(?,?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "SQLiteDurabilityTests", code: 3)
        }
        // SQLITE_TRANSIENT (-1): copy key/value so the SQL statement owns the bytes.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        let bindResult = data.withUnsafeBytes { buffer -> Int32 in
            sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(data.count), transient)
        }
        guard bindResult == SQLITE_OK else {
            throw NSError(domain: "SQLiteDurabilityTests", code: 4)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "SQLiteDurabilityTests", code: 5)
        }
    }
}

// MARK: - Practical performance measurements (pathological bounds only)

extension SQLiteDurabilityTests {
    private static let performanceWordCount = 2_000

    private func makeTwoThousandWordBody(seed: Int = 0) -> String {
        (0..<Self.performanceWordCount)
            .map { "w\(seed)-\($0 % 113)" }
            .joined(separator: " ")
    }

    func testTwoThousandWordUpsertLoadAndRelaunchStayDurableAndBounded() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let body = makeTwoThousandWordBody()
        let script = ScriptDocument(
            title: "Performance rehearsal",
            body: body,
            tags: ["perf", "rehearsal"],
            outline: [
                OutlinePoint(text: "Open", note: "Breathe"),
                OutlinePoint(text: "Close", note: "Thank them")
            ]
        )

        let writeStarted = CFAbsoluteTimeGetCurrent()
        let store = LibraryPersistenceFactory.makeShipping(fileURL: url)
        try await store.upsert(script)
        let writeElapsed = CFAbsoluteTimeGetCurrent() - writeStarted

        let loadStarted = CFAbsoluteTimeGetCurrent()
        let reopened = LibraryPersistenceFactory.makeShipping(fileURL: url)
        let loaded = try await reopened.load()
        let loadElapsed = CFAbsoluteTimeGetCurrent() - loadStarted

        let persisted = try XCTUnwrap(loaded.scripts.first)
        XCTAssertEqual(persisted.id, script.id)
        XCTAssertEqual(persisted.body, body)
        XCTAssertEqual(persisted.outline.count, 2)
        XCTAssertEqual(TextMetrics.wordCountProxy(body), Self.performanceWordCount)

        // Pathological multi-second stalls only — not tight wall-clock SLAs.
        XCTAssertLessThan(writeElapsed, 2.0, "2k-word upsert stalled (\(writeElapsed)s)")
        XCTAssertLessThan(loadElapsed, 2.0, "2k-word load stalled (\(loadElapsed)s)")
        print(String(format: "PERF sqlite_upsert_2000_words=%.3fms", writeElapsed * 1_000))
        print(String(format: "PERF sqlite_load_2000_words=%.3fms", loadElapsed * 1_000))
    }

    func testPersistenceHotPathBulkUpsertsStayBounded() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let store = SQLitePersistenceClient(fileURL: url)
        let scripts = (0..<40).map { index in
            ScriptDocument(
                title: "Hot path \(index)",
                body: makeTwoThousandWordBody(seed: index),
                tags: ["bulk"]
            )
        }

        let started = CFAbsoluteTimeGetCurrent()
        for script in scripts {
            try await store.upsert(script)
        }
        let loaded = try await store.load()
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(loaded.scripts.count, scripts.count)
        // 40 × 2k-word scripts: multi-second is still acceptable; fail only on stalls.
        XCTAssertLessThan(elapsed, 15.0, "bulk upsert hot path stalled (\(elapsed)s)")
        print(
            String(
                format: "PERF sqlite_bulk_40x2000_words=%.3fms scripts=%d",
                elapsed * 1_000,
                loaded.scripts.count
            )
        )
    }

    func testEditAutosaveRelaunchRecoveryForLargeScript() async throws {
        let url = temporarySQLiteURL()
        defer { removeSQLiteFiles(at: url) }
        let originalBody = makeTwoThousandWordBody(seed: 7)
        let script = ScriptDocument(title: "Draft", body: originalBody)
        let first = SQLitePersistenceClient(fileURL: url)
        try await first.upsert(script)

        var edited = script
        edited.body = originalBody + "\n\nEncore line for relaunch."
        edited.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let editStarted = CFAbsoluteTimeGetCurrent()
        try await first.upsert(edited)
        let editElapsed = CFAbsoluteTimeGetCurrent() - editStarted

        let second = SQLitePersistenceClient(fileURL: url)
        let loaded = try await second.load()
        let persisted = try XCTUnwrap(loaded.scripts.first { $0.id == script.id })
        XCTAssertTrue(persisted.body.hasSuffix("Encore line for relaunch."))
        XCTAssertEqual(
            persisted.updatedAt.timeIntervalSince1970,
            edited.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertLessThan(editElapsed, 2.0, "large edit upsert stalled (\(editElapsed)s)")
        print(String(format: "PERF sqlite_edit_relaunch_2000_words=%.3fms", editElapsed * 1_000))
    }
}

/// Lightweight word count for package tests without depending on app TextMetrics.
private enum TextMetrics {
    static func wordCountProxy(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
