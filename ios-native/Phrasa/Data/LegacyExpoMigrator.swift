import Foundation
import SQLite3

/// One-time importer for the Expo SQLite key/value store used by the existing
/// `com.phrasa.app` build. Keeping the same bundle identifier means a native
/// upgrade can preserve scripts already stored on the device.
struct LegacyExpoMigrator: Sendable {
    enum MigrationError: LocalizedError, Equatable {
        case open(String)
        case read(String)
        case invalidData(String)

        var errorDescription: String? {
            switch self {
            case .open(let message), .read(let message):
                return "Phrasa found an earlier library but could not read it. Nothing was replaced, so you can try again. \(message)"
            case .invalidData(let key):
                return "Phrasa found an earlier library, but its \(key) data is damaged. Nothing was replaced, so you can try again."
            }
        }
    }

    enum RecoveryError: LocalizedError, Equatable {
        case missingDatabase
        case moveFailed(String)
        case rollbackFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingDatabase:
                "Phrasa could not find the earlier library file, so nothing was reset."
            case .moveFailed(let detail):
                "Phrasa could not preserve the earlier library. The original files were put back: \(detail)"
            case .rollbackFailed(let detail):
                "Phrasa could not preserve the earlier library or fully put its files back: \(detail)"
            }
        }
    }

    private let databaseURL: URL
    private let recoveryMoveItem: @Sendable (URL, URL) throws -> Void

    init(
        databaseURL: URL? = nil,
        recoveryMoveItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.databaseURL = databaseURL ?? documents
            .appendingPathComponent("SQLite", isDirectory: true)
            .appendingPathComponent("ExpoSQLiteStorage")
        self.recoveryMoveItem = recoveryMoveItem
    }

    func canRecoverLibrary(after error: Error) -> Bool {
        error is MigrationError
    }

    /// Moves the unreadable Expo database out of the migration path only after
    /// the user confirms Start fresh. The main file and SQLite sidecars stay
    /// together, and a failed move rolls every completed move back.
    func preserveUnreadableLibraryAndSkipMigration() throws -> URL {
        let fileManager = FileManager.default
        let sources = ["", "-wal", "-shm"]
            .map { URL(fileURLWithPath: databaseURL.path + $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard sources.contains(databaseURL) else {
            throw RecoveryError.missingDatabase
        }

        let recoveryRoot = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
        let recoveryDirectory = recoveryRoot.appendingPathComponent(
            "legacy-expo-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString)",
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
                throw RecoveryError.moveFailed(error.localizedDescription)
            }
            throw RecoveryError.rollbackFailed(
                rollbackFailure?.localizedDescription ?? error.localizedDescription
            )
        }
        return recoveryDirectory
    }

    func importIfPresent() throws -> LibrarySnapshot? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite returned error \(openResult)."
            if let database { sqlite3_close(database) }
            throw MigrationError.open(detail)
        }
        defer { sqlite3_close(database) }

        let folderData = try read(database, key: "autoprompt.folders.v1")
        let scriptData = try read(database, key: "autoprompt.scripts.v1")
        let settingsData = try read(database, key: "autoprompt.settings.v1")
        guard folderData != nil || scriptData != nil || settingsData != nil else { return nil }

        var folderIDs = LegacyIDMap()
        let folders = try decodeFolders(
            folderData,
            idMap: &folderIDs
        )
        var scriptIDs = LegacyIDMap()
        let scripts = try decodeScripts(
            scriptData,
            scriptIDs: &scriptIDs,
            folderIDs: &folderIDs
        )
        let settings = try decodeSettings(settingsData)
        return LibraryBackupNormalizer.normalized(
            LibrarySnapshot(
                scripts: scripts,
                folders: folders,
                settings: settings,
                seeded: true
            )
        )
    }

    private func read(_ database: OpaquePointer, key: String) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM storage WHERE key = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MigrationError.read(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(
            statement,
            1,
            key,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        ) == SQLITE_OK else {
            throw MigrationError.read(String(cString: sqlite3_errmsg(database)))
        }

        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else {
                throw MigrationError.invalidData(key)
            }
            let value = Data(String(cString: text).utf8)
            let terminalResult = sqlite3_step(statement)
            if terminalResult == SQLITE_ROW {
                throw MigrationError.invalidData("duplicate values for \(key)")
            }
            guard terminalResult == SQLITE_DONE else {
                throw MigrationError.read(String(cString: sqlite3_errmsg(database)))
            }
            return value
        default:
            throw MigrationError.read(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func decodeScripts(
        _ data: Data?,
        scriptIDs: inout LegacyIDMap,
        folderIDs: inout LegacyIDMap
    ) throws -> [ScriptDocument] {
        guard let data else { return [] }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MigrationError.invalidData("scripts")
        }
        return try objects.enumerated().map { index, object in
            let record = "script record \(index + 1)"
            guard let idString = object["id"] as? String, !idString.isEmpty else {
                throw MigrationError.invalidData(record)
            }
            let id = scriptIDs.idForRecord(idString)
            let title = try optionalString(object, key: "title", record: record)
                ?? "Untitled script"
            let body = try optionalString(object, key: "body", record: record) ?? ""
            let source = ScriptSource(rawValue: object["sourceType"] as? String ?? "") ?? .manual
            let folderID = (object["folderId"] as? String).map { folderIDs.idForReference($0) }
            let tags = (object["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
            let outline = decodeOutline(object["outline"])
            let created = try optionalDate(object, key: "createdAt", record: record) ?? .now
            let updated = try optionalDate(object, key: "updatedAt", record: record) ?? created
            return ScriptDocument(
                id: id,
                title: title,
                body: body,
                source: source,
                folderID: folderID,
                tags: tags,
                outline: outline,
                lastOpenedAt: try optionalDate(
                    object,
                    key: "lastOpenedAt",
                    record: record,
                    allowsNull: true
                ),
                createdAt: created,
                updatedAt: updated
            )
        }
    }

    private func decodeOutline(_ value: Any?) -> [OutlinePoint] {
        guard let objects = value as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = object["note"] as? String ?? ""
            guard !text.isEmpty
                    || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return OutlinePoint(id: id, text: text, note: note)
        }
    }

    private func decodeFolders(_ data: Data?, idMap: inout LegacyIDMap) throws -> [ScriptFolder] {
        guard let data else { return [] }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MigrationError.invalidData("folders")
        }
        return try objects.enumerated().map { index, object in
            let record = "folder record \(index + 1)"
            guard let idString = object["id"] as? String, !idString.isEmpty else {
                throw MigrationError.invalidData(record)
            }
            return ScriptFolder(
                id: idMap.idForRecord(idString),
                name: object["name"] as? String ?? "Untitled folder",
                createdAt: try optionalDate(object, key: "createdAt", record: record) ?? .now
            )
        }
    }

    private func decodeSettings(_ data: Data?) throws -> ReaderSettings {
        guard let data else { return ReaderSettings() }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.invalidData("reader settings")
        }
        var settings = ReaderSettings()
        if let raw = value["mode"] as? String { settings.mode = ReaderMode(rawValue: raw) ?? settings.mode }
        if let raw = value["scrollStyle"] as? String { settings.scrollStyle = ScrollStyle(rawValue: raw) ?? settings.scrollStyle }
        if let raw = value["fontFamily"] as? String { settings.font = ReadingFont(rawValue: raw) ?? settings.font }
        if let raw = value["theme"] as? String { settings.theme = ReaderTheme(rawValue: raw) ?? settings.theme }
        if let raw = value["align"] as? String { settings.alignment = raw == "center" ? .center : .leading }
        settings.fontSize = number(value["fontSize"]) ?? settings.fontSize
        settings.lineHeight = number(value["lineHeight"]) ?? settings.lineHeight
        settings.horizontalMargin = (number(value["marginX"]) ?? settings.horizontalMargin * 100) / 100
        settings.focusPosition = number(value["focusPosition"]) ?? settings.focusPosition
        settings.speedWPM = number(value["speedWpm"]) ?? settings.speedWPM
        settings.mirrorHorizontal = value["mirrorH"] as? Bool ?? settings.mirrorHorizontal
        settings.mirrorVertical = value["mirrorV"] as? Bool ?? settings.mirrorVertical
        settings.recognitionLanguage = value["recognitionLang"] as? String ?? settings.recognitionLanguage
        settings.showPacing = value["showPacing"] as? Bool ?? settings.showPacing
        settings.targetDuration = number(value["targetSec"])
        settings.normalize()
        return settings
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func optionalString(
        _ object: [String: Any],
        key: String,
        record: String
    ) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let value = value as? String else {
            throw MigrationError.invalidData("\(record) \(key)")
        }
        return value
    }

    private func optionalDate(
        _ object: [String: Any],
        key: String,
        record: String,
        allowsNull: Bool = false
    ) throws -> Date? {
        guard let value = object[key] else { return nil }
        if value is NSNull, allowsNull { return nil }
        guard let value = value as? String, let parsed = date(value) else {
            throw MigrationError.invalidData("\(record) \(key)")
        }
        return parsed
    }

    private func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct LegacyIDMap {
    private var canonicalIDs: [String: UUID] = [:]
    private var usedIDs: Set<UUID> = []

    /// The first record for a legacy identifier is canonical. Later duplicate
    /// records receive unique IDs so importing them cannot overwrite content or
    /// violate SQLite primary keys; references continue to target the first.
    mutating func idForRecord(_ legacyID: String) -> UUID {
        let key = canonicalKey(for: legacyID)
        guard canonicalIDs[key] == nil else { return unusedID() }
        let id = unusedID(preferred: UUID(uuidString: legacyID))
        canonicalIDs[key] = id
        return id
    }

    mutating func idForReference(_ legacyID: String) -> UUID {
        let key = canonicalKey(for: legacyID)
        if let id = canonicalIDs[key] { return id }
        let id = unusedID(preferred: UUID(uuidString: legacyID))
        canonicalIDs[key] = id
        return id
    }

    private func canonicalKey(for legacyID: String) -> String {
        UUID(uuidString: legacyID).map { "uuid:\($0.uuidString)" } ?? "legacy:\(legacyID)"
    }

    private mutating func unusedID(preferred: UUID? = nil) -> UUID {
        if let preferred, usedIDs.insert(preferred).inserted { return preferred }
        var generated = UUID()
        while !usedIDs.insert(generated).inserted { generated = UUID() }
        return generated
    }
}
