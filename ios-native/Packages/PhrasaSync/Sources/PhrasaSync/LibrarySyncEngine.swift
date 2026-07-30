import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// Pure, explicit, user-initiated library synchronization.
///
/// - Local SQLite (via the caller's prepared `CloudSyncInput`) remains the
///   offline source of truth until a successful apply.
/// - Never touches audio or transcripts.
/// - No background, realtime, or CloudKit paths.
/// - Ownership, quarantine, tombstones, conflict copies, and stale generations
///   are enforced through plans + the caller's token/lane.
/// - Callers must supply a live `preflight` that revalidates dirty-editor
///   eligibility immediately before the first repository call. There is no
///   default-clean shortcut on the shipping path.
public enum LibrarySyncEngine {
    /// Builds a merge result against a remote repository. Does not mutate local
    /// persistence — the platform store applies `CloudSyncResult` atomically.
    ///
    /// `preflight` runs immediately before the first repository/network
    /// operation so a draft staged after prepare fails closed with zero remote
    /// I/O. Never hold a durable store lock across this method.
    public static func synchronize(
        accountID: UUID,
        input: CloudSyncInput,
        preferences: CloudPreferenceResolution = .keepThisDevice,
        repository: any CloudLibraryRepository,
        preflight: CloudSyncPreflightValidator,
        ensureAccount: @escaping @Sendable () async throws -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> CloudSyncResult {
        guard input.state.accountID == accountID else {
            throw CloudRepositoryError.accountChanged
        }

        // Final TOCTOU close: live host validation immediately before remote I/O.
        // Value-only dirty captures at prepare time are not sufficient.
        try await preflight()

        let local = input.library
        let syncStartedAt = now()
        async let scriptsTask = repository.fetchScripts(accountID: accountID, updatedAfter: nil)
        async let foldersTask = repository.fetchFolders(accountID: accountID)
        async let settingsTask = repository.fetchSettings(accountID: accountID)
        var (remoteScripts, remoteFolders, remoteSettings) = try await (
            scriptsTask, foldersTask, settingsTask
        )
        try await ensureAccount()

        // Keyset pagination can miss rows inserted behind the cursor. Recheck
        // previously synced IDs omitted by enumeration; only a point-lookup nil
        // becomes a verified deletion candidate.
        var verifiedScriptAbsenceIDs: Set<UUID> = []
        let scriptCandidates = CloudScriptSyncPlan.remoteAbsenceCandidateIDs(
            remote: remoteScripts,
            state: input.state
        )
        for id in scriptCandidates.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let current = try await repository.fetchScript(id: id, accountID: accountID) {
                remoteScripts.append(current)
            } else {
                verifiedScriptAbsenceIDs.insert(id)
            }
            try await ensureAccount()
        }

        var verifiedFolderAbsenceIDs: Set<UUID> = []
        let folderCandidates = CloudFolderSyncPlan.remoteAbsenceCandidateIDs(
            remote: remoteFolders,
            state: input.state
        )
        for id in folderCandidates.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let current = try await repository.fetchFolder(id: id, accountID: accountID) {
                remoteFolders.append(current)
            } else {
                verifiedFolderAbsenceIDs.insert(id)
            }
            try await ensureAccount()
        }

        let plan = try CloudScriptSyncPlan.make(
            local: local.scripts,
            remote: remoteScripts,
            state: input.state,
            detectedAt: syncStartedAt,
            verifiedRemoteAbsenceIDs: verifiedScriptAbsenceIDs
        )
        let folderPlan = try CloudFolderSyncPlan.make(
            local: local.folders,
            remote: remoteFolders,
            state: input.state,
            detectedAt: syncStartedAt,
            verifiedRemoteAbsenceIDs: verifiedFolderAbsenceIDs
        )

        // Upload unfiled when a script's folder is foreign to this account.
        let scriptsToUpload = folderPlan.removingForeignFolderLinks(from: plan.upload)
        let folderWrites = CloudFolderWrite.make(
            desired: folderPlan.upload,
            from: remoteFolders
        )
        let scriptWrites = CloudScriptWrite.make(
            desired: scriptsToUpload,
            from: remoteScripts
        )

