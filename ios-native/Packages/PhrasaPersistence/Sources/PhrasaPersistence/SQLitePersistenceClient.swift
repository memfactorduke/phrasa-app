import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif
import SQLite3

private final class SQLiteConnectionHandle: @unchecked Sendable {
    var pointer: OpaquePointer?

    deinit {
        if let pointer {
            // `close_v2` safely defers final closure until SQLite releases any
            // internal statement still associated with the connection.
            sqlite3_close_v2(pointer)
        }
    }
}

public actor SQLitePersistenceClient: LibraryPersistence, LibraryRecoveryPersistence {
    public enum DatabaseError: LocalizedError, Sendable {
        case open(String)
        case execute(String)
        case prepare(String)
        case read(String)
        case invalidData(String)
        case unsupportedSchema(String)
        case ownershipConflict(String)

        public var errorDescription: String? {
            switch self {
            case .open(let message): "Phrasa could not open its offline library: \(message)"
            case .execute(let message), .prepare(let message): "Phrasa could not save its offline library: \(message)"
            case .read(let message): "Phrasa could not finish reading its offline library: \(message)"
            case .invalidData(let detail): "Phrasa found damaged data in its offline library: \(detail)"
            case .unsupportedSchema(let detail): "This Phrasa library was created by a newer app version: \(detail)"
            case .ownershipConflict(let detail): "Phrasa kept account-owned offline data unchanged: \(detail)"
            }
        }
    }

    public enum LibraryRecoveryError: LocalizedError, Sendable {
        case closeFailed(String)
        case missingDatabase
        case moveFailed(String)
        case rollbackFailed(String)

        public var errorDescription: String? {
            switch self {
            case .closeFailed(let detail):
                "Phrasa could not safely close the damaged library: \(detail)"
            case .missingDatabase:
                "Phrasa could not find the damaged library file, so nothing was reset."
            case .moveFailed(let detail):
                "Phrasa could not preserve the damaged library. The original files were put back: \(detail)"
            case .rollbackFailed(let detail):
                "Phrasa could not finish preserving the damaged library or fully put its files back: \(detail)"
            }
        }
    }

    private let fileURL: URL
    private let recoveryMoveItem: @Sendable (URL, URL) throws -> Void
    private let connectionHandle = SQLiteConnectionHandle()
    private var database: OpaquePointer? {
        get { connectionHandle.pointer }
        set { connectionHandle.pointer = newValue }
    }
    private var mutationRevision: UInt64 = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let ownershipSchemaKey = LibrarySchema.ownershipSchemaKey
    private static let currentOwnershipSchemaVersion = LibrarySchema.currentOwnershipSchemaVersion

    public init(
        fileURL: URL? = nil,
        recoveryMoveItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = fileURL ?? base.appendingPathComponent("Phrasa", isDirectory: true)
            .appendingPathComponent("library.sqlite3")
        self.recoveryMoveItem = recoveryMoveItem
    }

    public nonisolated func canRecoverLibrary(after error: Error) -> Bool {
        guard let databaseError = error as? DatabaseError else { return false }
        switch databaseError {
        case .invalidData:
            return true
        case .open(let detail), .execute(let detail), .prepare(let detail), .read(let detail):
            return Self.isCorruptionMessage(detail)
        case .unsupportedSchema, .ownershipConflict:
            return false
        }
    }

    private static func isCorruptionMessage(_ detail: String) -> Bool {
        let normalized = detail.lowercased()
        return normalized.contains("not a database")
            || normalized.contains("database disk image is malformed")
            || normalized.contains("malformed database schema")
            || normalized.contains("corrupt")
    }

    public func preserveCorruptLibraryAndReset() async throws -> URL {
        try closeDatabaseForRecovery()
        let fileManager = FileManager.default
        let sources = ["", "-wal", "-shm"]
            .map { URL(fileURLWithPath: fileURL.path + $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard sources.contains(fileURL) else {
            throw LibraryRecoveryError.missingDatabase
        }

        let recoveryRoot = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
        let timestamp = Int(Date.now.timeIntervalSince1970)
        let recoveryDirectory = recoveryRoot.appendingPathComponent(
            "library-\(timestamp)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )

        var moved: [(source: URL, destination: URL)] = []
        do {
            for source in sources {
                let destination = recoveryDirectory.appendingPathComponent(source.lastPathComponent)
                try recoveryMoveItem(source, destination)
                moved.append((source, destination))
            }
        } catch {
            var rollbackFailure: Error?
            for item in moved.reversed() {
                do {
                    try recoveryMoveItem(item.destination, item.source)
                } catch {
                    rollbackFailure = rollbackFailure ?? error
                }
            }
            if rollbackFailure == nil {
                try? fileManager.removeItem(at: recoveryDirectory)
                throw LibraryRecoveryError.moveFailed(error.localizedDescription)
            }
            throw LibraryRecoveryError.rollbackFailed(
                rollbackFailure?.localizedDescription ?? error.localizedDescription
            )
        }
        mutationRevision = 0
        return recoveryDirectory
    }

    public func load() async throws -> LibrarySnapshot {
        let db = try connection()
        var snapshot = LibrarySnapshot.empty
        snapshot.scripts = try loadScripts(db)
        snapshot.folders = try loadFolders(db)
        if let settingsData = try meta(db, key: LibrarySchema.settingsMetadataKey) {
            do {
                snapshot.settings = try decoder.decode(ReaderSettings.self, from: settingsData)
                snapshot.settings.normalize()
            } catch {
                throw DatabaseError.invalidData("reader settings could not be decoded")
            }
        }
        if let seededData = try meta(db, key: LibrarySchema.seededMetadataKey) {
            guard let seededString = String(data: seededData, encoding: .utf8),
                  seededString == "0" || seededString == "1" else {
                throw DatabaseError.invalidData("the migration marker is invalid")
            }
            snapshot.seeded = seededString == "1"
        }
        return snapshot
    }

    public func replace(with snapshot: LibrarySnapshot) async throws {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            try replaceLibrary(with: snapshot, db: db)
            // Bulk import/restore content has no trustworthy account context.
            // Give every still-unowned row a durable local-only owner rather
            // than allowing the next signed-in account to claim it implicitly.
            try quarantineUnownedLibraryRows(db)
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func upsert(_ script: ScriptDocument) async throws {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            try upsert(script, db: db)
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func upsertCloudConflict(_ script: ScriptDocument, accountID: UUID) async throws {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            guard try !hasForeignCloudOwner(
                scriptID: script.id,
                accountID: accountID,
                db: db
            ) else {
                throw DatabaseError.ownershipConflict(
                    "the protected copy already belongs to a different account"
                )
            }
            try upsert(script, db: db)
            try upsertCloudSyncRecord(
                CloudScriptSyncRecord(
                    accountID: accountID,
                    scriptID: script.id,
                    lastSyncedUpdatedAt: nil
                ),
                db: db
            )
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func deleteScript(id: UUID) async throws {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, "DELETE FROM scripts WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, in: statement)
            try stepDone(statement, db: db)
            try upsertTombstone(
                ScriptDeletionTombstone(scriptID: id, deletedAt: .now),
                db: db
            )
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func deleteFolder(id: UUID, updatedScripts: [ScriptDocument]) async throws {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, "DELETE FROM folders WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, in: statement)
            try stepDone(statement, db: db)
            try upsertFolderTombstone(
                FolderDeletionTombstone(folderID: id, deletedAt: .now),
                db: db
            )
            for script in updatedScripts { try upsert(script, db: db) }
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func saveSettings(_ settings: ReaderSettings, seeded: Bool) async throws {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            try setMeta(db, key: LibrarySchema.settingsMetadataKey, data: try encoder.encode(settings))
            try setMeta(db, key: LibrarySchema.seededMetadataKey, data: Data(seeded ? "1".utf8 : "0".utf8))
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func saveFolders(_ folders: [ScriptFolder]) async throws {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            try execute(db, "DELETE FROM folders")
            try saveFolders(folders, db: db)
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func prepareCloudSync(
        accountID: UUID,
        localScriptIDs: Set<UUID>,
        localFolderIDs: Set<UUID>
    ) async throws -> CloudLocalSyncState {
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            // A script is claimed only when no account has ever owned it on
            // this device. This first-writer rule is the durable privacy
            // boundary that prevents account B from uploading account A's
            // downloaded or previously uploaded scripts.
            for scriptID in localScriptIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let statement = try prepare(db, """
                    INSERT INTO cloud_script_sync_state(account_id,script_id,last_synced_updated)
                    SELECT ?,?,NULL
                    WHERE NOT EXISTS (
                      SELECT 1 FROM cloud_script_sync_state WHERE script_id = ?
                    )
                    """)
                defer { sqlite3_finalize(statement) }
                bind(accountID.uuidString, at: 1, in: statement)
                bind(scriptID.uuidString, at: 2, in: statement)
                bind(scriptID.uuidString, at: 3, in: statement)
                try stepDone(statement, db: db)
            }
            for folderID in localFolderIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let statement = try prepare(db, """
                    INSERT INTO cloud_folder_sync_state(account_id,folder_id,has_synced)
                    SELECT ?,?,0
                    WHERE NOT EXISTS (
                      SELECT 1 FROM cloud_folder_sync_state WHERE folder_id = ?
                    )
                    """)
                defer { sqlite3_finalize(statement) }
                bind(accountID.uuidString, at: 1, in: statement)
                bind(folderID.uuidString, at: 2, in: statement)
                bind(folderID.uuidString, at: 3, in: statement)
                try stepDone(statement, db: db)
            }
            let nextMutationRevision = mutationRevision &+ 1
            let state = try loadCloudSyncState(
                accountID: accountID,
                mutationRevision: nextMutationRevision,
                db: db
            )
            try execute(db, "COMMIT")
            mutationRevision = nextMutationRevision
            return state
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    public func applyCloudSync(
        snapshot: LibrarySnapshot,
        update: CloudSyncPersistenceUpdate
    ) async throws {
        guard update.expectedMutationRevision == mutationRevision else {
            throw CloudSyncApplicationError.localLibraryChanged
        }
        let db = try connection()
        try execute(db, "BEGIN IMMEDIATE")
        do {
            try replaceLibrary(with: snapshot, db: db)
            for record in update.records where record.accountID == update.accountID {
                try upsertCloudSyncRecord(record, db: db)
            }
            for record in update.folderRecords where record.accountID == update.accountID {
                try upsertCloudFolderSyncRecord(record, db: db)
            }
            for tombstone in update.tombstones {
                try upsertTombstone(tombstone, db: db)
            }
            for scriptID in update.clearedTombstoneIDs {
                try deleteTombstone(scriptID: scriptID, db: db)
            }
            for tombstone in update.folderTombstones {
                try upsertFolderTombstone(tombstone, db: db)
            }
            for folderID in update.clearedFolderTombstoneIDs {
                try deleteFolderTombstone(folderID: folderID, db: db)
            }
            try execute(db, "COMMIT")
            recordMutation()
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private func connection() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(fileURL.path, &opened, flags, nil)
        guard openResult == SQLITE_OK, let opened else {
            let detail = opened.map { message($0) } ?? "SQLite returned error \(openResult)"
            if let opened { sqlite3_close(opened) }
            throw DatabaseError.open(detail)
        }
        do {
            try execute(opened, "PRAGMA journal_mode = WAL")
            try execute(opened, "PRAGMA foreign_keys = ON")
            try execute(opened, "PRAGMA synchronous = NORMAL")
            try execute(opened, """
            CREATE TABLE IF NOT EXISTS scripts (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                source TEXT NOT NULL,
                folder_id TEXT,
                tags BLOB NOT NULL,
                outline BLOB NOT NULL,
                last_opened REAL,
                created REAL NOT NULL,
                updated REAL NOT NULL
            )
            """)
            try execute(opened, "CREATE INDEX IF NOT EXISTS scripts_updated ON scripts(updated DESC)")
            try execute(opened, """
            CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                created REAL NOT NULL
            )
            """)
            try execute(opened, "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)")
            try execute(opened, """
            CREATE TABLE IF NOT EXISTS script_deletion_tombstones (
                script_id TEXT PRIMARY KEY NOT NULL,
                deleted REAL NOT NULL
            )
            """)
            try execute(opened, """
            CREATE TABLE IF NOT EXISTS folder_deletion_tombstones (
                folder_id TEXT PRIMARY KEY NOT NULL,
                deleted REAL NOT NULL
            )
            """)
            try execute(opened, """
            CREATE TABLE IF NOT EXISTS cloud_script_sync_state (
                account_id TEXT NOT NULL,
                script_id TEXT NOT NULL,
                last_synced_updated REAL,
                last_synced_fingerprint TEXT,
                PRIMARY KEY(account_id, script_id)
            )
            """)
            let scriptStateColumns = try cloudScriptStateColumns(opened)
            if !scriptStateColumns.contains("last_synced_fingerprint") {
                try execute(
                    opened,
                    "ALTER TABLE cloud_script_sync_state ADD COLUMN last_synced_fingerprint TEXT"
                )
            }
            try execute(opened, "CREATE INDEX IF NOT EXISTS cloud_script_sync_state_script ON cloud_script_sync_state(script_id)")
            try execute(opened, """
            CREATE TABLE IF NOT EXISTS cloud_folder_sync_state (
                account_id TEXT NOT NULL,
                folder_id TEXT NOT NULL,
                has_synced INTEGER NOT NULL DEFAULT 0,
                last_synced_name TEXT,
                last_synced_created REAL,
                PRIMARY KEY(account_id, folder_id)
            )
            """)
            var folderStateColumns = try cloudFolderStateColumns(opened)
            if !folderStateColumns.contains("has_synced") {
                try execute(
                    opened,
                    "ALTER TABLE cloud_folder_sync_state ADD COLUMN has_synced INTEGER NOT NULL DEFAULT 0"
                )
                folderStateColumns.insert("has_synced")
            }
            if !folderStateColumns.contains("last_synced_name") {
                try execute(
                    opened,
                    "ALTER TABLE cloud_folder_sync_state ADD COLUMN last_synced_name TEXT"
                )
                folderStateColumns.insert("last_synced_name")
            }
            if !folderStateColumns.contains("last_synced_created") {
                try execute(
                    opened,
                    "ALTER TABLE cloud_folder_sync_state ADD COLUMN last_synced_created REAL"
                )
            }
            try execute(opened, "CREATE INDEX IF NOT EXISTS cloud_folder_sync_state_folder ON cloud_folder_sync_state(folder_id)")
            try migrateCloudOwnershipIfNeeded(opened)
            try migrateLibrarySchemaIfNeeded(opened)
            database = opened
            return opened
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    private func closeDatabaseForRecovery() throws {
        guard let database else { return }
        let result = sqlite3_close(database)
        guard result == SQLITE_OK else {
            throw LibraryRecoveryError.closeFailed(message(database))
        }
        self.database = nil
    }

    /// Records and validates the library layout version. Table creation remains
    /// idempotent via `CREATE TABLE IF NOT EXISTS`; future layout changes add
    /// ordered steps here before bumping `LibrarySchema.currentVersion`.
    private func migrateLibrarySchemaIfNeeded(_ db: OpaquePointer) throws {
        let expected = String(LibrarySchema.currentVersion)
        if let versionData = try meta(db, key: LibrarySchema.versionMetadataKey) {
            guard let version = String(data: versionData, encoding: .utf8),
                  let stored = Int(version) else {
                throw DatabaseError.invalidData("the library schema marker is invalid")
            }
            if stored > LibrarySchema.currentVersion {
                throw DatabaseError.unsupportedSchema("schema \(stored)")
            }
            if stored < LibrarySchema.currentVersion {
                try setMeta(
                    db,
                    key: LibrarySchema.versionMetadataKey,
                    data: Data(expected.utf8)
                )
            }
            return
        }
        try setMeta(
            db,
            key: LibrarySchema.versionMetadataKey,
            data: Data(expected.utf8)
        )
    }

    private func migrateCloudOwnershipIfNeeded(_ db: OpaquePointer) throws {
        if let versionData = try meta(db, key: Self.ownershipSchemaKey) {
            guard let version = String(data: versionData, encoding: .utf8) else {
                throw DatabaseError.invalidData("the cloud ownership marker is invalid")
            }
            if version != Self.currentOwnershipSchemaVersion {
                if let storedVersion = Int(version),
                   let currentVersion = Int(Self.currentOwnershipSchemaVersion),
                   storedVersion > currentVersion {
                    throw DatabaseError.unsupportedSchema("schema \(storedVersion)")
                }
                throw DatabaseError.invalidData("the cloud ownership marker is invalid")
            }
            return
        }

        try execute(db, "BEGIN IMMEDIATE")
        do {
            // Rows that existed before account provenance was introduced have
            // no safe account assignment. Quarantine only IDs with no existing
            // owner so already-protected libraries remain unchanged.
            try quarantineUnownedLibraryRows(db)
            try setMeta(
                db,
                key: Self.ownershipSchemaKey,
                data: Data(Self.currentOwnershipSchemaVersion.utf8)
            )
            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private func quarantineUnownedLibraryRows(_ db: OpaquePointer) throws {
        let scriptStatement = try prepare(db, """
            INSERT INTO cloud_script_sync_state(account_id,script_id,last_synced_updated)
            SELECT ?,scripts.id,NULL
            FROM scripts
            WHERE NOT EXISTS (
              SELECT 1 FROM cloud_script_sync_state
              WHERE cloud_script_sync_state.script_id = scripts.id
            )
            """)
        defer { sqlite3_finalize(scriptStatement) }
        bind(CloudOwnershipIdentity.quarantined.uuidString, at: 1, in: scriptStatement)
        try stepDone(scriptStatement, db: db)

        let folderStatement = try prepare(db, """
            INSERT INTO cloud_folder_sync_state(account_id,folder_id,has_synced)
            SELECT ?,folders.id,0
            FROM folders
            WHERE NOT EXISTS (
              SELECT 1 FROM cloud_folder_sync_state
              WHERE cloud_folder_sync_state.folder_id = folders.id
            )
            """)
        defer { sqlite3_finalize(folderStatement) }
        bind(CloudOwnershipIdentity.quarantined.uuidString, at: 1, in: folderStatement)
        try stepDone(folderStatement, db: db)
    }

    private func loadScripts(_ db: OpaquePointer) throws -> [ScriptDocument] {
        let statement = try prepare(db, """
            SELECT id,title,body,source,folder_id,tags,outline,last_opened,created,updated
            FROM scripts ORDER BY updated DESC
            """)
        defer { sqlite3_finalize(statement) }
        var scripts: [ScriptDocument] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return scripts }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let idText = text(statement, 0), let id = UUID(uuidString: idText),
                  let title = text(statement, 1),
                  let body = text(statement, 2),
                  let sourceText = text(statement, 3),
                  let source = ScriptSource(rawValue: sourceText),
                  let tagsData = blob(statement, 5),
                  let outlineData = blob(statement, 6),
                  isNumber(statement, 8),
                  isNumber(statement, 9) else {
                throw DatabaseError.invalidData("a saved script record is incomplete")
            }
            let folderID: UUID?
            if let folderText = text(statement, 4) {
                guard let parsedFolderID = UUID(uuidString: folderText) else {
                    throw DatabaseError.invalidData("a script has an invalid folder reference")
                }
                folderID = parsedFolderID
            } else {
                folderID = nil
            }
            let tags: [String]
            let outline: [OutlinePoint]
            do {
                tags = try decoder.decode([String].self, from: tagsData)
                outline = try decoder.decode([OutlinePoint].self, from: outlineData)
            } catch {
                throw DatabaseError.invalidData("a script's tags or outline could not be decoded")
            }
            guard sqlite3_column_type(statement, 7) == SQLITE_NULL || isNumber(statement, 7) else {
                throw DatabaseError.invalidData("a script has an invalid last-opened date")
            }
            let lastOpened = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            scripts.append(ScriptDocument(
                id: id,
                title: title,
                body: body,
                source: source,
                folderID: folderID,
                tags: tags,
                outline: outline,
                lastOpenedAt: lastOpened,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            ))
        }
    }

    private func loadFolders(_ db: OpaquePointer) throws -> [ScriptFolder] {
        let statement = try prepare(db, "SELECT id,name,created FROM folders ORDER BY name COLLATE NOCASE")
        defer { sqlite3_finalize(statement) }
        var folders: [ScriptFolder] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return folders }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let idText = text(statement, 0),
                  let id = UUID(uuidString: idText),
                  let name = text(statement, 1),
                  isNumber(statement, 2) else {
                throw DatabaseError.invalidData("a saved folder record is incomplete")
            }
            folders.append(ScriptFolder(
                id: id,
                name: name,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
    }

    private func upsert(_ script: ScriptDocument, db: OpaquePointer) throws {
        let statement = try prepare(db, """
            INSERT INTO scripts(id,title,body,source,folder_id,tags,outline,last_opened,created,updated)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              title=excluded.title,body=excluded.body,source=excluded.source,
              folder_id=excluded.folder_id,tags=excluded.tags,outline=excluded.outline,
              last_opened=excluded.last_opened,updated=excluded.updated
            """)
        defer { sqlite3_finalize(statement) }
        bind(script.id.uuidString, at: 1, in: statement)
        bind(script.title, at: 2, in: statement)
        bind(script.body, at: 3, in: statement)
        bind(script.source.rawValue, at: 4, in: statement)
        bindOptional(script.folderID?.uuidString, at: 5, in: statement)
        bind(try encoder.encode(script.tags), at: 6, in: statement)
        bind(try encoder.encode(script.outline), at: 7, in: statement)
        if let lastOpenedAt = script.lastOpenedAt {
            sqlite3_bind_double(statement, 8, lastOpenedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_double(statement, 9, script.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 10, script.updatedAt.timeIntervalSince1970)
        try stepDone(statement, db: db)
        try deleteTombstone(scriptID: script.id, db: db)
    }

    private func replaceLibrary(with snapshot: LibrarySnapshot, db: OpaquePointer) throws {
        try execute(db, "DELETE FROM scripts")
        try execute(db, "DELETE FROM folders")
        for script in snapshot.scripts { try upsert(script, db: db) }
        try saveFolders(snapshot.folders, db: db)
        try setMeta(db, key: LibrarySchema.settingsMetadataKey, data: try encoder.encode(snapshot.settings))
        try setMeta(db, key: LibrarySchema.seededMetadataKey, data: Data(snapshot.seeded ? "1".utf8 : "0".utf8))
    }

    private func loadCloudSyncState(
        accountID: UUID,
        mutationRevision: UInt64,
        db: OpaquePointer
    ) throws -> CloudLocalSyncState {
        var currentAccountRecords: [UUID: CloudScriptSyncRecord] = [:]
        let currentStatement = try prepare(db, """
            SELECT script_id,last_synced_updated,last_synced_fingerprint
            FROM cloud_script_sync_state
            WHERE account_id = ?
            """)
        defer { sqlite3_finalize(currentStatement) }
        bind(accountID.uuidString, at: 1, in: currentStatement)
        while true {
            let result = sqlite3_step(currentStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let scriptIDText = text(currentStatement, 0),
                  let scriptID = UUID(uuidString: scriptIDText),
                  sqlite3_column_type(currentStatement, 1) == SQLITE_NULL
                    || isNumber(currentStatement, 1) else {
                throw DatabaseError.invalidData("a cloud sync record is incomplete")
            }
            let lastSyncedUpdatedAt = sqlite3_column_type(currentStatement, 1) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(currentStatement, 1))
            let lastSyncedFingerprint = text(currentStatement, 2)
            currentAccountRecords[scriptID] = CloudScriptSyncRecord(
                accountID: accountID,
                scriptID: scriptID,
                lastSyncedUpdatedAt: lastSyncedUpdatedAt,
                lastSyncedFingerprint: lastSyncedFingerprint
            )
        }

        var scriptIDsOwnedByOtherAccounts: Set<UUID> = []
        let otherStatement = try prepare(db, """
            SELECT DISTINCT script_id
            FROM cloud_script_sync_state
            WHERE account_id <> ?
            """)
        defer { sqlite3_finalize(otherStatement) }
        bind(accountID.uuidString, at: 1, in: otherStatement)
        while true {
            let result = sqlite3_step(otherStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let scriptIDText = text(otherStatement, 0),
                  let scriptID = UUID(uuidString: scriptIDText) else {
                throw DatabaseError.invalidData("a cloud ownership record has an invalid script ID")
            }
            scriptIDsOwnedByOtherAccounts.insert(scriptID)
        }

        var currentAccountFolderRecords: [UUID: CloudFolderSyncRecord] = [:]
        let currentFolderStatement = try prepare(db, """
            SELECT folder_id,has_synced,last_synced_name,last_synced_created
            FROM cloud_folder_sync_state
            WHERE account_id = ?
            """)
        defer { sqlite3_finalize(currentFolderStatement) }
        bind(accountID.uuidString, at: 1, in: currentFolderStatement)
        while true {
            let result = sqlite3_step(currentFolderStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let folderIDText = text(currentFolderStatement, 0),
                  let folderID = UUID(uuidString: folderIDText),
                  sqlite3_column_type(currentFolderStatement, 1) == SQLITE_INTEGER,
                  [Int64(0), Int64(1)].contains(sqlite3_column_int64(currentFolderStatement, 1)),
                  sqlite3_column_type(currentFolderStatement, 2) == SQLITE_NULL
                    || sqlite3_column_type(currentFolderStatement, 2) == SQLITE_TEXT,
                  sqlite3_column_type(currentFolderStatement, 3) == SQLITE_NULL
                    || isNumber(currentFolderStatement, 3) else {
                throw DatabaseError.invalidData("a cloud folder record has an invalid folder ID")
            }
            let baselineName = text(currentFolderStatement, 2)
            let baselineCreatedAt = sqlite3_column_type(currentFolderStatement, 3) == SQLITE_NULL
                ? nil
                : Date(
                    timeIntervalSince1970: sqlite3_column_double(currentFolderStatement, 3)
                )
            guard (baselineName == nil) == (baselineCreatedAt == nil) else {
                throw DatabaseError.invalidData("a cloud folder baseline is incomplete")
            }
            currentAccountFolderRecords[folderID] = CloudFolderSyncRecord(
                accountID: accountID,
                folderID: folderID,
                hasSynced: sqlite3_column_int64(currentFolderStatement, 1) == 1,
                lastSyncedName: baselineName,
                lastSyncedCreatedAt: baselineCreatedAt
            )
        }

        var folderIDsOwnedByOtherAccounts: Set<UUID> = []
        let otherFolderStatement = try prepare(db, """
            SELECT DISTINCT folder_id
            FROM cloud_folder_sync_state
            WHERE account_id <> ?
            """)
        defer { sqlite3_finalize(otherFolderStatement) }
        bind(accountID.uuidString, at: 1, in: otherFolderStatement)
        while true {
            let result = sqlite3_step(otherFolderStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let folderIDText = text(otherFolderStatement, 0),
                  let folderID = UUID(uuidString: folderIDText) else {
                throw DatabaseError.invalidData("a cloud folder ownership record has an invalid folder ID")
            }
            folderIDsOwnedByOtherAccounts.insert(folderID)
        }

        var tombstonesByScriptID: [UUID: ScriptDeletionTombstone] = [:]
        let tombstoneStatement = try prepare(db, "SELECT script_id,deleted FROM script_deletion_tombstones")
        defer { sqlite3_finalize(tombstoneStatement) }
        while true {
            let result = sqlite3_step(tombstoneStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let scriptIDText = text(tombstoneStatement, 0),
                  let scriptID = UUID(uuidString: scriptIDText),
                  isNumber(tombstoneStatement, 1) else {
                throw DatabaseError.invalidData("a deletion marker is incomplete")
            }
            tombstonesByScriptID[scriptID] = ScriptDeletionTombstone(
                scriptID: scriptID,
                deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(tombstoneStatement, 1))
            )
        }

        var tombstonesByFolderID: [UUID: FolderDeletionTombstone] = [:]
        let folderTombstoneStatement = try prepare(
            db,
            "SELECT folder_id,deleted FROM folder_deletion_tombstones"
        )
        defer { sqlite3_finalize(folderTombstoneStatement) }
        while true {
            let result = sqlite3_step(folderTombstoneStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.read(message(db)) }
            guard let folderIDText = text(folderTombstoneStatement, 0),
                  let folderID = UUID(uuidString: folderIDText),
                  isNumber(folderTombstoneStatement, 1) else {
                throw DatabaseError.invalidData("a folder deletion marker is incomplete")
            }
            tombstonesByFolderID[folderID] = FolderDeletionTombstone(
                folderID: folderID,
                deletedAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(folderTombstoneStatement, 1)
                )
            )
        }

        return CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: currentAccountRecords,
            scriptIDsOwnedByOtherAccounts: scriptIDsOwnedByOtherAccounts,
            currentAccountFolderRecords: currentAccountFolderRecords,
            folderIDsOwnedByOtherAccounts: folderIDsOwnedByOtherAccounts,
            tombstonesByScriptID: tombstonesByScriptID,
            tombstonesByFolderID: tombstonesByFolderID,
            mutationRevision: mutationRevision
        )
    }

    private func recordMutation() {
        mutationRevision &+= 1
    }

    private func upsertCloudSyncRecord(
        _ record: CloudScriptSyncRecord,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(db, """
            INSERT INTO cloud_script_sync_state(
              account_id,script_id,last_synced_updated,last_synced_fingerprint
            )
            SELECT ?,?,?,?
            WHERE NOT EXISTS (
              SELECT 1 FROM cloud_script_sync_state
              WHERE script_id = ? AND account_id <> ?
            )
            ON CONFLICT(account_id,script_id) DO UPDATE SET
              last_synced_updated=COALESCE(
                excluded.last_synced_updated,
                cloud_script_sync_state.last_synced_updated
              ),
              last_synced_fingerprint=COALESCE(
                excluded.last_synced_fingerprint,
                cloud_script_sync_state.last_synced_fingerprint
              )
            """)
        defer { sqlite3_finalize(statement) }
        bind(record.accountID.uuidString, at: 1, in: statement)
        bind(record.scriptID.uuidString, at: 2, in: statement)
        if let lastSyncedUpdatedAt = record.lastSyncedUpdatedAt {
            sqlite3_bind_double(statement, 3, lastSyncedUpdatedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        if let lastSyncedFingerprint = record.lastSyncedFingerprint {
            bind(lastSyncedFingerprint, at: 4, in: statement)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        bind(record.scriptID.uuidString, at: 5, in: statement)
        bind(record.accountID.uuidString, at: 6, in: statement)
        try stepDone(statement, db: db)
    }

    private func hasForeignCloudOwner(
        scriptID: UUID,
        accountID: UUID,
        db: OpaquePointer
    ) throws -> Bool {
        let statement = try prepare(db, """
            SELECT 1
            FROM cloud_script_sync_state
            WHERE script_id = ? AND account_id <> ?
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        bind(scriptID.uuidString, at: 1, in: statement)
        bind(accountID.uuidString, at: 2, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw DatabaseError.read(message(db))
        }
    }

    private func upsertCloudFolderSyncRecord(
        _ record: CloudFolderSyncRecord,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(db, """
            INSERT INTO cloud_folder_sync_state(
              account_id,folder_id,has_synced,last_synced_name,last_synced_created
            )
            SELECT ?,?,?,?,?
            WHERE NOT EXISTS (
              SELECT 1 FROM cloud_folder_sync_state
              WHERE folder_id = ? AND account_id <> ?
            )
            ON CONFLICT(account_id,folder_id) DO UPDATE SET
              has_synced=MAX(cloud_folder_sync_state.has_synced,excluded.has_synced),
              last_synced_name=CASE
                WHEN excluded.last_synced_name IS NOT NULL
                  AND excluded.last_synced_created IS NOT NULL
                THEN excluded.last_synced_name
                ELSE cloud_folder_sync_state.last_synced_name
              END,
              last_synced_created=CASE
                WHEN excluded.last_synced_name IS NOT NULL
                  AND excluded.last_synced_created IS NOT NULL
                THEN excluded.last_synced_created
                ELSE cloud_folder_sync_state.last_synced_created
              END
            """)
        defer { sqlite3_finalize(statement) }
        bind(record.accountID.uuidString, at: 1, in: statement)
        bind(record.folderID.uuidString, at: 2, in: statement)
        sqlite3_bind_int(statement, 3, record.hasSynced ? 1 : 0)
        bindOptional(record.lastSyncedName, at: 4, in: statement)
        if let lastSyncedCreatedAt = record.lastSyncedCreatedAt {
            sqlite3_bind_double(statement, 5, lastSyncedCreatedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bind(record.folderID.uuidString, at: 6, in: statement)
        bind(record.accountID.uuidString, at: 7, in: statement)
        try stepDone(statement, db: db)
    }

    private func upsertTombstone(
        _ tombstone: ScriptDeletionTombstone,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(db, """
            INSERT INTO script_deletion_tombstones(script_id,deleted)
            VALUES(?,?)
            ON CONFLICT(script_id) DO UPDATE SET
              deleted=MAX(script_deletion_tombstones.deleted,excluded.deleted)
            """)
        defer { sqlite3_finalize(statement) }
        bind(tombstone.scriptID.uuidString, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, tombstone.deletedAt.timeIntervalSince1970)
        try stepDone(statement, db: db)
    }

    private func deleteTombstone(scriptID: UUID, db: OpaquePointer) throws {
        let statement = try prepare(db, "DELETE FROM script_deletion_tombstones WHERE script_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(scriptID.uuidString, at: 1, in: statement)
        try stepDone(statement, db: db)
    }

    private func upsertFolderTombstone(
        _ tombstone: FolderDeletionTombstone,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(db, """
            INSERT INTO folder_deletion_tombstones(folder_id,deleted)
            VALUES(?,?)
            ON CONFLICT(folder_id) DO UPDATE SET
              deleted=MAX(folder_deletion_tombstones.deleted,excluded.deleted)
            """)
        defer { sqlite3_finalize(statement) }
        bind(tombstone.folderID.uuidString, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, tombstone.deletedAt.timeIntervalSince1970)
        try stepDone(statement, db: db)
    }

    private func deleteFolderTombstone(folderID: UUID, db: OpaquePointer) throws {
        let statement = try prepare(
            db,
            "DELETE FROM folder_deletion_tombstones WHERE folder_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(folderID.uuidString, at: 1, in: statement)
        try stepDone(statement, db: db)
    }

    private func saveFolders(_ folders: [ScriptFolder], db: OpaquePointer) throws {
        for folder in folders {
            let statement = try prepare(db, "INSERT INTO folders(id,name,created) VALUES(?,?,?)")
            defer { sqlite3_finalize(statement) }
            bind(folder.id.uuidString, at: 1, in: statement)
            bind(folder.name, at: 2, in: statement)
            sqlite3_bind_double(statement, 3, folder.createdAt.timeIntervalSince1970)
            try stepDone(statement, db: db)
            try deleteFolderTombstone(folderID: folder.id, db: db)
        }
    }

    private func meta(_ db: OpaquePointer, key: String) throws -> Data? {
        let statement = try prepare(db, "SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            guard let value = blob(statement, 0) else {
                throw DatabaseError.invalidData("metadata \(key) is empty")
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.read(message(db))
            }
            return value
        default:
            throw DatabaseError.read(message(db))
        }
    }

    private func setMeta(_ db: OpaquePointer, key: String, data: Data) throws {
        let statement = try prepare(db, """
            INSERT INTO metadata(key,value) VALUES(?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(data, at: 2, in: statement)
        try stepDone(statement, db: db)
    }

    private func cloudScriptStateColumns(_ db: OpaquePointer) throws -> Set<String> {
        try tableColumns("cloud_script_sync_state", db: db, label: "script")
    }

    private func cloudFolderStateColumns(_ db: OpaquePointer) throws -> Set<String> {
        try tableColumns("cloud_folder_sync_state", db: db, label: "folder")
    }

    private func tableColumns(
        _ table: String,
        db: OpaquePointer,
        label: String
    ) throws -> Set<String> {
        let statement = try prepare(db, "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return columns
            case SQLITE_ROW:
                guard let name = text(statement, 1) else {
                    throw DatabaseError.invalidData("the cloud \(label) schema is incomplete")
                }
                columns.insert(name)
            default:
                throw DatabaseError.read(message(db))
            }
        }
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.execute(message(db))
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepare(message(db))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute(message(db)) }
    }

    private func message(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func isNumber(_ statement: OpaquePointer, _ column: Int32) -> Bool {
        let type = sqlite3_column_type(statement, column)
        return type == SQLITE_INTEGER || type == SQLITE_FLOAT
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    private func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        if let value { bind(value, at: index, in: statement) } else { sqlite3_bind_null(statement, index) }
    }
    private func bind(_ value: Data, at index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}
