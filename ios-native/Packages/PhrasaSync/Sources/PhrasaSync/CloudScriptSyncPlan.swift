import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

public struct CloudScriptRemoteDeletion: Equatable, Sendable {
    public let tombstone: ScriptDeletionTombstone
    public let expectedRemote: ScriptDocument

    public init(tombstone: ScriptDeletionTombstone, expectedRemote: ScriptDocument) {
        self.tombstone = tombstone
        self.expectedRemote = expectedRemote
    }
}

/// A deterministic account-aware three-way sync plan. The durable fingerprint
/// is the common baseline; one changed side wins, while different script edits
/// preserve the cloud row and upload the device edit as a deterministic,
/// unfiled conflict copy. Records written by an older build have no baseline
/// and therefore preserve one-sided content.
public struct CloudScriptSyncPlan: Equatable, Sendable {
    public var upload: [ScriptDocument]
    public var deleteRemotely: [CloudScriptRemoteDeletion]
    public var applyLocally: [ScriptDocument]
    public var deleteLocally: [ScriptDeletionTombstone]
    public var records: [CloudScriptSyncRecord]
    public var tombstones: [ScriptDeletionTombstone]
    public var clearedTombstoneIDs: Set<UUID>

    public static func make(
        local: [ScriptDocument],
        remote: [ScriptDocument],
        state: CloudLocalSyncState,
        detectedAt: Date,
        verifiedRemoteAbsenceIDs: Set<UUID> = []
    ) throws -> Self {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let allIDs = Set(localByID.keys)
            .union(remoteByID.keys)
            .union(state.currentAccountRecords.keys)
            .union(state.tombstonesByScriptID.keys)
        var upload: [ScriptDocument] = []
        var deleteRemotely: [CloudScriptRemoteDeletion] = []
        var applyLocally: [ScriptDocument] = []
        var deleteLocally: [ScriptDeletionTombstone] = []
        var recordsByID: [UUID: CloudScriptSyncRecord] = [:]
        var tombstonesByID: [UUID: ScriptDeletionTombstone] = [:]
        var clearedTombstoneIDs: Set<UUID> = []

        func markSynced(_ script: ScriptDocument) {
            recordsByID[script.id] = CloudScriptSyncRecord(
                accountID: state.accountID,
                scriptID: script.id,
                lastSyncedUpdatedAt: CloudTimestampPrecision.normalized(script.updatedAt),
                lastSyncedFingerprint: CloudScriptFingerprint.make(script)
            )
        }

        func reconcileMatchingContent(
            local: ScriptDocument,
            remote: ScriptDocument
        ) {
            let merged = CloudScriptVersion.mergingMetadata(
                contentFrom: remote,
                local: local,
                remote: remote
            )
            if !CloudScriptVersion.matches(merged, remote) {
                upload.append(merged)
            }
            if !CloudScriptVersion.matches(merged, local) {
                applyLocally.append(merged)
            }
            markSynced(merged)
        }

        func chooseLocalContent(
            _ local: ScriptDocument,
            over remote: ScriptDocument
        ) {
            let merged = CloudScriptVersion.mergingMetadata(
                contentFrom: local,
                local: local,
                remote: remote
            )
            upload.append(merged)
            if !CloudScriptVersion.matches(merged, local) {
                applyLocally.append(merged)
            }
            markSynced(merged)
        }

        func chooseRemoteContent(
            _ remote: ScriptDocument,
            over local: ScriptDocument
        ) {
            let merged = CloudScriptVersion.mergingMetadata(
                contentFrom: remote,
                local: local,
                remote: remote
            )
            if !CloudScriptVersion.matches(merged, remote) {
                upload.append(merged)
            }
            applyLocally.append(merged)
            markSynced(merged)
        }

        func preserveDivergentContent(
            local: ScriptDocument,
            remote: ScriptDocument
        ) throws {
            let conflictCopy = CloudScriptConflictCopy.make(
                local: local,
                accountID: state.accountID
            )
            guard conflictCopy.id != local.id,
                  !state.scriptIDsOwnedByOtherAccounts.contains(conflictCopy.id) else {
                throw CloudRepositoryError.scriptConflict(local)
            }
            let conflictFingerprint = CloudScriptFingerprint.make(conflictCopy)
            if let existingLocal = localByID[conflictCopy.id],
               CloudScriptFingerprint.make(existingLocal) != conflictFingerprint {
                throw CloudRepositoryError.scriptConflict(existingLocal)
            }
            if let existingRemote = remoteByID[conflictCopy.id],
               CloudScriptFingerprint.make(existingRemote) != conflictFingerprint {
                throw CloudRepositoryError.scriptConflict(existingRemote)
            }

            // The cloud copy keeps the original identity. The device's work is
            // promoted to a deterministic new identity, so retrying after a
            // partial network success addresses the same row instead of making
            // another duplicate.
            applyLocally.append(remote)
            clearedTombstoneIDs.insert(local.id)
            markSynced(remote)

            if let existingRemote = remoteByID[conflictCopy.id] {
                reconcileMatchingContent(local: conflictCopy, remote: existingRemote)
            } else {
                let copyToUpload: ScriptDocument
                if let existingLocal = localByID[conflictCopy.id] {
                    copyToUpload = CloudScriptVersion.mergingMetadata(
                        contentFrom: conflictCopy,
                        local: existingLocal,
                        remote: conflictCopy
                    )
                } else {
                    copyToUpload = conflictCopy
                }
                upload.append(copyToUpload)
                markSynced(copyToUpload)
            }
        }

        func markRemoteDeletion(
            id: UUID,
            local: ScriptDocument?,
            record: CloudScriptSyncRecord
        ) {
            let tombstone = state.tombstonesByScriptID[id]
                ?? ScriptDeletionTombstone(scriptID: id, deletedAt: detectedAt)
            tombstonesByID[id] = tombstone
            if local != nil { deleteLocally.append(tombstone) }
            recordsByID[id] = record
        }

        for id in allIDs {
            let record = state.currentAccountRecords[id]
            // Ownership is exclusive on this device. A local script claimed or
            // downloaded by account A is invisible to account B's sync plan,
            // even though it remains available in the offline library.
            if state.scriptIDsOwnedByOtherAccounts.contains(id) {
                continue
            }

            let localScript = localByID[id]
            let remoteScript = remoteByID[id]

            if let tombstone = state.tombstonesByScriptID[id] {
                if let baseline = record?.lastSyncedFingerprint {
                    if let remoteScript {
                        if CloudScriptFingerprint.make(remoteScript) == baseline {
                            deleteRemotely.append(CloudScriptRemoteDeletion(
                                tombstone: tombstone,
                                expectedRemote: remoteScript
                            ))
                            if localScript != nil { deleteLocally.append(tombstone) }
                            recordsByID[id] = record
                            tombstonesByID[id] = tombstone
                        } else {
                            applyLocally.append(remoteScript)
                            clearedTombstoneIDs.insert(id)
                            markSynced(remoteScript)
                        }
                    } else {
                        // The explicit local tombstone remains authoritative
                        // for this device, while the point lookup determines
                        // whether any exact cloud version still needs removal.
                        if localScript != nil { deleteLocally.append(tombstone) }
                        recordsByID[id] = record
                        tombstonesByID[id] = tombstone
                    }
                } else {
                    // A legacy tombstone has no proof of which cloud content
                    // was deleted. Preserve any surviving copy and establish a
                    // baseline; only identical two-sided copies can be merged.
                    switch (localScript, remoteScript) {
                    case (.some(let local), .some(let remote)):
                        if CloudScriptFingerprint.make(local)
                            == CloudScriptFingerprint.make(remote) {
                            reconcileMatchingContent(local: local, remote: remote)
                        } else {
                            try preserveDivergentContent(local: local, remote: remote)
                        }
                        clearedTombstoneIDs.insert(id)
                    case (.some(let local), .none):
                        upload.append(local)
                        markSynced(local)
                        clearedTombstoneIDs.insert(id)
                    case (.none, .some(let remote)):
                        applyLocally.append(remote)
                        markSynced(remote)
                        clearedTombstoneIDs.insert(id)
                    case (.none, .none):
                        if let record { recordsByID[id] = record }
                        tombstonesByID[id] = tombstone
                    }
                }
                continue
            }

            if let record, let baseline = record.lastSyncedFingerprint {
                switch (localScript, remoteScript) {
                case (.some(let local), .some(let remote)):
                    let localFingerprint = CloudScriptFingerprint.make(local)
                    let remoteFingerprint = CloudScriptFingerprint.make(remote)
                    if localFingerprint == remoteFingerprint {
                        reconcileMatchingContent(local: local, remote: remote)
                    } else if localFingerprint == baseline {
                        chooseRemoteContent(remote, over: local)
                    } else if remoteFingerprint == baseline {
                        chooseLocalContent(local, over: remote)
                    } else {
                        try preserveDivergentContent(local: local, remote: remote)
                    }
                case (.some(let local), .none):
                    if CloudScriptFingerprint.make(local) == baseline {
                        if verifiedRemoteAbsenceIDs.contains(id) {
                            markRemoteDeletion(id: id, local: local, record: record)
                        } else {
                            recordsByID[id] = record
                        }
                    } else {
                        upload.append(local)
                        markSynced(local)
                    }
                case (.none, .some(let remote)):
                    if CloudScriptFingerprint.make(remote) == baseline {
                        let tombstone = ScriptDeletionTombstone(
                            scriptID: id,
                            deletedAt: detectedAt
                        )
                        deleteRemotely.append(CloudScriptRemoteDeletion(
                            tombstone: tombstone,
                            expectedRemote: remote
                        ))
                        tombstonesByID[id] = tombstone
                        recordsByID[id] = record
                    } else {
                        applyLocally.append(remote)
                        clearedTombstoneIDs.insert(id)
                        markSynced(remote)
                    }
                case (.none, .none):
                    if verifiedRemoteAbsenceIDs.contains(id) {
                        markRemoteDeletion(id: id, local: nil, record: record)
                    } else {
                        recordsByID[id] = record
                    }
                }
                continue
            }

            // Claimed and legacy records have no exact ancestor. Never infer a
            // deletion from them: preserve a one-sided copy, and fail closed
            // when two different versions share the same ID.
            switch (localScript, remoteScript) {
            case (.some(let local), .some(let remote)):
                if CloudScriptFingerprint.make(local)
                    == CloudScriptFingerprint.make(remote) {
                    reconcileMatchingContent(local: local, remote: remote)
                } else {
                    try preserveDivergentContent(local: local, remote: remote)
                }
            case (.some(let local), .none):
                upload.append(local)
                markSynced(local)
            case (.none, .some(let remote)):
                applyLocally.append(remote)
                clearedTombstoneIDs.insert(id)
                markSynced(remote)
            case (.none, .none):
                if let record { recordsByID[id] = record }
            }
        }

        func deduplicated(_ scripts: [ScriptDocument]) -> [ScriptDocument] {
            Array(Dictionary(
                scripts.map { ($0.id, $0) },
                uniquingKeysWith: { first, second in
                    guard CloudScriptFingerprint.make(first)
                            == CloudScriptFingerprint.make(second) else {
                        return second
                    }
                    return CloudScriptVersion.mergingMetadata(
                        contentFrom: second,
                        local: first,
                        remote: second
                    )
                }
            ).values)
        }

        upload = deduplicated(upload)
        applyLocally = deduplicated(applyLocally)
        upload.sort { $0.id.uuidString < $1.id.uuidString }
        deleteRemotely.sort {
            $0.tombstone.scriptID.uuidString < $1.tombstone.scriptID.uuidString
        }
        applyLocally.sort { $0.id.uuidString < $1.id.uuidString }
        deleteLocally.sort { $0.scriptID.uuidString < $1.scriptID.uuidString }
        return Self(
            upload: upload,
            deleteRemotely: deleteRemotely,
            applyLocally: applyLocally,
            deleteLocally: deleteLocally,
            records: recordsByID.values.sorted { $0.scriptID.uuidString < $1.scriptID.uuidString },
            tombstones: tombstonesByID.values.sorted { $0.scriptID.uuidString < $1.scriptID.uuidString },
            clearedTombstoneIDs: clearedTombstoneIDs
        )
    }