        try await repository.writeFolders(folderWrites, accountID: accountID)
        try await ensureAccount()
        let writtenScripts = try await repository.writeScripts(
            scriptWrites,
            accountID: accountID
        )
        try await ensureAccount()
        for deletion in plan.deleteRemotely {
            try await repository.deleteScript(
                expected: deletion.expectedRemote,
                accountID: accountID
            )
            try await ensureAccount()
        }
        for deletion in folderPlan.deleteRemotely {
            try await repository.deleteFolder(
                expected: deletion.expectedRemote,
                accountID: accountID
            )
            try await ensureAccount()
        }

        let resolvedSettings: ReaderSettings
        switch preferences {
        case .keepThisDevice:
            resolvedSettings = local.settings
            try await repository.saveSettings(local.settings, accountID: accountID)
            try await ensureAccount()
        case .restoreFromCloud:
            if let remoteSettings {
                resolvedSettings = remoteSettings
            } else {
                resolvedSettings = local.settings
                try await repository.saveSettings(local.settings, accountID: accountID)
            }
            try await ensureAccount()
        case .localOnly:
            // Shipping path: ignore remote settings and do not push local
            // whole-JSON settings. Scripts/folders remain the sync product.
            resolvedSettings = local.settings
            _ = remoteSettings
        }

        var scriptsByID = Dictionary(
            local.scripts.map { ($0.id, $0) },
            uniquingKeysWith: { left, right in left.updatedAt >= right.updatedAt ? left : right }
        )
        let currentAccountLocalScripts = local.scripts.filter {
            input.state.currentAccountRecords[$0.id] != nil
        }
        for script in folderPlan.removingForeignFolderLinks(from: currentAccountLocalScripts) {
            scriptsByID[script.id] = script
        }
        for tombstone in plan.deleteLocally {
            scriptsByID.removeValue(forKey: tombstone.scriptID)
        }
        for script in folderPlan.removingForeignFolderLinks(from: plan.applyLocally) {
            scriptsByID[script.id] = script
        }
        for script in writtenScripts {
            scriptsByID[script.id] = script
        }
        let removedFolderIDs = Set(folderPlan.deleteLocally.map(\.folderID))
        for script in scriptsByID.values where script.folderID.map(removedFolderIDs.contains) == true {
            var unfiled = script
            unfiled.folderID = nil
            scriptsByID[script.id] = unfiled
        }

        var foldersByID = Dictionary(
            uniqueKeysWithValues: local.folders.map { ($0.id, $0) }
        )
        for tombstone in folderPlan.deleteLocally {
            foldersByID.removeValue(forKey: tombstone.folderID)
        }
        for folder in folderPlan.applyLocally {
            foldersByID[folder.id] = folder
        }

        var resolvedScriptRecords = Dictionary(
            uniqueKeysWithValues: plan.records.map { ($0.scriptID, $0) }
        )
        for script in writtenScripts {
            resolvedScriptRecords[script.id] = CloudScriptSyncRecord(
                accountID: accountID,
                scriptID: script.id,
                lastSyncedUpdatedAt: CloudTimestampPrecision.normalized(script.updatedAt),
                lastSyncedFingerprint: CloudScriptFingerprint.make(script)
            )
        }

        let summary = CloudSyncSummary(
            uploadedScripts: plan.upload.count,
            downloadedScripts: plan.applyLocally.count,
            completedAt: now(),
            excludedLocalScriptCount: input.excludedLocalScriptCount,
            excludedLocalFolderCount: input.excludedLocalFolderCount
        )
        let merged = LibrarySnapshot(
            scripts: scriptsByID.values.sorted { $0.updatedAt > $1.updatedAt },
            folders: foldersByID.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            settings: resolvedSettings,
            seeded: local.seeded || !remoteScripts.isEmpty
        )
        return CloudSyncResult(
            baseLibrary: local,
            mergedLibrary: merged,
            summary: summary,
            persistenceUpdate: CloudSyncPersistenceUpdate(
                accountID: accountID,
                records: resolvedScriptRecords.values.sorted {
                    $0.scriptID.uuidString < $1.scriptID.uuidString
                },
                folderRecords: folderPlan.records,
                tombstones: plan.tombstones,
                clearedTombstoneIDs: plan.clearedTombstoneIDs,
                folderTombstones: folderPlan.tombstones,
                clearedFolderTombstoneIDs: folderPlan.clearedTombstoneIDs,
                expectedMutationRevision: input.state.mutationRevision
            )
        )
    }
}

