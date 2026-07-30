import SQLite3
import XCTest
@testable import Phrasa

final class LegacyExpoMigratorTests: XCTestCase {
    func testMissingDatabaseIsTheOnlyNoLegacyDatabaseCase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-expo-library-\(UUID().uuidString)")

        XCTAssertNil(try LegacyExpoMigrator(databaseURL: url).importIfPresent())
    }

    func testExistingCorruptDatabaseThrowsInsteadOfLookingAbsent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-expo-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a sqlite database".utf8).write(to: url)

        XCTAssertThrowsError(try LegacyExpoMigrator(databaseURL: url).importIfPresent()) { error in
            XCTAssertNotNil(error as? LegacyExpoMigrator.MigrationError)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was replaced"))
        }
    }

    func testMalformedLegacyRecordThrowsInsteadOfBeingSilentlyMarkedMigrated() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        try insert(database, key: "autoprompt.scripts.v1", json: [[
            "title": "A script whose identifier was damaged",
            "body": "This content must not be silently discarded",
        ]])

        XCTAssertThrowsError(try LegacyExpoMigrator(databaseURL: url).importIfPresent()) { error in
            XCTAssertEqual(
                error as? LegacyExpoMigrator.MigrationError,
                .invalidData("script record 1")
            )
        }
    }

    func testPresentWrongTypedTitleOrBodyStopsMigration() throws {
        let malformedValues: [(field: String, value: Any)] = [
            ("title", 42),
            ("body", ["unexpected": "object"]),
        ]

        for malformed in malformedValues {
            let url = try makeDatabase()
            let database = try openDatabase(at: url)
            var script: [String: Any] = [
                "id": UUID().uuidString,
                "title": "Valid title",
                "body": "Valid body",
            ]
            script[malformed.field] = malformed.value
            try insert(database, key: "autoprompt.scripts.v1", json: [script])
            sqlite3_close(database)

            XCTAssertThrowsError(
                try LegacyExpoMigrator(databaseURL: url).importIfPresent(),
                "A present non-text \(malformed.field) must not be treated as absent"
            ) { error in
                XCTAssertEqual(
                    error as? LegacyExpoMigrator.MigrationError,
                    .invalidData("script record 1 \(malformed.field)")
                )
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func testPresentMalformedScriptTimestampsStopMigration() throws {
        for field in ["createdAt", "updatedAt", "lastOpenedAt"] {
            let url = try makeDatabase()
            let database = try openDatabase(at: url)
            try insert(database, key: "autoprompt.scripts.v1", json: [[
                "id": UUID().uuidString,
                "title": "Keep this script",
                "body": "Its damaged date must not erase it",
                field: "not-an-iso-8601-date",
            ]])
            sqlite3_close(database)

            XCTAssertThrowsError(
                try LegacyExpoMigrator(databaseURL: url).importIfPresent(),
                "A malformed \(field) must not be replaced with the current time"
            ) { error in
                XCTAssertEqual(
                    error as? LegacyExpoMigrator.MigrationError,
                    .invalidData("script record 1 \(field)")
                )
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func testPresentMalformedFolderTimestampStopsMigration() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openDatabase(at: url)
        try insert(database, key: "autoprompt.folders.v1", json: [[
            "id": UUID().uuidString,
            "name": "Keep this folder",
            "createdAt": "not-an-iso-8601-date",
        ]])
        sqlite3_close(database)

        XCTAssertThrowsError(try LegacyExpoMigrator(databaseURL: url).importIfPresent()) { error in
            XCTAssertEqual(
                error as? LegacyExpoMigrator.MigrationError,
                .invalidData("folder record 1 createdAt")
            )
        }
    }

    func testAbsentOptionalScriptFieldsStillReceiveDocumentedDefaults() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openDatabase(at: url)
        try insert(database, key: "autoprompt.scripts.v1", json: [[
            "id": UUID().uuidString,
            "lastOpenedAt": NSNull(),
        ]])
        sqlite3_close(database)

        let migrated = try XCTUnwrap(
            LegacyExpoMigrator(databaseURL: url).importIfPresent()?.scripts.first
        )
        XCTAssertEqual(migrated.title, "Untitled script")
        XCTAssertEqual(migrated.body, "")
        XCTAssertNil(migrated.lastOpenedAt)
        XCTAssertEqual(migrated.updatedAt, migrated.createdAt)
    }

    @MainActor
    func testLibraryStoreDoesNotSeedOverUnreadableLegacyDataAndCanRetry() async throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-expo-library-\(UUID().uuidString)")
        let nativeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-native-library-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: nativeURL.path + suffix)
            }
        }
        try Data("stranded upgrade data".utf8).write(to: legacyURL)
        let persistence = SQLitePersistenceClient(fileURL: nativeURL)
        let library = LibraryStore(
            persistence: persistence,
            legacyMigrator: LegacyExpoMigrator(databaseURL: legacyURL)
        )

        await library.load()

        XCTAssertFalse(library.isLoaded)
        XCTAssertTrue(library.scripts.isEmpty)
        XCTAssertTrue(library.canStartFreshAfterCorruption)
        XCTAssertNotNil(library.errorMessage)
        let nativeLibraryBeforeRetry = try await persistence.load()
        XCTAssertTrue(nativeLibraryBeforeRetry.scripts.isEmpty)
        XCTAssertFalse(nativeLibraryBeforeRetry.seeded)

        try FileManager.default.removeItem(at: legacyURL)
        let database = try makeDatabase(at: legacyURL)
        try insert(database, key: "autoprompt.scripts.v1", json: [[
            "id": UUID().uuidString,
            "title": "Recovered upgrade script",
            "body": "Still here",
        ]])
        sqlite3_close(database)

        await library.load()

        XCTAssertTrue(library.isLoaded)
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.scripts.map(\.title), ["Recovered upgrade script"])
        let savedLibrary = try await persistence.load()
        XCTAssertTrue(savedLibrary.seeded)
    }

    @MainActor
    func testConfirmedFreshStartPreservesUnreadableLegacyDatabaseAndSidecars() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-legacy-recovery-\(UUID().uuidString)", isDirectory: true)
        let legacyURL = directory.appendingPathComponent("ExpoSQLiteStorage")
        let legacyWALURL = URL(fileURLWithPath: legacyURL.path + "-wal")
        let legacySHMURL = URL(fileURLWithPath: legacyURL.path + "-shm")
        let nativeURL = directory.appendingPathComponent("library.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseData = Data("unreadable legacy database".utf8)
        let walData = Data("legacy pending writes".utf8)
        let shmData = Data("legacy shared memory".utf8)
        try databaseData.write(to: legacyURL)
        try walData.write(to: legacyWALURL)
        try shmData.write(to: legacySHMURL)
        let persistence = SQLitePersistenceClient(fileURL: nativeURL)
        let library = LibraryStore(
            persistence: persistence,
            legacyMigrator: LegacyExpoMigrator(databaseURL: legacyURL)
        )

        await library.load()

        XCTAssertFalse(library.isLoaded)
        XCTAssertTrue(library.canStartFreshAfterCorruption)
        XCTAssertEqual(try Data(contentsOf: legacyURL), databaseData)
        // SQLite may resize/update its shared-memory sidecar while attempting
        // the read. Recovery must preserve the exact files left after that
        // failed attempt, which are the files the user can later inspect.
        let databaseBeforeRecovery = try Data(contentsOf: legacyURL)
        let walBeforeRecovery = try Data(contentsOf: legacyWALURL)
        let shmBeforeRecovery = try Data(contentsOf: legacySHMURL)

        let didStartFresh = await library.startFreshAfterCorruption()

        XCTAssertTrue(didStartFresh)
        XCTAssertTrue(library.isLoaded)
        XCTAssertEqual(library.scripts.map(\.title), ["Welcome to Phrasa"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyWALURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySHMURL.path))
        let recoveryRoot = directory.appendingPathComponent("Recovery", isDirectory: true)
        let recoveryDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: recoveryRoot,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(
            try Data(contentsOf: recoveryDirectory.appendingPathComponent(legacyURL.lastPathComponent)),
            databaseBeforeRecovery
        )
        XCTAssertEqual(
            try Data(contentsOf: recoveryDirectory.appendingPathComponent(legacyWALURL.lastPathComponent)),
            walBeforeRecovery
        )
        XCTAssertEqual(
            try Data(contentsOf: recoveryDirectory.appendingPathComponent(legacySHMURL.lastPathComponent)),
            shmBeforeRecovery
        )
        let nativeLibrary = try await persistence.load()
        XCTAssertTrue(nativeLibrary.seeded)
        XCTAssertEqual(nativeLibrary.scripts.map(\.title), ["Welcome to Phrasa"])
    }

    func testImportsExpoScriptsFoldersAndSettings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpoSQLiteStorage-\(UUID().uuidString)")
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &databasePointer), SQLITE_OK)
        let database = try XCTUnwrap(databasePointer)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE storage(key TEXT PRIMARY KEY NOT NULL,value TEXT)", nil, nil, nil), SQLITE_OK)

        let scriptID = UUID()
        let folderID = UUID()
        try insert(database, key: "autoprompt.scripts.v1", json: [[
            "id": scriptID.uuidString,
            "title": "Existing phone script",
            "body": "Keep this safe",
            "sourceType": "manual",
            "folderId": folderID.uuidString.lowercased(),
            "tags": ["important"],
            "outline": [["id": "legacy-point", "text": "Opening", "note": "Smile"]],
            "createdAt": "2026-07-01T12:00:00.000Z",
            "updatedAt": "2026-07-02T12:00:00.000Z"
        ]])
        try insert(database, key: "autoprompt.folders.v1", json: [[
            "id": folderID.uuidString,
            "name": "Shows",
            "createdAt": "2026-07-01T12:00:00.000Z"
        ]])
        try insert(database, key: "autoprompt.settings.v1", json: [
            "fontFamily": "mono",
            "fontSize": 72,
            "marginX": 20,
            "speedWpm": 165,
            "mirrorH": true
        ])

        let migrated = try XCTUnwrap(LegacyExpoMigrator(databaseURL: url).importIfPresent())
        XCTAssertEqual(migrated.scripts.count, 1)
        XCTAssertEqual(migrated.scripts[0].id, scriptID)
        XCTAssertEqual(migrated.scripts[0].folderID, folderID)
        XCTAssertEqual(migrated.scripts[0].outline.first?.text, "Opening")
        XCTAssertEqual(migrated.folders.first?.id, folderID)
        XCTAssertEqual(migrated.settings.font, .mono)
        XCTAssertEqual(migrated.settings.fontSize, 72)
        XCTAssertEqual(migrated.settings.horizontalMargin, 0.2)
        XCTAssertEqual(migrated.settings.speedWPM, 165)
        XCTAssertTrue(migrated.settings.mirrorHorizontal)
    }

    func testPreservesLegacyOutlinePointThatOnlyHasANote() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        let pointID = UUID()

        try insert(database, key: "autoprompt.scripts.v1", json: [[
            "id": UUID().uuidString,
            "title": "Note-only outline",
            "outline": [[
                "id": pointID.uuidString,
                "text": "   ",
                "note": "Pause before the reveal"
            ]]
        ]])

        let migrated = try XCTUnwrap(LegacyExpoMigrator(databaseURL: url).importIfPresent())
        let point = try XCTUnwrap(migrated.scripts.first?.outline.first)
        XCTAssertEqual(point.id, pointID)
        XCTAssertEqual(point.text, "")
        XCTAssertEqual(point.note, "Pause before the reveal")
    }

    func testNormalizesLegacyDuplicatesAndMissingFolderReferences() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }
        let repeatedPointID = UUID()

        try insert(database, key: "autoprompt.scripts.v1", json: [[
            "id": UUID().uuidString,
            "title": "Legacy edge cases",
            "folderId": "folder-that-no-longer-exists",
            "tags": ["important", "important"],
            "outline": [
                ["id": repeatedPointID.uuidString, "text": "First"],
                ["id": repeatedPointID.uuidString, "text": "Second"]
            ]
        ]])

        let migrated = try XCTUnwrap(LegacyExpoMigrator(databaseURL: url).importIfPresent())
        let script = try XCTUnwrap(migrated.scripts.first)
        XCTAssertNil(script.folderID)
        XCTAssertEqual(script.tags, ["important"])
        XCTAssertEqual(script.outline.count, 2)
        XCTAssertEqual(Set(script.outline.map(\.id)).count, 2)
    }

    func testImportsNonUUIDFallbackIDsAndPreservesFolderLinkage() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }

        try insert(database, key: "autoprompt.scripts.v1", json: [[
            "id": "script-1719864000000-fallback",
            "title": "Fallback script",
            "body": "This script must survive migration",
            "folderId": "folder-1719864000000-fallback"
        ]])
        try insert(database, key: "autoprompt.folders.v1", json: [[
            "id": "folder-1719864000000-fallback",
            "name": "Fallback folder"
        ]])

        let migrated = try XCTUnwrap(LegacyExpoMigrator(databaseURL: url).importIfPresent())
        let script = try XCTUnwrap(migrated.scripts.first)
        let folder = try XCTUnwrap(migrated.folders.first)
        XCTAssertEqual(script.title, "Fallback script")
        XCTAssertEqual(script.folderID, folder.id)
    }

    func testDuplicateLegacyIDsKeepEveryRecordAndUseFirstFolderAsCanonicalReference() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openDatabase(at: url)
        defer { sqlite3_close(database) }

        try insert(database, key: "autoprompt.scripts.v1", json: [
            ["id": "duplicate-script", "title": "First script", "folderId": "duplicate-folder"],
            ["id": "duplicate-script", "title": "Second script", "folderId": "duplicate-folder"]
        ])
        try insert(database, key: "autoprompt.folders.v1", json: [
            ["id": "duplicate-folder", "name": "First folder"],
            ["id": "duplicate-folder", "name": "Second folder"]
        ])

        let migrated = try XCTUnwrap(LegacyExpoMigrator(databaseURL: url).importIfPresent())
        XCTAssertEqual(migrated.scripts.count, 2)
        XCTAssertEqual(Set(migrated.scripts.map(\.id)).count, 2)
        XCTAssertEqual(Set(migrated.scripts.map(\.title)), ["First script", "Second script"])
        XCTAssertEqual(migrated.folders.count, 2)
        XCTAssertEqual(Set(migrated.folders.map(\.id)).count, 2)
        XCTAssertEqual(Set(migrated.folders.map(\.name)), ["First folder", "Second folder"])

        let canonicalFolder = try XCTUnwrap(migrated.folders.first)
        XCTAssertTrue(migrated.scripts.allSatisfy { $0.folderID == canonicalFolder.id })
    }

    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpoSQLiteStorage-\(UUID().uuidString)")
        let database = try makeDatabase(at: url)
        defer { sqlite3_close(database) }
        return url
    }

    private func makeDatabase(at url: URL) throws -> OpaquePointer {
        let database = try openDatabase(at: url)
        XCTAssertEqual(
            sqlite3_exec(database, "CREATE TABLE storage(key TEXT PRIMARY KEY NOT NULL,value TEXT)", nil, nil, nil),
            SQLITE_OK
        )
        return database
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &databasePointer), SQLITE_OK)
        return try XCTUnwrap(databasePointer)
    }

    private func insert(_ database: OpaquePointer, key: String, json: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let value = try XCTUnwrap(String(data: data, encoding: .utf8))
        var statementPointer: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO storage(key,value) VALUES(?,?)", -1, &statementPointer, nil), SQLITE_OK)
        let statement = try XCTUnwrap(statementPointer)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}
