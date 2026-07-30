import Foundation
import Observation

// CloudSyncSummary / CloudSyncResult / CloudSyncInput live in shared PhrasaSync
// sources (embedded into this module on iOS; package product on Mac).

enum LibraryEditorDocumentMetadataChange: Equatable, Sendable {
    case folderID(UUID?)
    case lastOpenedAt(Date?)

    func apply(to document: inout ScriptDocument) {
        switch self {
        case .folderID(let folderID):
            document.folderID = folderID
        case .lastOpenedAt(let lastOpenedAt):
            document.lastOpenedAt = lastOpenedAt
        }
    }
}

enum LibraryEditorDocumentChangeScope: Equatable, Sendable {
    case replacement
    case metadata(LibraryEditorDocumentMetadataChange)
}

struct LibraryEditorDocumentChange: Equatable, Sendable {
    let revision: UInt64
    let document: ScriptDocument?
    let editorOriginID: UUID?
    let scope: LibraryEditorDocumentChangeScope

    init(
        revision: UInt64,
        document: ScriptDocument?,
        editorOriginID: UUID?,
        scope: LibraryEditorDocumentChangeScope = .replacement
    ) {
        self.revision = revision
        self.document = document
        self.editorOriginID = editorOriginID
        self.scope = scope
    }
}

@MainActor
@Observable
final class LibraryStore {
    enum RestoreMode: Sendable {
        case merge
        case replace
    }
    private(set) var scripts: [ScriptDocument] = []
    private(set) var folders: [ScriptFolder] = []
    var settings = ReaderSettings()
    private(set) var isLoaded = false
    private(set) var errorMessage: String?
    private(set) var canStartFreshAfterCorruption = false

    private let persistence: any LibraryPersistence
    private let legacyMigrator: LegacyExpoMigrator
    private var seeded = false
    @ObservationIgnored private var durableMutationIsRunning = false
    @ObservationIgnored private var durableMutationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var recoverableLoadErrorMessage: String?
    @ObservationIgnored private var recoverableLegacyLibrary = false
    @ObservationIgnored private var nextEditorDocumentRevision: UInt64 = 0
    @ObservationIgnored private var stagedEditorDrafts: [UUID: StagedEditorDraft] = [:]
    /// Script IDs whose latest editor content has not completed a durable write.
    /// Cloud prepare/push/pull must defer while this set is non-empty.
    @ObservationIgnored private var unpersistedEditorScriptIDs: Set<UUID> = []
    /// Bumped whenever editor content becomes unpersisted so a post-prepare
    /// stage invalidates any outstanding cloud eligibility lease.
    @ObservationIgnored private var cloudSyncEligibilityGeneration: UInt64 = 0
    @ObservationIgnored private var issuedCloudSyncEligibilityLease: CloudSyncEligibilityLease?
    /// Fired after a successful durable library mutation that may need cloud push.
    /// Never invoked for staged editor drafts, markOpened metadata, or failed saves.
    @ObservationIgnored var onDurableCloudRelevantMutation: (() -> Void)?
    private var editorDocumentChanges: [UUID: LibraryEditorDocumentChange] = [:]

    private struct StagedEditorDraft {
        let revision: UInt64
        let originID: UUID
        let document: ScriptDocument
    }

    /// Host dirty-editor signal for the shared sync eligibility gate.
    var cloudSyncHostDirtyState: CloudSyncHostDirtyState {
        CloudSyncHostDirtyState(
            unpersistedEditorScriptCount: unpersistedEditorScriptIDs.count
        )
    }

    /// Lease issued by the latest successful `prepareCloudSync`. Invalid when a
    /// draft becomes dirty after prepare (fail closed before network I/O).
    var cloudSyncEligibilityLease: CloudSyncEligibilityLease? {
        issuedCloudSyncEligibilityLease
    }

    /// Fail-closed check used after prepare and before the first repository
    /// fetch/write. Does not acquire the durable mutation lock.
    func isCloudSyncEligibilityLeaseValid(_ lease: CloudSyncEligibilityLease) -> Bool {
        issuedCloudSyncEligibilityLease == lease
            && lease.generation == cloudSyncEligibilityGeneration
            && cloudSyncHostDirtyState.eligibility.isEligible
    }