    public static func remoteAbsenceCandidateIDs(
        remote: [ScriptDocument],
        state: CloudLocalSyncState
    ) -> Set<UUID> {
        let remoteIDs = Set(remote.map(\.id))
        return Set(state.currentAccountRecords.compactMap { id, record in
            guard record.lastSyncedFingerprint != nil,
                  !remoteIDs.contains(id),
                  !state.scriptIDsOwnedByOtherAccounts.contains(id) else {
                return nil
            }
            return id
        })
    }
}

public struct CloudFolderRemoteDeletion: Equatable, Sendable {
    public let tombstone: FolderDeletionTombstone
    public let expectedRemote: ScriptFolder

    public init(tombstone: FolderDeletionTombstone, expectedRemote: ScriptFolder) {
        self.tombstone = tombstone
        self.expectedRemote = expectedRemote
    }
}

/// Folder names are account content too. Each synced folder carries the exact
/// name and creation value last observed by both sides. That durable baseline,
/// rather than device wall-clock ordering, distinguishes one-sided edits from
/// true divergent conflicts and makes remote absence safe to interpret.
public struct CloudFolderSyncPlan: Equatable, Sendable {
    public var upload: [ScriptFolder]
    public var deleteRemotely: [CloudFolderRemoteDeletion]
    public var applyLocally: [ScriptFolder]
    public var deleteLocally: [FolderDeletionTombstone]
    public var records: [CloudFolderSyncRecord]
    public var tombstones: [FolderDeletionTombstone]
    public var clearedTombstoneIDs: Set<UUID>
    public var allowedFolderIDs: Set<UUID>