/// In-memory repository for deterministic tests. Never used for production I/O.
public actor InMemoryCloudLibraryRepository: CloudLibraryRepository {
    public private(set) var scripts: [UUID: ScriptDocument] = [:]
    public private(set) var folders: [UUID: ScriptFolder] = [:]
    public private(set) var settings: ReaderSettings?
    public private(set) var accountID: UUID?

    public init(
        accountID: UUID? = nil,
        scripts: [ScriptDocument] = [],
        folders: [ScriptFolder] = [],
        settings: ReaderSettings? = nil
    ) {
        self.accountID = accountID
        self.scripts = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        self.folders = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        self.settings = settings
    }

    public func seed(
        accountID: UUID,
        scripts: [ScriptDocument],
        folders: [ScriptFolder],
        settings: ReaderSettings? = nil
    ) {
        self.accountID = accountID
        self.scripts = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        self.folders = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        self.settings = settings
    }

    public func fetchScripts(accountID: UUID, updatedAfter: Date?) async throws -> [ScriptDocument] {
        try verify(accountID)
        return scripts.values
            .filter { script in
                guard let updatedAfter else { return true }
                return script.updatedAt > updatedAfter
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func fetchScript(id: UUID, accountID: UUID) async throws -> ScriptDocument? {
        try verify(accountID)
        return scripts[id]
    }

    public func writeScripts(
        _ writes: [CloudScriptWrite],
        accountID: UUID
    ) async throws -> [ScriptDocument] {
        try verify(accountID)
        var written: [ScriptDocument] = []
        for write in writes {
            if let expected = write.expectedRemote {
                guard let current = scripts[write.desired.id],
                      CloudScriptVersion.matches(current, expected)
                        || CloudScriptFingerprint.make(current)
                            == CloudScriptFingerprint.make(expected)
                else {
                    // Accept exact fingerprint match on content even if opened-at differs.
                    if let current = scripts[write.desired.id],
                       write.currentMatchesDesired(current) {
                        written.append(current)
                        continue
                    }
                    if let current = scripts[write.desired.id],
                       CloudScriptFingerprint.make(current)
                        == CloudScriptFingerprint.make(write.desired) {
                        written.append(current)
                        continue
                    }
                    throw CloudRepositoryError.scriptConflict(write.desired)
                }
            }
            scripts[write.desired.id] = write.desired
            written.append(write.desired)
        }
        return written
    }

    public func deleteScript(expected: ScriptDocument, accountID: UUID) async throws {
        try verify(accountID)
        if let current = scripts[expected.id] {
            guard CloudTimestampPrecision.matches(current.updatedAt, expected.updatedAt) else {
                throw CloudRepositoryError.newerRemoteEdit
            }
            scripts.removeValue(forKey: expected.id)
        }
    }

    public func fetchFolders(accountID: UUID) async throws -> [ScriptFolder] {
        try verify(accountID)
        return folders.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func fetchFolder(id: UUID, accountID: UUID) async throws -> ScriptFolder? {
        try verify(accountID)
        return folders[id]
    }

    public func writeFolders(_ writes: [CloudFolderWrite], accountID: UUID) async throws {
        try verify(accountID)
        for write in writes {
            if let expected = write.expectedRemote,
               let current = folders[write.desired.id],
               !CloudFolderSyncPlan.matches(current, baseline: expected) {
                if write.currentMatchesDesired(current) { continue }
                throw CloudRepositoryError.folderConflict(device: write.desired, cloud: current)
            }
            folders[write.desired.id] = write.desired
        }
    }

    public func deleteFolder(expected: ScriptFolder, accountID: UUID) async throws {
        try verify(accountID)
        if let current = folders[expected.id] {
            guard CloudFolderSyncPlan.matches(current, baseline: expected) else {
                throw CloudRepositoryError.newerRemoteFolder
            }
            folders.removeValue(forKey: expected.id)
        }
    }

    public func fetchSettings(accountID: UUID) async throws -> ReaderSettings? {
        try verify(accountID)
        return settings
    }

    public func saveSettings(_ settings: ReaderSettings, accountID: UUID) async throws {
        try verify(accountID)
        self.settings = settings
    }

    private func verify(_ accountID: UUID) throws {
        if let existing = self.accountID, existing != accountID {
            throw CloudRepositoryError.accountChanged
        }
        self.accountID = accountID
    }
}