    init(
        persistence: any LibraryPersistence = LibraryPersistenceFactory.makeShipping(),
        legacyMigrator: LegacyExpoMigrator = LegacyExpoMigrator()
    ) {
        self.persistence = persistence
        self.legacyMigrator = legacyMigrator
    }

    func load() async {
        guard !isLoaded else { return }
        errorMessage = nil
        canStartFreshAfterCorruption = false
        recoverableLoadErrorMessage = nil
        recoverableLegacyLibrary = false
        do {
            let loaded = try await persistence.load()
            scripts = loaded.scripts
            folders = loaded.folders
            settings = loaded.settings
            settings.normalize()
            seeded = loaded.seeded
            if scripts.isEmpty && !seeded {
                if let migrated = try legacyMigrator.importIfPresent() {
                    scripts = migrated.scripts.isEmpty ? [.welcome] : migrated.scripts
                    folders = migrated.folders
                    settings = migrated.settings
                    seeded = true
                } else {
                    scripts = [.welcome]
                    seeded = true
                }
                try await persistence.replace(with: snapshot())
            }
        } catch {
            errorMessage = error.localizedDescription
            if legacyMigrator.canRecoverLibrary(after: error) {
                canStartFreshAfterCorruption = true
                recoverableLegacyLibrary = true
                recoverableLoadErrorMessage = error.localizedDescription
            } else if let recovery = persistence as? any LibraryRecoveryPersistence,
               recovery.canRecoverLibrary(after: error) {
                canStartFreshAfterCorruption = true
                recoverableLoadErrorMessage = error.localizedDescription
            }
            return
        }
        isLoaded = true
    }

