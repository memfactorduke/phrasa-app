import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// JSON library store retained only as a focused test double and migration
/// fixture. The shipping app uses `SQLitePersistenceClient` exclusively so
/// editing one script never rewrites every script body in the library.
/// Do not construct this type from production UI or app launch paths.
public actor PersistenceClient: LibraryPersistence {
    public enum PersistenceError: LocalizedError {
        case unreadableData
        case unreadableDataWithoutRecovery

        public var errorDescription: String? {
            switch self {
            case .unreadableData: "Phrasa could not read the saved library. A recovery copy was preserved."
            case .unreadableDataWithoutRecovery:
                "Phrasa could not read the saved library or create a recovery copy. Do not remove the app; try again or contact support."
            }
        }
    }

    private static let currentOwnershipSchemaVersion = 1

    private struct PersistedLibrary: Codable {
        var snapshot: LibrarySnapshot
        var syncRecords: [CloudScriptSyncRecord]
        var folderSyncRecords: [CloudFolderSyncRecord]
        var deletionTombstones: [ScriptDeletionTombstone]
        var folderDeletionTombstones: [FolderDeletionTombstone]
        var ownershipSchemaVersion: Int

        init(
            snapshot: LibrarySnapshot,
            syncRecords: [CloudScriptSyncRecord],
            folderSyncRecords: [CloudFolderSyncRecord] = [],
            deletionTombstones: [ScriptDeletionTombstone],
            folderDeletionTombstones: [FolderDeletionTombstone] = [],
            ownershipSchemaVersion: Int = PersistenceClient.currentOwnershipSchemaVersion
        ) {
            self.snapshot = snapshot
            self.syncRecords = syncRecords
            self.folderSyncRecords = folderSyncRecords
            self.deletionTombstones = deletionTombstones
            self.folderDeletionTombstones = folderDeletionTombstones
            self.ownershipSchemaVersion = ownershipSchemaVersion
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            snapshot = try values.decode(LibrarySnapshot.self, forKey: .snapshot)
            syncRecords = try values.decodeIfPresent(
                [CloudScriptSyncRecord].self,
                forKey: .syncRecords
            ) ?? []
            folderSyncRecords = try values.decodeIfPresent(
                [CloudFolderSyncRecord].self,
                forKey: .folderSyncRecords
            ) ?? []
            deletionTombstones = try values.decodeIfPresent(
                [ScriptDeletionTombstone].self,
                forKey: .deletionTombstones
            ) ?? []
            folderDeletionTombstones = try values.decodeIfPresent(
                [FolderDeletionTombstone].self,
                forKey: .folderDeletionTombstones
            ) ?? []
            ownershipSchemaVersion = try values.decodeIfPresent(
                Int.self,
                forKey: .ownershipSchemaVersion
            ) ?? 0
        }

        static let empty = PersistedLibrary(
            snapshot: .empty,
            syncRecords: [],
            folderSyncRecords: [],
            deletionTombstones: [],
            folderDeletionTombstones: []
        )
    }

    private let fileURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var mutationRevision: UInt64 = 0

    public init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = fileURL ?? base.appendingPathComponent("Phrasa", isDirectory: true)
            .appendingPathComponent("library.json")
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let timestamp = try value.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fractional.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = fractional.date(from: timestamp) { return date }
            let legacy = ISO8601DateFormatter()
            legacy.formatOptions = [.withInternetDateTime]
            legacy.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = legacy.date(from: timestamp) { return date }
            throw DecodingError.dataCorruptedError(
                in: value,
                debugDescription: "The saved timestamp is invalid."
            )
        }
        encoder = JSONEncoder()
        // Numeric instants preserve the exact folder baseline and remain
        // backward compatible through the dual-format decoder above.
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() async throws -> LibrarySnapshot {
        try readPersisted().snapshot
    }

    public func replace(with snapshot: LibrarySnapshot) async throws {
        var persisted = try readPersisted()
        persisted.snapshot = snapshot
        let restoredIDs = Set(snapshot.scripts.map(\.id))
        persisted.deletionTombstones.removeAll { restoredIDs.contains($0.scriptID) }
        let restoredFolderIDs = Set(snapshot.folders.map(\.id))
        persisted.folderDeletionTombstones.removeAll {
            restoredFolderIDs.contains($0.folderID)
        }
        // `replace` is the bulk import/restore boundary. Content with no known
        // owner is quarantined instead of being assigned to whichever account
        // happens to press Sync first.
        Self.quarantineUnownedContent(in: &persisted)
        try write(persisted)
        recordMutation()
    }

    public func upsert(_ script: ScriptDocument) async throws {
        var persisted = try readPersisted()
        if let index = persisted.snapshot.scripts.firstIndex(where: { $0.id == script.id }) {
            persisted.snapshot.scripts[index] = script
        } else {
            persisted.snapshot.scripts.append(script)
        }
        persisted.deletionTombstones.removeAll { $0.scriptID == script.id }
        try write(persisted)
        recordMutation()
    }

    public func upsertCloudConflict(_ script: ScriptDocument, accountID: UUID) async throws {
        var persisted = try readPersisted()
        if let index = persisted.snapshot.scripts.firstIndex(where: { $0.id == script.id }) {
            persisted.snapshot.scripts[index] = script
        } else {
            persisted.snapshot.scripts.append(script)
        }
        persisted.deletionTombstones.removeAll { $0.scriptID == script.id }
        guard !persisted.syncRecords.contains(where: {
            $0.scriptID == script.id && $0.accountID != accountID
        }) else {
            throw CloudSyncApplicationError.localLibraryChanged
        }
        if !persisted.syncRecords.contains(where: {
            $0.scriptID == script.id && $0.accountID == accountID
        }) {
            persisted.syncRecords.append(CloudScriptSyncRecord(
                accountID: accountID,
                scriptID: script.id,
                lastSyncedUpdatedAt: nil
            ))
        }
        try write(persisted)
        recordMutation()
    }

    public func deleteScript(id: UUID) async throws {
        var persisted = try readPersisted()
        persisted.snapshot.scripts.removeAll { $0.id == id }
        let tombstone = ScriptDeletionTombstone(scriptID: id, deletedAt: .now)
        if let index = persisted.deletionTombstones.firstIndex(where: { $0.scriptID == id }) {
            if tombstone.deletedAt > persisted.deletionTombstones[index].deletedAt {
                persisted.deletionTombstones[index] = tombstone
            }
        } else {
            persisted.deletionTombstones.append(tombstone)
        }
        try write(persisted)
        recordMutation()
    }

    public func deleteFolder(id: UUID, updatedScripts: [ScriptDocument]) async throws {
        var persisted = try readPersisted()
        persisted.snapshot.folders.removeAll { $0.id == id }
        for script in updatedScripts {
            if let index = persisted.snapshot.scripts.firstIndex(where: { $0.id == script.id }) {
                persisted.snapshot.scripts[index] = script
            }
        }
        let tombstone = FolderDeletionTombstone(folderID: id, deletedAt: .now)
        if let index = persisted.folderDeletionTombstones.firstIndex(where: {
            $0.folderID == id
        }) {
            if tombstone.deletedAt > persisted.folderDeletionTombstones[index].deletedAt {
                persisted.folderDeletionTombstones[index] = tombstone
            }
        } else {
            persisted.folderDeletionTombstones.append(tombstone)
        }
        try write(persisted)
        recordMutation()
    }

    public func saveSettings(_ settings: ReaderSettings, seeded: Bool) async throws {
        var persisted = try readPersisted()
        persisted.snapshot.settings = settings
        persisted.snapshot.seeded = seeded
        try write(persisted)
        recordMutation()
    }

    public func saveFolders(_ folders: [ScriptFolder]) async throws {
        var persisted = try readPersisted()
        persisted.snapshot.folders = folders
        let restoredIDs = Set(folders.map(\.id))
        persisted.folderDeletionTombstones.removeAll { restoredIDs.contains($0.folderID) }
        try write(persisted)
        recordMutation()
    }

    public func prepareCloudSync(
        accountID: UUID,
        localScriptIDs: Set<UUID>,
        localFolderIDs: Set<UUID>
    ) async throws -> CloudLocalSyncState {
        var persisted = try readPersisted()
        let ownedIDs = Set(persisted.syncRecords.map(\.scriptID))
        for scriptID in localScriptIDs.subtracting(ownedIDs) {
            persisted.syncRecords.append(CloudScriptSyncRecord(
                accountID: accountID,
                scriptID: scriptID,
                lastSyncedUpdatedAt: nil
            ))
        }
        let ownedFolderIDs = Set(persisted.folderSyncRecords.map(\.folderID))
        for folderID in localFolderIDs.subtracting(ownedFolderIDs) {
            persisted.folderSyncRecords.append(CloudFolderSyncRecord(
                accountID: accountID,
                folderID: folderID,
                hasSynced: false
            ))
        }
        try write(persisted)
        recordMutation()
        return Self.syncState(
            from: persisted,
            accountID: accountID,
            mutationRevision: mutationRevision
        )
    }

    public func applyCloudSync(
        snapshot: LibrarySnapshot,
        update: CloudSyncPersistenceUpdate
    ) async throws {
        guard update.expectedMutationRevision == mutationRevision else {
            throw CloudSyncApplicationError.localLibraryChanged
        }
        var persisted = try readPersisted()
        persisted.snapshot = snapshot

        for record in update.records where record.accountID == update.accountID {
            if let index = persisted.syncRecords.firstIndex(where: {
                $0.accountID == record.accountID && $0.scriptID == record.scriptID
            }) {
                let existing = persisted.syncRecords[index]
                persisted.syncRecords[index] = CloudScriptSyncRecord(
                    accountID: record.accountID,
                    scriptID: record.scriptID,
                    lastSyncedUpdatedAt: record.lastSyncedUpdatedAt
                        ?? existing.lastSyncedUpdatedAt,
                    lastSyncedFingerprint: record.lastSyncedFingerprint
                        ?? existing.lastSyncedFingerprint
                )
            } else if !persisted.syncRecords.contains(where: { $0.scriptID == record.scriptID }) {
                persisted.syncRecords.append(record)
            }
        }
        for record in update.folderRecords where record.accountID == update.accountID {
            if let index = persisted.folderSyncRecords.firstIndex(where: {
                $0.accountID == record.accountID && $0.folderID == record.folderID
            }) {
                let existing = persisted.folderSyncRecords[index]
                let baseline = record.lastSyncedFolder ?? existing.lastSyncedFolder
                persisted.folderSyncRecords[index] = CloudFolderSyncRecord(
                    accountID: record.accountID,
                    folderID: record.folderID,
                    hasSynced: existing.hasSynced || record.hasSynced,
                    lastSyncedName: baseline?.name,
                    lastSyncedCreatedAt: baseline?.createdAt
                )
            } else if !persisted.folderSyncRecords.contains(where: { $0.folderID == record.folderID }) {
                persisted.folderSyncRecords.append(record)
            }
        }

        let restoredIDs = Set(snapshot.scripts.map(\.id)).union(update.clearedTombstoneIDs)
        persisted.deletionTombstones.removeAll { restoredIDs.contains($0.scriptID) }
        for tombstone in update.tombstones {
            if let index = persisted.deletionTombstones.firstIndex(where: {
                $0.scriptID == tombstone.scriptID
            }) {
                if tombstone.deletedAt > persisted.deletionTombstones[index].deletedAt {
                    persisted.deletionTombstones[index] = tombstone
                }
            } else {
                persisted.deletionTombstones.append(tombstone)
            }
        }

        let restoredFolderIDs = Set(snapshot.folders.map(\.id))
            .union(update.clearedFolderTombstoneIDs)
        persisted.folderDeletionTombstones.removeAll {
            restoredFolderIDs.contains($0.folderID)
        }
        for tombstone in update.folderTombstones {
            if let index = persisted.folderDeletionTombstones.firstIndex(where: {
                $0.folderID == tombstone.folderID
            }) {
                if tombstone.deletedAt > persisted.folderDeletionTombstones[index].deletedAt {
                    persisted.folderDeletionTombstones[index] = tombstone
                }
            } else {
                persisted.folderDeletionTombstones.append(tombstone)
            }
        }
        try write(persisted)
        recordMutation()
    }

    private func readPersisted() throws -> PersistedLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: fileURL)
            if var persisted = try? decoder.decode(PersistedLibrary.self, from: data) {
                if persisted.ownershipSchemaVersion < Self.currentOwnershipSchemaVersion {
                    Self.quarantineUnownedContent(in: &persisted)
                    persisted.ownershipSchemaVersion = Self.currentOwnershipSchemaVersion
                    try write(persisted)
                }
                return persisted
            }
            // Snapshot-only files predate account provenance. Persist a stable
            // local-only owner before returning so a later account can never
            // claim this existing library implicitly.
            var persisted = PersistedLibrary(
                snapshot: try decoder.decode(LibrarySnapshot.self, from: data),
                syncRecords: [],
                folderSyncRecords: [],
                deletionTombstones: [],
                folderDeletionTombstones: []
            )
            Self.quarantineUnownedContent(in: &persisted)
            try write(persisted)
            return persisted
        } catch {
            let recoveryURL = fileURL.deletingPathExtension()
                .appendingPathExtension(
                    "recovery-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString).json"
                )
            do {
                try FileManager.default.copyItem(at: fileURL, to: recoveryURL)
            } catch {
                throw PersistenceError.unreadableDataWithoutRecovery
            }
            throw PersistenceError.unreadableData
        }
    }

    private func write(_ persisted: PersistedLibrary) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(persisted).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func recordMutation() {
        mutationRevision &+= 1
    }

    private static func quarantineUnownedContent(in persisted: inout PersistedLibrary) {
        var ownedScriptIDs = Set(persisted.syncRecords.map(\.scriptID))
        for script in persisted.snapshot.scripts where ownedScriptIDs.insert(script.id).inserted {
            persisted.syncRecords.append(CloudScriptSyncRecord(
                accountID: CloudOwnershipIdentity.quarantined,
                scriptID: script.id,
                lastSyncedUpdatedAt: nil
            ))
        }

        var ownedFolderIDs = Set(persisted.folderSyncRecords.map(\.folderID))
        for folder in persisted.snapshot.folders where ownedFolderIDs.insert(folder.id).inserted {
            persisted.folderSyncRecords.append(CloudFolderSyncRecord(
                accountID: CloudOwnershipIdentity.quarantined,
                folderID: folder.id,
                hasSynced: false
            ))
        }
    }

    private static func syncState(
        from persisted: PersistedLibrary,
        accountID: UUID,
        mutationRevision: UInt64
    ) -> CloudLocalSyncState {
        let currentRecords = persisted.syncRecords
            .filter { $0.accountID == accountID }
        return CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: Dictionary(
                currentRecords.map { ($0.scriptID, $0) },
                uniquingKeysWith: { _, latest in latest }
            ),
            scriptIDsOwnedByOtherAccounts: Set(
                persisted.syncRecords.lazy
                    .filter { $0.accountID != accountID }
                    .map(\.scriptID)
            ),
            currentAccountFolderRecords: Dictionary(
                persisted.folderSyncRecords.lazy
                    .filter { $0.accountID == accountID }
                    .map { ($0.folderID, $0) },
                uniquingKeysWith: { _, latest in latest }
            ),
            folderIDsOwnedByOtherAccounts: Set(
                persisted.folderSyncRecords.lazy
                    .filter { $0.accountID != accountID }
                    .map(\.folderID)
            ),
            tombstonesByScriptID: Dictionary(
                persisted.deletionTombstones.map { ($0.scriptID, $0) },
                uniquingKeysWith: { older, newer in
                    older.deletedAt >= newer.deletedAt ? older : newer
                }
            ),
            tombstonesByFolderID: Dictionary(
                persisted.folderDeletionTombstones.map { ($0.folderID, $0) },
                uniquingKeysWith: { older, newer in
                    older.deletedAt >= newer.deletedAt ? older : newer
                }
            ),
            mutationRevision: mutationRevision
        )
    }
}
