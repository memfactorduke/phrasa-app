import Foundation

/// Reserved local-only owner for content whose account provenance cannot be
/// established safely. Supabase-generated account IDs are random UUIDs, while
/// the all-zero UUID is never sent to the service or treated as a real account.
/// Keeping the sentinel in the same ownership tables makes every real account
/// see quarantined content as belonging to another identity.
public enum CloudOwnershipIdentity {
    public static let quarantined = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    ))
}

/// A durable record that a script was removed on this device. Reconciliation
/// compares cloud content with the exact last-sync fingerprint; the timestamp
/// orders repeated local deletion records and remains useful for diagnostics.
public struct ScriptDeletionTombstone: Codable, Equatable, Hashable, Sendable {
    public let scriptID: UUID
    public let deletedAt: Date

    public init(scriptID: UUID, deletedAt: Date) {
        self.scriptID = scriptID
        self.deletedAt = deletedAt
    }
}

/// A durable account-owned folder deletion. Folder reconciliation compares the
/// exact last-synced name and microsecond-normalized creation date rather than
/// relying on clocks from different devices.
public struct FolderDeletionTombstone: Codable, Equatable, Hashable, Sendable {
    public let folderID: UUID
    public let deletedAt: Date

    public init(folderID: UUID, deletedAt: Date) {
        self.folderID = folderID
        self.deletedAt = deletedAt
    }
}

/// Account-scoped ownership and last-sync provenance for one local script.
/// `lastSyncedFingerprint == nil` means the script has been durably claimed for
/// this account before its first upload, or was written by an older build that
/// did not retain an exact content baseline. Claiming before network I/O closes
/// the sign-out/account-switch window even when the upload later fails.
public struct CloudScriptSyncRecord: Codable, Equatable, Hashable, Sendable {
    public let accountID: UUID
    public let scriptID: UUID
    public let lastSyncedUpdatedAt: Date?
    public let lastSyncedFingerprint: String?

    public init(
        accountID: UUID,
        scriptID: UUID,
        lastSyncedUpdatedAt: Date?,
        lastSyncedFingerprint: String? = nil
    ) {
        self.accountID = accountID
        self.scriptID = scriptID
        self.lastSyncedUpdatedAt = lastSyncedUpdatedAt
        self.lastSyncedFingerprint = lastSyncedFingerprint
    }
}

/// Folder names can contain private project information, so they use the same
/// first-account ownership boundary as scripts. The optional baseline is the
/// exact folder version observed at the last successful sync. Older builds
/// stored only `hasSynced`; those records intentionally decode without a
/// baseline so absence is preserved rather than guessed to be a deletion.
public struct CloudFolderSyncRecord: Codable, Equatable, Hashable, Sendable {
    public let accountID: UUID
    public let folderID: UUID
    public let hasSynced: Bool
    public let lastSyncedName: String?
    public let lastSyncedCreatedAt: Date?