    @discardableResult
    func createScript(
        title: String = "Untitled script",
        body: String = "",
        folderID: UUID? = nil
    ) async -> ScriptDocument? {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
            return nil
        }
        let script = ScriptDocument(title: title, body: body, folderID: folderID)
        guard await saveScriptCatching(script) else { return nil }
        scripts.insert(script, at: 0)
        publishEditorDocumentChange(script, originID: nil)
        notifyDurableCloudRelevantMutation()
        return script
    }

    @discardableResult
    func update(_ script: ScriptDocument, editorOriginID: UUID? = nil) async -> Bool {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard !Task.isCancelled else { return false }
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return false }
        if let editorOriginID {
            guard let stagedDraft = stagedEditorDrafts[script.id],
                  stagedDraft.originID == editorOriginID else {
                // An external replace, move, or delete invalidates every save
                // that was queued from the editor's older baseline.
                return false
            }
            guard editableContentMatches(stagedDraft.document, script) else {
                // A newer draft from this same editor superseded this queued
                // value. Treat it as consumed without writing so the
                // autosave controller can continue immediately to the latest
                // pending value.
                return true
            }
        }
        var revised = revisedEditorDocument(script, changedAt: .now)
        // These fields are maintained outside the editor. A draft captured
        // before markOpened completed must never put older metadata back.
        revised.createdAt = scripts[index].createdAt
        revised.lastOpenedAt = scripts[index].lastOpenedAt
        revised.folderID = scripts[index].folderID
        // Editor drafts are the deliberate exception to commit-before-publish:
        // the autosave controller retains this visible value and offers Retry
        // when the durable write fails.
        scripts[index] = revised
        sortScripts()
        let revision = publishEditorDocumentChange(revised, originID: editorOriginID)
        if let editorOriginID {
            stagedEditorDrafts[revised.id] = StagedEditorDraft(
                revision: revision,
                originID: editorOriginID,
                document: revised
            )
        }
        // Mark dirty before the await so a concurrent prepare cannot snapshot
        // this in-memory revision before SQLite commits.
        markEditorContentUnpersisted(revised.id)
        let saved = await saveScriptCatching(revised)
        if saved {
            unpersistedEditorScriptIDs.remove(revised.id)
            notifyDurableCloudRelevantMutation()
        }
        return saved
    }

    /// Mirrors the editor's latest draft into the visible library immediately
    /// without bypassing the editor's debounced durable-write queue. Staged
    /// drafts make cloud sync ineligible until a successful durable save.
    @discardableResult
    func stageEditorDraft(
        _ script: ScriptDocument,
        changedAt: Date = .now,
        editorOriginID: UUID? = nil
    ) -> Bool {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return false }
        var revised = revisedEditorDocument(script, changedAt: changedAt)
        revised.createdAt = scripts[index].createdAt
        revised.lastOpenedAt = scripts[index].lastOpenedAt
        if let folderID = revised.folderID,
           !folders.contains(where: { $0.id == folderID }) {
            revised.folderID = nil
        }
        scripts[index] = revised
        sortScripts()
        let revision = publishEditorDocumentChange(revised, originID: editorOriginID)
        if let editorOriginID {
            stagedEditorDrafts[revised.id] = StagedEditorDraft(
                revision: revision,
                originID: editorOriginID,
                document: revised
            )
        }
        // Staged drafts never schedule cloud push. They only invalidate any
        // outstanding prepare lease so incomplete editor content cannot ship.
        markEditorContentUnpersisted(revised.id)
        return true
    }

    func delete(_ id: UUID) async {
        await beginDurableMutation()
        defer { endDurableMutation() }
        do {
            try await persistence.deleteScript(id: id)
            scripts.removeAll { $0.id == id }
            publishEditorDocumentChange(id: id, document: nil, originID: nil)
            notifyDurableCloudRelevantMutation()
        } catch {
            // Keep the visible script when its durable row+tombstone
            // transaction fails. Hiding it here would make it appear to come
            // back after relaunch even though the delete never committed.
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func duplicate(_ id: UUID) async -> ScriptDocument? {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard var copy = scripts.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.title += " (copy)"
        copy.createdAt = .now
        copy.updatedAt = .now
        copy.lastOpenedAt = nil
        copy.outline = copy.outline.map { OutlinePoint(text: $0.text, note: $0.note) }
        guard await saveScriptCatching(copy) else { return nil }
        scripts.insert(copy, at: 0)
        publishEditorDocumentChange(copy, originID: nil)
        notifyDurableCloudRelevantMutation()
        return copy
    }

    @discardableResult
    func markOpened(_ id: UUID) async -> Bool {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard let script = scripts.first(where: { $0.id == id }) else { return false }
        let openedAt = Date.now
        var revised = script
        revised.lastOpenedAt = openedAt
        guard await saveScriptCatching(revised) else { return false }
        guard let currentIndex = scripts.firstIndex(where: { $0.id == id }) else { return false }
        // Only merge the metadata field so an editor draft staged while the
        // write was awaiting cannot be replaced by the older full document.
        scripts[currentIndex].lastOpenedAt = openedAt
        publishEditorDocumentChange(
            scripts[currentIndex],
            originID: nil,
            scope: .metadata(.lastOpenedAt(openedAt))
        )
        // Open timestamps are local metadata only — never schedule cloud push.
        return true
    }

    @discardableResult
    func saveSettings(_ newValue: ReaderSettings) async -> Bool {
        await beginDurableMutation()
        defer { endDurableMutation() }
        var normalized = newValue
        normalized.normalize()
        do {
            try await persistence.saveSettings(normalized, seeded: seeded)
            settings = normalized
            // Reader appearance/pacing preferences are intentionally local-only
            // for this release; saving them must not schedule a script/folder sync.
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createFolder(name: String) async -> ScriptFolder? {
        await beginDurableMutation()
        defer { endDurableMutation() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ScriptFolder(name: trimmed.isEmpty ? "Untitled folder" : trimmed)
        var revisedFolders = folders
        revisedFolders.append(folder)
        sortFolders(&revisedFolders)
        guard await saveFoldersCatching(revisedFolders) else { return nil }
        folders = revisedFolders
        notifyDurableCloudRelevantMutation()
        return folder
    }

    @discardableResult
    func renameFolder(_ id: UUID, to name: String) async -> Bool {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var revisedFolders = folders
        revisedFolders[index].name = trimmed.isEmpty ? "Untitled folder" : trimmed
        sortFolders(&revisedFolders)
        guard await saveFoldersCatching(revisedFolders) else { return false }
        folders = revisedFolders
        notifyDurableCloudRelevantMutation()
        return true
    }

    func deleteFolder(_ id: UUID) async {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard folders.contains(where: { $0.id == id }) else { return }
        let remainingFolders = folders.filter { $0.id != id }
        var revisedScripts = scripts
        let changedAt = Date.now
        var changedScripts: [ScriptDocument] = []
        for index in revisedScripts.indices where revisedScripts[index].folderID == id {
            revisedScripts[index].folderID = nil
            revisedScripts[index].updatedAt = changedAt
            changedScripts.append(revisedScripts[index])
        }
        do {
            try await persistence.deleteFolder(id: id, updatedScripts: changedScripts)
            // Keep the visible library aligned with the all-or-nothing disk
            // transaction. A failed delete therefore never appears to return
            // after relaunch.
            folders = remainingFolders
            // Re-scan current state: an editor can stage a move into this
            // folder while the delete transaction is awaiting persistence.
            var postCommitSanitizedScripts: [ScriptDocument] = []
            for currentIndex in scripts.indices where scripts[currentIndex].folderID == id {
                // Preserve any editor draft staged while persistence awaited;
                // only the folder relationship belongs to this operation.
                scripts[currentIndex].folderID = nil
                scripts[currentIndex].updatedAt = max(
                    scripts[currentIndex].updatedAt,
                    changedAt
                )
                postCommitSanitizedScripts.append(scripts[currentIndex])
                publishEditorDocumentChange(
                    scripts[currentIndex],
                    originID: nil,
                    scope: .metadata(.folderID(nil))
                )
            }
            sortScripts()
            // `stageEditorDraft` is synchronous and may run while the folder
            // transaction is awaiting its actor. Save the re-scanned versions
            // as well, so a draft that selected the now-deleted folder cannot
            // leave a dangling folder ID after relaunch.
            for script in postCommitSanitizedScripts {
                do {
                    try await persistence.upsert(script)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            notifyDurableCloudRelevantMutation()
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func moveScript(_ id: UUID, to folderID: UUID?) async -> Bool {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return false }
        guard var script = scripts.first(where: { $0.id == id }) else { return false }
        guard script.folderID != folderID else { return true }
        script.folderID = folderID
        let revised = revisedEditorDocument(script, changedAt: .now)
        guard await saveScriptCatching(revised) else { return false }
        guard let currentIndex = scripts.firstIndex(where: { $0.id == id }) else { return false }
        scripts[currentIndex].folderID = folderID
        scripts[currentIndex].updatedAt = max(scripts[currentIndex].updatedAt, revised.updatedAt)
        sortScripts()
        publishEditorDocumentChange(
            scripts[currentIndex],
            originID: nil,
            scope: .metadata(.folderID(folderID))
        )
        notifyDurableCloudRelevantMutation()
        return true
    }

    func script(id: UUID) -> ScriptDocument? { scripts.first { $0.id == id } }

    func editorDocumentChange(id: UUID) -> LibraryEditorDocumentChange? {
        editorDocumentChanges[id]
    }

    @discardableResult
    func addImported(_ script: ScriptDocument) async -> ScriptDocument? {
        await beginDurableMutation()
        defer { endDurableMutation() }
        var imported = script
        imported.id = UUID()
        imported.createdAt = .now
        imported.updatedAt = .now
        guard imported.folderID == nil || folders.contains(where: { $0.id == imported.folderID }) else {
            return nil
        }
        guard await saveScriptCatching(imported) else { return nil }
        scripts.insert(imported, at: 0)
        publishEditorDocumentChange(imported, originID: nil)
        notifyDurableCloudRelevantMutation()
        return imported
    }

    func exportSnapshot() -> LibrarySnapshot { snapshot() }

    /// Claims never-synced scripts for this account before cloud I/O begins.
    /// Existing ownership records are never reassigned on sign-out, so another
    /// account cannot upload content that came from the first account.
    ///
    /// Returns `.deferred` while any editor draft is staged but not yet
    /// durably persisted — never snapshots staged-only content for push/pull.
    /// On success, issues a short-lived eligibility lease that a later
    /// `stageEditorDraft` invalidates before any network I/O may begin.
    func prepareCloudSync(for accountID: UUID) async throws -> CloudSyncPreparationOutcome {
        await beginDurableMutation()
        defer { endDurableMutation() }
        issuedCloudSyncEligibilityLease = nil
        if case .deferred(let reason) = cloudSyncHostDirtyState.eligibility {
            return .deferred(reason)
        }
        let library = snapshot()
        let state = try await persistence.prepareCloudSync(
            accountID: accountID,
            localScriptIDs: Set(library.scripts.map(\.id)),
            localFolderIDs: Set(library.folders.map(\.id))
        )
        // A stage can interleave only if it does not take the durable lock;
        // re-check after the ownership write so staged content never ships.
        if case .deferred(let reason) = cloudSyncHostDirtyState.eligibility {
            return .deferred(reason)
        }
        try CloudSyncApplicationPolicy.validate(base: library, current: snapshot())
        let lease = CloudSyncEligibilityLease(generation: cloudSyncEligibilityGeneration)
        issuedCloudSyncEligibilityLease = lease
        return .ready(CloudSyncInput(library: library, state: state))
    }

    @discardableResult
    func restore(_ backup: LibrarySnapshot, mode: RestoreMode) async -> Bool {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard unpersistedEditorScriptIDs.isEmpty else {
            errorMessage = "Save or recover the open editor draft before restoring a backup."
            return false
        }
        var restored: LibrarySnapshot
        switch mode {
        case .replace:
            restored = LibrarySnapshot(
                scripts: backup.scripts,
                folders: backup.folders,
                settings: backup.settings,
                seeded: true
            )
        case .merge:
            var scriptsByID = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
            for script in backup.scripts {
                if let existing = scriptsByID[script.id] {
                    if CloudScriptFingerprint.make(script) == CloudScriptFingerprint.make(existing) {
                        scriptsByID[script.id] = CloudScriptVersion.mergingMetadata(
                            contentFrom: existing,
                            local: existing,
                            remote: script
                        )
                    } else {
                        // A backup clock is not proof that its divergent content
                        // should replace the current document. Preserve both.
                        let copy = backupConflictCopy(script)
                        if scriptsByID[copy.id] == nil {
                            scriptsByID[copy.id] = copy
                        }
                    }
                } else {
                    scriptsByID[script.id] = script
                }
            }
            var foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            for folder in backup.folders where foldersByID[folder.id] == nil {
                foldersByID[folder.id] = folder
            }
            restored = LibrarySnapshot(
                scripts: Array(scriptsByID.values),
                folders: Array(foldersByID.values),
                settings: settings,
                seeded: true
            )
        }
        restored.scripts.sort { $0.updatedAt > $1.updatedAt }
        sortFolders(&restored.folders)
        restored.settings.normalize()
        do {
            try await persistence.replace(with: restored)
            applyVisibleSnapshot(restored)
            notifyDurableCloudRelevantMutation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func backupConflictCopy(_ backup: ScriptDocument) -> ScriptDocument {
        let quarantineIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var copy = CloudScriptConflictCopy.make(
            local: backup,
            accountID: quarantineIdentity
        )
        let title = backup.title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = "\((title.isEmpty ? "Untitled script" : title)) — Backup copy"
        return copy
    }

    /// Persists the completed cloud merge before changing any visible state,
    /// so a disk error cannot leave the on-screen library ahead of its backup.
    func applyCloudLibrary(_ merged: LibrarySnapshot) async throws {
        await beginDurableMutation()
        defer { endDurableMutation() }
        var normalized = LibraryBackupNormalizer.normalized(merged)
        normalized.settings.normalize()
        try await persistence.replace(with: normalized)
        applyVisibleSnapshot(normalized)
    }

    /// The merged scripts and their account provenance are one transaction.
    /// If disk persistence fails, neither newly downloaded content nor its
    /// account association becomes visible on this device.
    func applyCloudSyncResult(_ result: CloudSyncResult) async throws {
        await beginDurableMutation()
        defer { endDurableMutation() }
        try CloudSyncApplicationPolicy.validate(
            base: result.baseLibrary,
            current: snapshot()
        )
        let editorRevisionAtCommitStart = nextEditorDocumentRevision
        var normalized = LibraryBackupNormalizer.normalized(result.mergedLibrary)
        normalized.settings.normalize()
        try await persistence.applyCloudSync(
            snapshot: normalized,
            update: result.persistenceUpdate
        )
        // A synchronous editor stage can occur while the persistence actor is
        // committing. At that point the cloud transaction cannot be undone.
        // Preserve edits newer than our revision boundary as either the
        // original row (when cloud did not change it) or a deterministic local
        // conflict copy, then publish the state that is actually durable.
        let reconciliation = await reconcileEditorDraftsAfterCloudCommit(
            base: result.baseLibrary,
            committedCloud: normalized,
            accountID: result.persistenceUpdate.accountID,
            newerThan: editorRevisionAtCommitStart
        )
        applyVisibleSnapshot(reconciliation.snapshot)
        if reconciliation.requiresRetry {
            let error = CloudSyncApplicationError.localConflictCopyNeedsSaving
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private struct CloudCommitReconciliation {
        var snapshot: LibrarySnapshot
        var requiresRetry: Bool
    }

    private func reconcileEditorDraftsAfterCloudCommit(
        base: LibrarySnapshot,
        committedCloud: LibrarySnapshot,
        accountID: UUID,
        newerThan revision: UInt64
    ) async -> CloudCommitReconciliation {
        let interleavedDrafts = stagedEditorDrafts.values
            .filter { $0.revision > revision }
            .sorted { $0.revision < $1.revision }
        guard !interleavedDrafts.isEmpty else {
            return CloudCommitReconciliation(snapshot: committedCloud, requiresRetry: false)
        }

        let baseByID = Dictionary(uniqueKeysWithValues: base.scripts.map { ($0.id, $0) })
        var reconciled = committedCloud
        var requiresRetry = false
        let validFolderIDs = Set(reconciled.folders.map(\.id))
        for staged in interleavedDrafts {
            var local = staged.document
            if let folderID = local.folderID, !validFolderIDs.contains(folderID) {
                local.folderID = nil
            }
            let cloudIndex = reconciled.scripts.firstIndex { $0.id == local.id }
            let cloud = cloudIndex.map { reconciled.scripts[$0] }
            var preserved: ScriptDocument

            if cloud == baseByID[local.id] {
                preserved = local
                if let cloudIndex {
                    reconciled.scripts[cloudIndex] = local
                } else {
                    reconciled.scripts.append(local)
                }
            } else if cloud == local {
                continue
            } else {
                preserved = makeLocalConflictCopy(from: local, accountID: accountID)
                if let index = reconciled.scripts.firstIndex(where: { $0.id == preserved.id }) {
                    if conflictFingerprint(reconciled.scripts[index])
                        == conflictFingerprint(preserved) {
                        reconciled.scripts[index] = preserved
                    } else {
                        // A user may have edited an earlier deterministic
                        // conflict copy. Never overwrite that real document.
                        preserved.id = UUID()
                        reconciled.scripts.append(preserved)
                    }
                } else {
                    reconciled.scripts.append(preserved)
                }
            }

            do {
                try await persistence.upsertCloudConflict(
                    preserved,
                    accountID: accountID
                )
            } catch {
                // The cloud row is already durable. Publish that committed row
                // plus the in-memory conflict copy, which invalidates the old
                // original-ID autosave and prevents its Retry action from
                // overwriting the cloud version. The visible error makes clear
                // that the preserved copy still needs a successful disk write.
                requiresRetry = true
            }
        }
        reconciled.scripts.sort { $0.updatedAt > $1.updatedAt }
        return CloudCommitReconciliation(
            snapshot: reconciled,
            requiresRetry: requiresRetry
        )
    }

    /// Shared content digest from PhrasaSync (embedded pure engine).
    private func conflictFingerprint(_ script: ScriptDocument) -> String {
        CloudScriptFingerprint.make(script)
    }

    private func makeLocalConflictCopy(
        from local: ScriptDocument,
        accountID: UUID
    ) -> ScriptDocument {
        CloudScriptConflictCopy.make(local: local, accountID: accountID)
    }

    private func applyVisibleSnapshot(_ normalized: LibrarySnapshot) {
        let previousIDs = Set(scripts.map(\.id))
        scripts = normalized.scripts.sorted { $0.updatedAt > $1.updatedAt }
        folders = normalized.folders.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        settings = normalized.settings
        seeded = normalized.seeded
        let documentsByID = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        for id in previousIDs.union(documentsByID.keys) {
            publishEditorDocumentChange(
                id: id,
                document: documentsByID[id],
                originID: nil
            )
        }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    func clearError() { errorMessage = nil }

    func redisplayRecoverableLoadError() {
        guard !isLoaded, let recoverableLoadErrorMessage else { return }
        errorMessage = recoverableLoadErrorMessage
    }

    @discardableResult
    func startFreshAfterCorruption() async -> Bool {
        await beginDurableMutation()
        defer { endDurableMutation() }
        guard !isLoaded, canStartFreshAfterCorruption else {
            return false
        }
        do {
            let recoveryDirectory: URL
            if recoverableLegacyLibrary {
                recoveryDirectory = try legacyMigrator.preserveUnreadableLibraryAndSkipMigration()
            } else if let recovery = persistence as? any LibraryRecoveryPersistence {
                recoveryDirectory = try await recovery.preserveCorruptLibraryAndReset()
            } else {
                return false
            }
            scripts = []
            folders = []
            settings = ReaderSettings()
            seeded = false
            canStartFreshAfterCorruption = false
            recoverableLoadErrorMessage = nil
            recoverableLegacyLibrary = false
            await load()
            guard isLoaded else { return false }
            errorMessage = "Phrasa started a fresh library after preserving the damaged files in \(recoveryDirectory.lastPathComponent)."
            return true
        } catch {
            errorMessage = error.localizedDescription
            canStartFreshAfterCorruption = true
            return false
        }
    }

    private func sortScripts() {
        scripts.sort { $0.updatedAt > $1.updatedAt }
    }

    private func sortFolders(_ folders: inout [ScriptFolder]) {
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    private func publishEditorDocumentChange(
        _ document: ScriptDocument,
        originID: UUID?,
        scope: LibraryEditorDocumentChangeScope = .replacement
    ) -> UInt64 {
        publishEditorDocumentChange(
            id: document.id,
            document: document,
            originID: originID,
            scope: scope
        )
    }

    @discardableResult
    private func publishEditorDocumentChange(
        id: UUID,
        document: ScriptDocument?,
        originID: UUID?,
        scope: LibraryEditorDocumentChangeScope = .replacement
    ) -> UInt64 {
        nextEditorDocumentRevision &+= 1
        if originID == nil, case .replacement = scope {
            stagedEditorDrafts[id] = nil
            // External durable replace supersedes any staged draft for this id.
            unpersistedEditorScriptIDs.remove(id)
        }
        editorDocumentChanges[id] = LibraryEditorDocumentChange(
            revision: nextEditorDocumentRevision,
            document: document,
            editorOriginID: originID,
            scope: scope
        )
        return nextEditorDocumentRevision
    }

    private func revisedEditorDocument(
        _ script: ScriptDocument,
        changedAt: Date
    ) -> ScriptDocument {
        var revised = script
        revised.title = revised.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if revised.title.isEmpty { revised.title = "Untitled script" }
        revised.updatedAt = changedAt
        return revised
    }

    private func editableContentMatches(
        _ left: ScriptDocument,
        _ right: ScriptDocument
    ) -> Bool {
        normalizedEditorTitle(left.title) == normalizedEditorTitle(right.title)
            && left.body == right.body
            && left.source == right.source
            && left.tags == right.tags
            && left.outline == right.outline
    }

    private func normalizedEditorTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled script" : trimmed
    }

    private func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(scripts: scripts, folders: folders, settings: settings, seeded: seeded)
    }

    @discardableResult
    private func saveScriptCatching(_ script: ScriptDocument) async -> Bool {
        do {
            try await persistence.upsert(script)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func saveFoldersCatching(_ folders: [ScriptFolder]) async -> Bool {
        do {
            try await persistence.saveFolders(folders)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Main-actor methods can interleave every time they await the persistence
    /// actor. This FIFO keeps commit-before-publish mutations in invocation
    /// order, so each candidate is built from the last successfully published
    /// state rather than from a stale snapshot.
    private func beginDurableMutation() async {
        if !durableMutationIsRunning {
            durableMutationIsRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            durableMutationWaiters.append(continuation)
        }
    }

    private func endDurableMutation() {
        guard !durableMutationWaiters.isEmpty else {
            durableMutationIsRunning = false
            return
        }
        durableMutationWaiters.removeFirst().resume()
    }

    private func markEditorContentUnpersisted(_ scriptID: UUID) {
        let wasClean = unpersistedEditorScriptIDs.isEmpty
        unpersistedEditorScriptIDs.insert(scriptID)
        if wasClean || issuedCloudSyncEligibilityLease != nil {
            cloudSyncEligibilityGeneration &+= 1
        }
        issuedCloudSyncEligibilityLease = nil
    }

    private func notifyDurableCloudRelevantMutation() {
        onDurableCloudRelevantMutation?()
    }
}

// CloudSyncApplicationError and CloudSyncApplicationPolicy live in the shared
// domain sources (Packages/PhrasaDomain) so package tests and the app share
// one definition of the commit-before-publish sync boundary.
