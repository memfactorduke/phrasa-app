import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// Explicit user preference for reader-settings direction during one sync.
/// Library content (scripts/folders/outline) always uses three-way merge.
public enum CloudPreferenceResolution: String, CaseIterable, Identifiable, Sendable {
    /// Keep local reader settings and push them to cloud (legacy LWW path).
    case keepThisDevice
    /// Overwrite local reader settings from cloud when present.
    case restoreFromCloud
    /// Shipping default: reader settings stay on-device only — no settings
    /// push or restore. Script/folder edits remain the sync product.
    case localOnly

    public var id: Self { self }
}

public struct CloudSyncSummary: Equatable, Sendable {
    public let uploadedScripts: Int
    public let downloadedScripts: Int
    public let completedAt: Date
    public let excludedLocalScriptCount: Int
    public let excludedLocalFolderCount: Int

    public init(
        uploadedScripts: Int,
        downloadedScripts: Int,
        completedAt: Date,
        excludedLocalScriptCount: Int = 0,
        excludedLocalFolderCount: Int = 0
    ) {
        self.uploadedScripts = uploadedScripts
        self.downloadedScripts = downloadedScripts
        self.completedAt = completedAt
        self.excludedLocalScriptCount = excludedLocalScriptCount
        self.excludedLocalFolderCount = excludedLocalFolderCount
    }
}

public struct CloudSyncResult: Sendable {
    public let baseLibrary: LibrarySnapshot
    public let mergedLibrary: LibrarySnapshot
    public let summary: CloudSyncSummary
    public let persistenceUpdate: CloudSyncPersistenceUpdate

    public init(
        baseLibrary: LibrarySnapshot,
        mergedLibrary: LibrarySnapshot,
        summary: CloudSyncSummary,
        persistenceUpdate: CloudSyncPersistenceUpdate
    ) {
        self.baseLibrary = baseLibrary
        self.mergedLibrary = mergedLibrary
        self.summary = summary
        self.persistenceUpdate = persistenceUpdate
    }
}

/// Explicit count of local content that will not upload for the prepared
/// account — foreign-owned rows and durable pre-provenance / bulk-restore
/// quarantine. This is the safe “adoption required / device-only” signal;
/// hosts must never silently claim these IDs for the next signed-in account.
public struct CloudProtectedLocalContent: Equatable, Sendable {
    public let scriptCount: Int
    public let folderCount: Int

    public init(scriptCount: Int, folderCount: Int) {
        self.scriptCount = max(0, scriptCount)
        self.folderCount = max(0, folderCount)
    }

    public var isEmpty: Bool { scriptCount == 0 && folderCount == 0 }

    /// True when backup restore or pre-provenance migration left content that
    /// stays local-only until a deliberate product path (never first-account
    /// silent adoption) handles it.
    public var adoptionRequiredOrQuarantined: Bool { !isEmpty }
}

/// Prepared local library + ownership/tombstone state for one explicit sync.
public struct CloudSyncInput: Sendable {
    public let library: LibrarySnapshot
    public let state: CloudLocalSyncState

    public init(library: LibrarySnapshot, state: CloudLocalSyncState) {
        self.library = library
        self.state = state
    }

    /// Only count protected IDs that are still present in this snapshot. The
    /// durable ownership tables can retain records after local deletion.
    public var excludedLocalScriptCount: Int {
        let localIDs = Set(library.scripts.map(\.id))
        return localIDs.intersection(state.scriptIDsOwnedByOtherAccounts).count
    }

    public var excludedLocalFolderCount: Int {
        let localIDs = Set(library.folders.map(\.id))
        return localIDs.intersection(state.folderIDsOwnedByOtherAccounts).count
    }

    /// Explicit quarantine / foreign-owned surface after prepare. Empty means
    /// every present local script/folder is claimable or already owned by this
    /// account — never treat a non-empty value as silently adopted.
    public var protectedLocalContent: CloudProtectedLocalContent {
        CloudProtectedLocalContent(
            scriptCount: excludedLocalScriptCount,
            folderCount: excludedLocalFolderCount
        )
    }
}

public enum CloudSyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case succeeded(CloudSyncSummary)
    case failed(String)
    /// Explicit not-eligible outcome (e.g. dirty editor). Not a transport failure.
    case deferred(CloudSyncDeferredReason)
}

/// Generation-scoped token for one user-initiated synchronization.
/// Account IDs alone are insufficient after sign-out/re-sign-in.
public struct CloudSynchronizationToken: Equatable, Sendable {
    fileprivate let generation: UInt64
    public let accountID: UUID

    fileprivate init(generation: UInt64, accountID: UUID) {
        self.generation = generation
        self.accountID = accountID
    }
}

/// Identifies the one synchronization allowed to publish a terminal status.
public struct CloudSynchronizationLane: Sendable {
    private var nextGeneration: UInt64 = 0
    public private(set) var activeToken: CloudSynchronizationToken?

    public init() {}

    public mutating func begin(accountID: UUID) -> CloudSynchronizationToken {
        nextGeneration &+= 1
        let token = CloudSynchronizationToken(
            generation: nextGeneration,
            accountID: accountID
        )
        activeToken = token
        return token
    }

    public func isActive(_ token: CloudSynchronizationToken) -> Bool {
        activeToken == token
    }

    public mutating func reset() {
        activeToken = nil
    }

    /// Returns `nil` for a stale completion so it cannot clear or replace the
    /// status of a newer synchronization.
    public mutating func resolvedCompletionStatus(
        _ proposedStatus: CloudSyncStatus,
        for token: CloudSynchronizationToken,
        currentAccountID: UUID?
    ) -> CloudSyncStatus? {
        guard activeToken == token else { return nil }
        activeToken = nil
        return currentAccountID == token.accountID ? proposedStatus : .idle
    }
}