    public func removingForeignFolderLinks(from scripts: [ScriptDocument]) -> [ScriptDocument] {
        scripts.map { script in
            guard let folderID = script.folderID,
                  !allowedFolderIDs.contains(folderID) else {
                return script
            }
            var unfiled = script
            unfiled.folderID = nil
            return unfiled
        }
    }

    public static func make(
        local: [ScriptFolder],
        remote: [ScriptFolder],
        state: CloudLocalSyncState,
        detectedAt: Date,
        verifiedRemoteAbsenceIDs: Set<UUID> = []
    ) throws -> Self {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let allIDs = Set(localByID.keys)
            .union(remoteByID.keys)
            .union(state.currentAccountFolderRecords.keys)
        var upload: [ScriptFolder] = []
        var deleteRemotely: [CloudFolderRemoteDeletion] = []
        var applyLocally: [ScriptFolder] = []
        var deleteLocally: [FolderDeletionTombstone] = []
        var recordsByID: [UUID: CloudFolderSyncRecord] = [:]
        var tombstonesByID: [UUID: FolderDeletionTombstone] = [:]
        var clearedTombstoneIDs: Set<UUID> = []

        func markSynced(_ folder: ScriptFolder) {
            recordsByID[folder.id] = CloudFolderSyncRecord(
                accountID: state.accountID,
                folderID: folder.id,
                hasSynced: true,
                lastSyncedName: folder.name,
                lastSyncedCreatedAt: CloudTimestampPrecision.wireNormalized(folder.createdAt)
            )
        }

        func markDeletion(
            id: UUID,
            local: ScriptFolder?,
            remote: ScriptFolder?,
            record: CloudFolderSyncRecord
        ) {
            let tombstone = state.tombstonesByFolderID[id]
                ?? FolderDeletionTombstone(folderID: id, deletedAt: detectedAt)
            tombstonesByID[id] = tombstone
            if local != nil { deleteLocally.append(tombstone) }
            if let remote {
                deleteRemotely.append(CloudFolderRemoteDeletion(
                    tombstone: tombstone,
                    expectedRemote: remote
                ))
            }
            recordsByID[id] = record
        }

        for id in allIDs {
            let record = state.currentAccountFolderRecords[id]
            if state.folderIDsOwnedByOtherAccounts.contains(id) {
                continue
            }
            let localFolder = localByID[id]
            let remoteFolder = remoteByID[id]

            if let record, state.tombstonesByFolderID[id] != nil {
                if let baseline = Self.baseline(for: record) {
                    if let remoteFolder,
                       !Self.matches(remoteFolder, baseline: baseline) {
                        // An explicit local deletion must not erase a remote
                        // rename or recreation made from the shared baseline.
                        applyLocally.append(remoteFolder)
                        clearedTombstoneIDs.insert(id)
                        markSynced(remoteFolder)
                    } else {
                        markDeletion(
                            id: id,
                            local: localFolder,
                            remote: remoteFolder,
                            record: record
                        )
                    }
                } else {
                    // A legacy ownership-only record cannot prove which side
                    // changed. Preserve any surviving data and establish an
                    // exact baseline only after both sides agree on a copy.
                    switch (localFolder, remoteFolder) {
                    case (.some(let local), .some(let remote)):
                        guard Self.matches(local, baseline: remote) else {
                            throw CloudRepositoryError.folderConflict(
                                device: local,
                                cloud: remote
                            )
                        }
                        clearedTombstoneIDs.insert(id)
                        markSynced(local)
                    case (.some(let local), .none):
                        upload.append(local)
                        clearedTombstoneIDs.insert(id)
                        markSynced(local)
                    case (.none, .some(let remote)):
                        applyLocally.append(remote)
                        clearedTombstoneIDs.insert(id)
                        markSynced(remote)
                    case (.none, .none):
                        recordsByID[id] = record
                        if let tombstone = state.tombstonesByFolderID[id] {
                            tombstonesByID[id] = tombstone
                        }
                    }
                }
                continue
            }

            if let record, let baseline = Self.baseline(for: record) {
                switch (localFolder, remoteFolder) {
                case (.some(let local), .some(let remote)):
                    let localMatches = Self.matches(local, baseline: baseline)
                    let remoteMatches = Self.matches(remote, baseline: baseline)
                    if Self.matches(local, baseline: remote) {
                        markSynced(local)
                    } else if localMatches, !remoteMatches {
                        applyLocally.append(remote)
                        markSynced(remote)
                    } else if !localMatches, remoteMatches {
                        upload.append(local)
                        markSynced(local)
                    } else {
                        // Both sides diverged from the exact shared baseline.
                        // Stop before either value is overwritten.
                        throw CloudRepositoryError.folderConflict(
                            device: local,
                            cloud: remote
                        )
                    }
                    clearedTombstoneIDs.insert(id)
                case (.some(let local), .none):
                    if Self.matches(local, baseline: baseline) {
                        if verifiedRemoteAbsenceIDs.contains(id) {
                            markDeletion(
                                id: id,
                                local: local,
                                remote: nil,
                                record: record
                            )
                        } else {
                            recordsByID[id] = record
                        }
                    } else {
                        // A rename or recreated generation is real local work;
                        // it wins over a confirmed deletion of the old baseline.
                        upload.append(local)
                        clearedTombstoneIDs.insert(id)
                        markSynced(local)
                    }
                case (.none, .some(let remote)):
                    if Self.matches(remote, baseline: baseline) {
                        // The remote still has the exact shared baseline, so an
                        // absent local copy represents a local deletion.
                        markDeletion(
                            id: id,
                            local: nil,
                            remote: remote,
                            record: record
                        )
                    } else {
                        // Remote changed or recreated the folder; preserve it.
                        applyLocally.append(remote)
                        clearedTombstoneIDs.insert(id)
                        markSynced(remote)
                    }
                case (.none, .none):
                    if verifiedRemoteAbsenceIDs.contains(id) {
                        markDeletion(id: id, local: nil, remote: nil, record: record)
                    } else {
                        recordsByID[id] = record
                    }
                }
            } else {
                // Newly claimed and legacy records have no trustworthy shared
                // baseline. One-sided data is preserved; two differing copies
                // require explicit resolution instead of local-wins overwrite.
                switch (localFolder, remoteFolder) {
                case (.some(let local), .some(let remote)):
                    guard Self.matches(local, baseline: remote) else {
                        throw CloudRepositoryError.folderConflict(
                            device: local,
                            cloud: remote
                        )
                    }
                    clearedTombstoneIDs.insert(id)
                    markSynced(local)
                case (.some(let local), .none):
                    upload.append(local)
                    clearedTombstoneIDs.insert(id)
                    markSynced(local)
                case (.none, .some(let remote)):
                    applyLocally.append(remote)
                    clearedTombstoneIDs.insert(id)
                    markSynced(remote)
                case (.none, .none):
                    if let record { recordsByID[id] = record }
                }
            }
        }

        upload.sort { $0.id.uuidString < $1.id.uuidString }
        deleteRemotely.sort {
            $0.expectedRemote.id.uuidString < $1.expectedRemote.id.uuidString
        }
        applyLocally.sort { $0.id.uuidString < $1.id.uuidString }
        deleteLocally.sort { $0.folderID.uuidString < $1.folderID.uuidString }
        let deletedLocalIDs = Set(deleteLocally.map(\.folderID))
        let retainedCurrentLocalIDs = Set(localByID.keys).intersection(
            state.currentAccountFolderRecords.keys
        ).subtracting(deletedLocalIDs)
        return Self(
            upload: upload,
            deleteRemotely: deleteRemotely,
            applyLocally: applyLocally,
            deleteLocally: deleteLocally,
            records: recordsByID.values.sorted {
                $0.folderID.uuidString < $1.folderID.uuidString
            },
            tombstones: tombstonesByID.values.sorted {
                $0.folderID.uuidString < $1.folderID.uuidString
            },
            clearedTombstoneIDs: clearedTombstoneIDs,
            allowedFolderIDs: retainedCurrentLocalIDs.union(applyLocally.map(\.id))
        )
    }

    public static func remoteAbsenceCandidateIDs(
        remote: [ScriptFolder],
        state: CloudLocalSyncState
    ) -> Set<UUID> {
        let remoteIDs = Set(remote.map(\.id))
        return Set(state.currentAccountFolderRecords.compactMap { id, record in
            guard Self.baseline(for: record) != nil,
                  !remoteIDs.contains(id),
                  !state.folderIDsOwnedByOtherAccounts.contains(id) else {
                return nil
            }
            return id
        })
    }

    private static func baseline(for record: CloudFolderSyncRecord) -> ScriptFolder? {
        guard record.hasSynced,
              let name = record.lastSyncedName,
              let createdAt = record.lastSyncedCreatedAt else {
            return nil
        }
        return ScriptFolder(id: record.folderID, name: name, createdAt: createdAt)
    }

    public static func matches(_ folder: ScriptFolder, baseline: ScriptFolder) -> Bool {
        folder.id == baseline.id
            && folder.name == baseline.name
            // Folders round-trip created_at through the same ms wire boundary.
            && CloudTimestampPrecision.wireMatches(folder.createdAt, baseline.createdAt)
    }
}