    public init(
        accountID: UUID,
        folderID: UUID,
        hasSynced: Bool,
        lastSyncedName: String? = nil,
        lastSyncedCreatedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.folderID = folderID
        self.hasSynced = hasSynced
        if let lastSyncedName, let lastSyncedCreatedAt {
            self.lastSyncedName = lastSyncedName
            self.lastSyncedCreatedAt = lastSyncedCreatedAt
        } else {
            self.lastSyncedName = nil
            self.lastSyncedCreatedAt = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, folderID, hasSynced, lastSyncedName, lastSyncedCreatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(UUID.self, forKey: .accountID)
        folderID = try values.decode(UUID.self, forKey: .folderID)
        // Compatibility with the ownership-only envelope written by builds
        // made before two-way folder deletion tracking was introduced.
        hasSynced = try values.decodeIfPresent(Bool.self, forKey: .hasSynced) ?? false
        let decodedName = try values.decodeIfPresent(String.self, forKey: .lastSyncedName)
        let decodedCreatedAt: Date?
        if let seconds = try? values.decode(Double.self, forKey: .lastSyncedCreatedAt) {
            decodedCreatedAt = Date(timeIntervalSince1970: seconds)
        } else {
            // Accept the ISO-8601 value emitted by any interim build that used
            // the surrounding encoder's normal Date strategy.
            decodedCreatedAt = try values.decodeIfPresent(
                Date.self,
                forKey: .lastSyncedCreatedAt
            )
        }
        // A partial baseline cannot prove identity. Treat it exactly like a
        // legacy record and preserve content until a complete sync establishes
        // a new baseline.
        if let decodedName, let decodedCreatedAt {
            lastSyncedName = decodedName
            lastSyncedCreatedAt = decodedCreatedAt
        } else {
            lastSyncedName = nil
            lastSyncedCreatedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(folderID, forKey: .folderID)
        try values.encode(hasSynced, forKey: .hasSynced)
        try values.encodeIfPresent(lastSyncedName, forKey: .lastSyncedName)
        // Store the baseline timestamp as a numeric instant so the JSON
        // compatibility store does not lose sub-second precision through its
        // legacy `.iso8601` Date strategy.
        try values.encodeIfPresent(
            lastSyncedCreatedAt?.timeIntervalSince1970,
            forKey: .lastSyncedCreatedAt
        )
    }

    public var lastSyncedFolder: ScriptFolder? {
        guard let lastSyncedName, let lastSyncedCreatedAt else { return nil }
        return ScriptFolder(id: folderID, name: lastSyncedName, createdAt: lastSyncedCreatedAt)
    }
}

public struct CloudLocalSyncState: Equatable, Sendable {
    public let accountID: UUID
    public let currentAccountRecords: [UUID: CloudScriptSyncRecord]
    public let scriptIDsOwnedByOtherAccounts: Set<UUID>
    public let currentAccountFolderRecords: [UUID: CloudFolderSyncRecord]
    public let folderIDsOwnedByOtherAccounts: Set<UUID>
    public let tombstonesByScriptID: [UUID: ScriptDeletionTombstone]
    public let tombstonesByFolderID: [UUID: FolderDeletionTombstone]
    /// In-memory generation of the persistence actor when this sync state was
    /// prepared. It detects any intervening local write before a merge commits.
    public let mutationRevision: UInt64

    public init(
        accountID: UUID,
        currentAccountRecords: [UUID: CloudScriptSyncRecord],
        scriptIDsOwnedByOtherAccounts: Set<UUID>,
        currentAccountFolderRecords: [UUID: CloudFolderSyncRecord],
        folderIDsOwnedByOtherAccounts: Set<UUID>,
        tombstonesByScriptID: [UUID: ScriptDeletionTombstone],
        tombstonesByFolderID: [UUID: FolderDeletionTombstone],
        mutationRevision: UInt64 = 0
    ) {
        self.accountID = accountID
        self.currentAccountRecords = currentAccountRecords
        self.scriptIDsOwnedByOtherAccounts = scriptIDsOwnedByOtherAccounts
        self.currentAccountFolderRecords = currentAccountFolderRecords
        self.folderIDsOwnedByOtherAccounts = folderIDsOwnedByOtherAccounts
        self.tombstonesByScriptID = tombstonesByScriptID
        self.tombstonesByFolderID = tombstonesByFolderID
        self.mutationRevision = mutationRevision
    }

    public static func empty(accountID: UUID) -> Self {
        Self(
            accountID: accountID,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
    }
}

public struct CloudSyncPersistenceUpdate: Equatable, Sendable {
    public let accountID: UUID
    public let records: [CloudScriptSyncRecord]
    public let folderRecords: [CloudFolderSyncRecord]
    public let tombstones: [ScriptDeletionTombstone]
    public let clearedTombstoneIDs: Set<UUID>
    public let folderTombstones: [FolderDeletionTombstone]
    public let clearedFolderTombstoneIDs: Set<UUID>
    /// Must match the persistence actor generation captured by
    /// `prepareCloudSync`; otherwise this merge was built from stale local data.
    public let expectedMutationRevision: UInt64

    public init(
        accountID: UUID,
        records: [CloudScriptSyncRecord],
        folderRecords: [CloudFolderSyncRecord],
        tombstones: [ScriptDeletionTombstone],
        clearedTombstoneIDs: Set<UUID>,
        folderTombstones: [FolderDeletionTombstone],
        clearedFolderTombstoneIDs: Set<UUID>,
        expectedMutationRevision: UInt64
    ) {
        self.accountID = accountID
        self.records = records
        self.folderRecords = folderRecords
        self.tombstones = tombstones
        self.clearedTombstoneIDs = clearedTombstoneIDs
        self.folderTombstones = folderTombstones
        self.clearedFolderTombstoneIDs = clearedFolderTombstoneIDs
        self.expectedMutationRevision = expectedMutationRevision
    }
}

public protocol LibraryPersistence: Sendable {
    func load() async throws -> LibrarySnapshot
    func replace(with snapshot: LibrarySnapshot) async throws
    func upsert(_ script: ScriptDocument) async throws
    /// Atomically saves a conflict copy and binds it to the account whose sync
    /// produced it, closing the sign-out/account-switch ownership window.
    func upsertCloudConflict(_ script: ScriptDocument, accountID: UUID) async throws
    func deleteScript(id: UUID) async throws
    func deleteFolder(id: UUID, updatedScripts: [ScriptDocument]) async throws
    func saveSettings(_ settings: ReaderSettings, seeded: Bool) async throws
    func saveFolders(_ folders: [ScriptFolder]) async throws

    /// Atomically claims previously unowned local scripts for `accountID` and
    /// returns all state needed to build a privacy-safe sync plan.
    func prepareCloudSync(
        accountID: UUID,
        localScriptIDs: Set<UUID>,
        localFolderIDs: Set<UUID>
    ) async throws -> CloudLocalSyncState

    /// Persists the merged library and its provenance/tombstone changes as one
    /// unit so account isolation cannot lag behind newly downloaded content.
    func applyCloudSync(
        snapshot: LibrarySnapshot,
        update: CloudSyncPersistenceUpdate
    ) async throws
}

public extension LibraryPersistence {
    func upsertCloudConflict(_ script: ScriptDocument, accountID: UUID) async throws {
        try await upsert(script)
        _ = try await prepareCloudSync(
            accountID: accountID,
            localScriptIDs: [script.id],
            localFolderIDs: []
        )
    }
}

/// Optional capability for stores that can preserve an unreadable library and
/// create a clean replacement. Ordinary test and compatibility stores do not
/// need to implement recovery merely to satisfy `LibraryPersistence`.
public protocol LibraryRecoveryPersistence: LibraryPersistence {
    nonisolated func canRecoverLibrary(after error: Error) -> Bool
    func preserveCorruptLibraryAndReset() async throws -> URL
}

public enum CloudSyncApplicationError: LocalizedError, Equatable, Sendable {
    case localLibraryChanged
    case localConflictCopyNeedsSaving

    public var errorDescription: String? {
        switch self {
        case .localLibraryChanged:
            "Your library changed while cloud sync was running, so Phrasa kept the newer device version instead of overwriting it. Sync again to merge those changes safely."
        case .localConflictCopyNeedsSaving:
            "Cloud changes were saved, but a protected copy of edits made during sync could not be saved on this device. Keep Phrasa open and sync again to save that visible copy safely."
        }
    }
}

public enum CloudSyncApplicationPolicy {
    public static func validate(
        base: LibrarySnapshot,
        current: LibrarySnapshot
    ) throws {
        guard base == current else {
            throw CloudSyncApplicationError.localLibraryChanged
        }
    }
}

/// Explicit library schema contract shared by SQLite migrations and recovery.
public enum LibrarySchema {
    /// Current on-disk schema version for the shipping SQLite store.
    public static let currentVersion = 1
    /// Metadata key written after successful schema bootstrap/migration.
    public static let versionMetadataKey = "library_schema_version"
    /// Ownership quarantine marker independent of table layout version.
    public static let ownershipSchemaKey = "cloud_ownership_schema"
    public static let currentOwnershipSchemaVersion = "1"
    public static let settingsMetadataKey = "settings"
    public static let seededMetadataKey = "seeded"

    /// Durability invariants the shipping store must uphold.
    public static let durabilityInvariants: [String] = [
        "SQLite is the only shipping library store",
        "WAL mode with foreign keys enabled",
        "Visible mutations commit before publish except staged editor drafts",
        "Corrupt libraries are preserved before reset",
        "JSON persistence is a test double only",
        "Stale cloud mutation revisions cannot apply",
        "Unowned bulk-restored rows are quarantined",
    ]
}
