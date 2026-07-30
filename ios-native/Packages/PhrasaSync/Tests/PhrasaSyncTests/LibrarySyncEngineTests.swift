import Foundation
import XCTest
@testable import PhrasaDomain
@testable import PhrasaSync

final class LibrarySyncEngineTests: XCTestCase {
    func testUploadDownloadAndConflictCopyAreDeterministic() async throws {
        let accountID = UUID()
        let baseline = ScriptDocument(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Shared",
            body: "baseline",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        var local = baseline
        local.body = "local edit"
        local.updatedAt = Date(timeIntervalSince1970: 20)
        var remote = baseline
        remote.body = "remote edit"
        remote.updatedAt = Date(timeIntervalSince1970: 30)

        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: baseline.id,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [baseline.id: record],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:],
            mutationRevision: 7
        )
        let library = LibrarySnapshot(
            scripts: [local],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let remoteRepo = InMemoryCloudLibraryRepository(
            accountID: accountID,
            scripts: [remote],
            folders: []
        )
        let input = CloudSyncInput(library: library, state: state)
        let fixedNow = Date(timeIntervalSince1970: 100)

        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: input,
            preferences: .keepThisDevice,
            repository: remoteRepo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible,
            now: { fixedNow }
        )

        let expectedConflict = CloudScriptConflictCopy.make(local: local, accountID: accountID)
        XCTAssertEqual(result.summary.uploadedScripts, 1)
        XCTAssertEqual(result.summary.downloadedScripts, 1)
        XCTAssertEqual(result.summary.completedAt, fixedNow)
        XCTAssertEqual(
            Set(result.mergedLibrary.scripts.map(\.id)),
            [remote.id, expectedConflict.id]
        )
        XCTAssertEqual(
            result.mergedLibrary.scripts.first(where: { $0.id == remote.id })?.body,
            "remote edit"
        )
        XCTAssertEqual(
            result.mergedLibrary.scripts.first(where: { $0.id == expectedConflict.id })?.body,
            "local edit"
        )
        XCTAssertNil(
            result.mergedLibrary.scripts.first(where: { $0.id == expectedConflict.id })?.folderID
        )
        XCTAssertEqual(result.persistenceUpdate.expectedMutationRevision, 7)
        XCTAssertEqual(result.persistenceUpdate.accountID, accountID)
    }

    func testForeignOwnedScriptsNeverUpload() async throws {
        let accountA = UUID()
        let accountB = UUID()
        let foreign = ScriptDocument(title: "A private", body: "secret")
        let owned = ScriptDocument(title: "B local", body: "mine")
        let state = CloudLocalSyncState(
            accountID: accountB,
            currentAccountRecords: [
                owned.id: CloudScriptSyncRecord(
                    accountID: accountB,
                    scriptID: owned.id,
                    lastSyncedUpdatedAt: nil
                )
            ],
            scriptIDsOwnedByOtherAccounts: [foreign.id],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
        let library = LibrarySnapshot(
            scripts: [foreign, owned],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let remote = InMemoryCloudLibraryRepository(accountID: accountB)
        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountB,
            input: CloudSyncInput(library: library, state: state),
            repository: remote,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )

        let remoteScripts = try await remote.fetchScripts(accountID: accountB, updatedAfter: nil)
        XCTAssertEqual(remoteScripts.map(\.id), [owned.id])
        XCTAssertFalse(remoteScripts.contains(where: { $0.id == foreign.id }))
        XCTAssertEqual(result.summary.excludedLocalScriptCount, 1)
        XCTAssertTrue(result.mergedLibrary.scripts.contains(where: { $0.id == foreign.id }))
        _ = accountA
    }

    func testTombstoneDeletesExactRemoteAndClearsLocal() async throws {
        let accountID = UUID()
        let scriptID = UUID()
        let remote = ScriptDocument(
            id: scriptID,
            title: "Gone",
            body: "cloud",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: scriptID,
            lastSyncedUpdatedAt: remote.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(remote)
        )
        let tombstone = ScriptDeletionTombstone(
            scriptID: scriptID,
            deletedAt: Date(timeIntervalSince1970: 30)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [scriptID: record],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [scriptID: tombstone],
            tombstonesByFolderID: [:]
        )
        let library = LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: ReaderSettings(),
            seeded: true
        )
        let repo = InMemoryCloudLibraryRepository(accountID: accountID, scripts: [remote])
        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: CloudSyncInput(library: library, state: state),
            repository: repo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )

        XCTAssertTrue(result.mergedLibrary.scripts.isEmpty)
        XCTAssertEqual(result.persistenceUpdate.tombstones, [tombstone])
        let remaining = try await repo.fetchScripts(accountID: accountID, updatedAfter: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testOutlinePointsRoundTripThroughFingerprintAndPlan() throws {
        let accountID = UUID()
        let point = OutlinePoint(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            text: "Act 1",
            note: "Slow down"
        )
        let noteOnly = OutlinePoint(text: "  ", note: "Cue")
        let local = ScriptDocument(
            title: "Talk",
            body: "Hello",
            outline: [point, noteOnly, OutlinePoint(text: " ", note: "\n")],
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [],
            state: .empty(accountID: accountID),
            detectedAt: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(plan.upload.count, 1)
        // Plans preserve the in-memory outline array; the wire codec drops empties.
        XCTAssertEqual(plan.upload.first?.outline.count, 3)
        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(plan.upload[0])
        )
        let encoded = try XCTUnwrap(CloudOutlinePoint.cloudPoints(from: local.outline))
        XCTAssertEqual(encoded.count, 2)
        XCTAssertEqual(encoded.compactMap(\.point), [point, noteOnly])
    }

    func testFolderRenameConflictFailsClosed() throws {
        let accountID = UUID()
        let folderID = UUID()
        let baseline = ScriptFolder(
            id: folderID,
            name: "Shows",
            createdAt: Date(timeIntervalSince1970: 5)
        )
        var local = baseline
        local.name = "Device name"
        var remote = baseline
        remote.name = "Cloud name"
        let record = CloudFolderSyncRecord(
            accountID: accountID,
            folderID: folderID,
            hasSynced: true,
            lastSyncedName: baseline.name,
            lastSyncedCreatedAt: baseline.createdAt
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [folderID: record],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
        XCTAssertThrowsError(
            try CloudFolderSyncPlan.make(
                local: [local],
                remote: [remote],
                state: state,
                detectedAt: Date(timeIntervalSince1970: 40)
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudRepositoryError,
                .folderConflict(device: local, cloud: remote)
            )
        }
    }

    func testSynchronizationLaneRejectsStaleGeneration() {
        var lane = CloudSynchronizationLane()
        let first = lane.begin(accountID: UUID())
        let second = lane.begin(accountID: first.accountID)
        XCTAssertTrue(lane.isActive(second))
        XCTAssertFalse(lane.isActive(first))
        XCTAssertNil(
            lane.resolvedCompletionStatus(
                .succeeded(CloudSyncSummary(
                    uploadedScripts: 0,
                    downloadedScripts: 0,
                    completedAt: .now
                )),
                for: first,
                currentAccountID: first.accountID
            )
        )
        let status = lane.resolvedCompletionStatus(
            .failed("nope"),
            for: second,
            currentAccountID: second.accountID
        )
        XCTAssertEqual(status, .failed("nope"))
        XCTAssertNil(lane.activeToken)
    }

    func testConfigurationRejectsSecretsAndAllowsAbsentOffline() throws {
        XCTAssertNil(try CloudConfiguration.load(infoDictionary: [:], environment: [:]))
        XCTAssertThrowsError(
            try CloudConfiguration(
                projectURL: URL(string: "https://example.supabase.co")!,
                publishableKey: "sb_secret_nope",
                sourcePolicy: .debug
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .privilegedKey)
        }
        let ok = try CloudConfiguration(
            projectURL: URL(string: "https://example.supabase.co")!,
            publishableKey: "sb_publishable_test_key",
            sourcePolicy: .debug
        )
        XCTAssertEqual(ok.projectURL.host, "example.supabase.co")
    }

    func testReleasePinsProductionHostAndIgnoresEnvironmentOverrides() throws {
        let productionURL = CloudConfiguration.productionProjectURLString
        let production = try CloudConfiguration(
            projectURL: URL(string: productionURL)!,
            publishableKey: "sb_publishable_release",
            sourcePolicy: .release
        )
        XCTAssertEqual(production.projectURL.host, CloudConfiguration.productionProjectHost)

        XCTAssertThrowsError(
            try CloudConfiguration(
                projectURL: URL(string: "https://example.supabase.co")!,
                publishableKey: "sb_publishable_release",
                sourcePolicy: .release
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .invalidProjectURL)
        }

        // Release must ignore env even when Info.plist is blank/unresolved.
        let ignoredEnv = try CloudConfiguration.load(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: "$(PHRASA_SUPABASE_URL)",
                CloudConfiguration.publishableKeyInfoKey: "$(PHRASA_SUPABASE_PUBLISHABLE_KEY)",
            ],
            environment: [
                "SUPABASE_URL": productionURL,
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_from_env",
                "EXPO_PUBLIC_SUPABASE_URL": productionURL,
                "EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_expo",
            ],
            sourcePolicy: .release
        )
        XCTAssertNil(ignoredEnv, "Release must ignore env and stay offline for unresolved placeholders")

        let releaseReady = try CloudConfiguration.load(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: productionURL,
                CloudConfiguration.publishableKeyInfoKey: "sb_publishable_plist",
            ],
            environment: [
                "SUPABASE_URL": "https://attacker.example.com",
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_attacker",
            ],
            sourcePolicy: .release
        )
        XCTAssertEqual(releaseReady?.projectURL.host, CloudConfiguration.productionProjectHost)
        XCTAssertEqual(releaseReady?.publishableKey, "sb_publishable_plist")
    }

    func testDebugAllowsLocalhostAndExplicitSupabaseEnvWithoutExpoFallbacks() throws {
        let localhost = try CloudConfiguration(
            projectURL: URL(string: "http://127.0.0.1:54321")!,
            publishableKey: "sb_publishable_local",
            sourcePolicy: .debug
        )
        XCTAssertEqual(localhost.projectURL.host, "127.0.0.1")

        let fromEnv = try CloudConfiguration.load(
            infoDictionary: [:],
            environment: [
                "SUPABASE_URL": "http://localhost:54321",
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_env",
            ],
            sourcePolicy: .debug
        )
        XCTAssertEqual(fromEnv?.projectURL.host, "localhost")
        XCTAssertEqual(fromEnv?.publishableKey, "sb_publishable_env")

        // Legacy Expo env keys must never configure the native client.
        let expoOnly = try CloudConfiguration.load(
            infoDictionary: [:],
            environment: [
                "EXPO_PUBLIC_SUPABASE_URL": "https://uqkjidvqyngrnyftdazp.supabase.co",
                "EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_expo",
                "EXPO_PUBLIC_SUPABASE_ANON_KEY": "sb_publishable_anon",
            ],
            sourcePolicy: .debug
        )
        XCTAssertNil(expoOnly)
    }

    func testSyncInputCountsOnlyPresentProtectedRows() {
        let accountID = UUID()
        let present = ScriptDocument(title: "Other")
        let missingID = UUID()
        let input = CloudSyncInput(
            library: LibrarySnapshot(
                scripts: [present],
                folders: [],
                settings: .init(),
                seeded: true
            ),
            state: CloudLocalSyncState(
                accountID: accountID,
                currentAccountRecords: [:],
                scriptIDsOwnedByOtherAccounts: [present.id, missingID],
                currentAccountFolderRecords: [:],
                folderIDsOwnedByOtherAccounts: [],
                tombstonesByScriptID: [:],
                tombstonesByFolderID: [:]
            )
        )
        XCTAssertEqual(input.excludedLocalScriptCount, 1)
    }

    func testNeverSyncsAudioOrTranscriptFields() throws {
        // Guard: ScriptDocument has no audio/transcript properties; fingerprint
        // covers title/body/outline/tags/source/folder only.
        let script = ScriptDocument(title: "Talk", body: "words", outline: [
            OutlinePoint(text: "Point", note: "Note")
        ])
        let fingerprint = CloudScriptFingerprint.make(script)
        XCTAssertFalse(fingerprint.isEmpty)
        let mirror = Mirror(reflecting: script)
        let labels = Set(mirror.children.compactMap(\.label))
        XCTAssertFalse(labels.contains("audio"))
        XCTAssertFalse(labels.contains("transcript"))
        XCTAssertFalse(labels.contains("audioURL"))
        XCTAssertTrue(labels.contains("outline"))
        XCTAssertTrue(labels.contains("body"))
    }

    func testDirtyEditorHostStateDefersAndBlocksEnginePushPull() async throws {
        let dirty = CloudSyncHostDirtyState(unpersistedEditorScriptCount: 2)
        XCTAssertEqual(
            dirty.eligibility,
            .deferred(.editorContentNotPersisted(scriptCount: 2))
        )
        XCTAssertThrowsError(try CloudSyncEligibilityGate.requireEligible(dirty)) { error in
            XCTAssertEqual(
                error as? CloudSyncEligibilityError,
                .deferred(.editorContentNotPersisted(scriptCount: 2))
            )
        }

        let accountID = UUID()
        let library = LibrarySnapshot(
            scripts: [ScriptDocument(title: "Staged", body: "unsaved")],
            folders: [],
            settings: .init(),
            seeded: true
        )
        let input = CloudSyncInput(
            library: library,
            state: .empty(accountID: accountID)
        )
        let repo = CountingInMemoryCloudLibraryRepository(accountID: accountID)
        do {
            _ = try await LibrarySyncEngine.synchronize(
                accountID: accountID,
                input: input,
                repository: repo,
                preflight: CloudSyncPreflight.requireLiveHost {
                    dirty
                }
            )
            XCTFail("Engine must refuse push/pull while editor content is unpersisted")
        } catch {
            XCTAssertEqual(
                error as? CloudSyncEligibilityError,
                .deferred(.editorContentNotPersisted(scriptCount: 2))
            )
        }
        let calls = await repo.totalRemoteCalls
        XCTAssertEqual(calls, 0, "Dirty preflight must make zero repository calls")

        XCTAssertEqual(CloudSyncHostDirtyState.clean.eligibility, .eligible)
        let cleanResult = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: input,
            repository: repo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertEqual(cleanResult.summary.uploadedScripts, 1)
    }

    func testLivePreflightStagingDraftAfterPrepareBeforeRemoteMakesZeroRepositoryCalls() async throws {
        let accountID = UUID()
        let script = ScriptDocument(title: "Prepared", body: "durable")
        let library = LibrarySnapshot(
            scripts: [script],
            folders: [],
            settings: .init(),
            seeded: true
        )
        let input = CloudSyncInput(
            library: library,
            state: .empty(accountID: accountID)
        )
        let repo = CountingInMemoryCloudLibraryRepository(accountID: accountID)

        // Deterministic race: prepare already succeeded with clean state; the
        // barrier/preflight stages a draft at the final gate immediately before
        // remote access and must fail closed with zero repository calls.
        final class DirtyGate: @unchecked Sendable {
            var dirtyCount = 0
            let lock = NSLock()
            func stageDraft() {
                lock.lock()
                dirtyCount = 1
                lock.unlock()
            }
            func snapshot() -> CloudSyncHostDirtyState {
                lock.lock()
                defer { lock.unlock() }
                return CloudSyncHostDirtyState(unpersistedEditorScriptCount: dirtyCount)
            }
        }
        let gate = DirtyGate()
        let preflight: CloudSyncPreflightValidator = {
            gate.stageDraft()
            try CloudSyncEligibilityGate.requireEligible(gate.snapshot())
        }

        do {
            _ = try await LibrarySyncEngine.synchronize(
                accountID: accountID,
                input: input,
                repository: repo,
                preflight: preflight
            )
            XCTFail("Staged draft at final preflight must defer sync")
        } catch {
            XCTAssertEqual(
                error as? CloudSyncEligibilityError,
                .deferred(.editorContentNotPersisted(scriptCount: 1))
            )
        }
        let calls = await repo.totalRemoteCalls
        XCTAssertEqual(calls, 0)
        let writes = await repo.writeCallCount
        XCTAssertEqual(writes, 0)
    }

    func testLocalOnlyPreferencesSkipSettingsWrite() async throws {
        let accountID = UUID()
        var localSettings = ReaderSettings()
        localSettings.theme = .contrast
        var remoteSettings = ReaderSettings()
        remoteSettings.theme = .sepia
        let library = LibrarySnapshot(
            scripts: [ScriptDocument(title: "Talk", body: "words")],
            folders: [],
            settings: localSettings,
            seeded: true
        )
        let repo = InMemoryCloudLibraryRepository(
            accountID: accountID,
            settings: remoteSettings
        )
        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: CloudSyncInput(library: library, state: .empty(accountID: accountID)),
            preferences: .localOnly,
            repository: repo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertEqual(result.mergedLibrary.settings.theme, .contrast)
        let stillRemote = try await repo.fetchSettings(accountID: accountID)
        XCTAssertEqual(stillRemote?.theme, .sepia, "localOnly must not overwrite cloud settings")
    }

    func testPreparationOutcomeCarriesDeferredReasonWithoutInput() {
        let reason = CloudSyncDeferredReason.editorContentNotPersisted(scriptCount: 1)
        let outcome = CloudSyncPreparationOutcome.deferred(reason)
        if case .deferred(let deferred) = outcome {
            XCTAssertEqual(deferred, reason)
            XCTAssertTrue(deferred.userFacingMessage.contains("Save your editor changes"))
        } else {
            XCTFail("Expected deferred preparation outcome")
        }
        XCTAssertEqual(
            CloudSyncStatus.deferred(reason),
            .deferred(.editorContentNotPersisted(scriptCount: 1))
        )
    }

    /// User settings are preference-resolved (not script three-way merge).
    /// `restoreFromCloud` installs remote when present; `keepThisDevice` pushes
    /// local. Protected/quarantine surface remains independent of settings.
    func testUserSettingsPreferenceRestoreFromCloudAndKeepLocal() async throws {
        let accountID = UUID()
        var localSettings = ReaderSettings()
        localSettings.speedWPM = 140
        localSettings.theme = .paper
        localSettings.normalize()
        var remoteSettings = ReaderSettings()
        remoteSettings.speedWPM = 210
        remoteSettings.theme = .contrast
        remoteSettings.normalize()

        let library = LibrarySnapshot(
            scripts: [],
            folders: [],
            settings: localSettings,
            seeded: true
        )
        let input = CloudSyncInput(
            library: library,
            state: .empty(accountID: accountID)
        )

        let restoreRepo = InMemoryCloudLibraryRepository(
            accountID: accountID,
            settings: remoteSettings
        )
        let restored = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: input,
            preferences: .restoreFromCloud,
            repository: restoreRepo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertEqual(restored.mergedLibrary.settings.speedWPM, 210)
        XCTAssertEqual(restored.mergedLibrary.settings.theme, .contrast)

        let keepRepo = InMemoryCloudLibraryRepository(
            accountID: accountID,
            settings: remoteSettings
        )
        let kept = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: input,
            preferences: .keepThisDevice,
            repository: keepRepo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertEqual(kept.mergedLibrary.settings.speedWPM, 140)
        XCTAssertEqual(kept.mergedLibrary.settings.theme, .paper)
        let savedRemote = try await keepRepo.fetchSettings(accountID: accountID)
        XCTAssertEqual(savedRemote?.speedWPM, 140)
    }

    func testTimestampOCCPrecisionRejectsSubMillisecondStaleDelete() async throws {
        let older = Date(timeIntervalSince1970: Double(1_700_000_000_100_000) / 1_000_000)
        let newer = Date(timeIntervalSince1970: Double(1_700_000_000_100_500) / 1_000_000)
        XCTAssertFalse(CloudTimestampPrecision.matches(older, newer))
        XCTAssertEqual(
            CloudTimestampPrecision.microseconds(newer) - CloudTimestampPrecision.microseconds(older),
            500
        )

        let accountID = UUID()
        let remote = ScriptDocument(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "OCC",
            body: "x",
            updatedAt: newer
        )
        let repo = InMemoryCloudLibraryRepository(accountID: accountID, scripts: [remote])
        do {
            try await repo.deleteScript(
                expected: ScriptDocument(
                    id: remote.id,
                    title: remote.title,
                    body: remote.body,
                    updatedAt: older
                ),
                accountID: accountID
            )
            XCTFail("Sub-millisecond stale expected must fail closed")
        } catch {
            XCTAssertEqual(error as? CloudRepositoryError, .newerRemoteEdit)
        }
        try await repo.deleteScript(
            expected: ScriptDocument(
                id: remote.id,
                title: remote.title,
                body: remote.body,
                updatedAt: CloudTimestampPrecision.normalized(newer)
            ),
            accountID: accountID
        )
        let afterDelete = try await repo.fetchScript(id: remote.id, accountID: accountID)
        XCTAssertNil(afterDelete)
    }

    // MARK: - Wire millisecond boundary (production QA evidence)

    /// Wire ms is stable for already-ms Dates; lastOpenedAt uses wire satisfaction;
    /// fingerprint is UUID + editable content only; updatedAt OCC stays µs-exact.
    func testWirePrecisionLastOpenedAndStableMsWithoutWeakeningUpdatedAtOCC() {
        // Already-ms Date must not slip under stable wire canonicalization.
        let exactMs = Date(timeIntervalSince1970: 1_784_520_732.734_000)
        XCTAssertEqual(CloudTimestampPrecision.wireMilliseconds(exactMs), 1_784_520_732_734)
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(
                CloudTimestampPrecision.wireNormalized(exactMs)
            ),
            1_784_520_732_734
        )

        // Sub-ms open still collapses to the same wire ms as the server echo.
        let localOpened = Date(timeIntervalSince1970: 1_784_520_732.746_402)
        let serverOpened = Date(timeIntervalSince1970: 1_784_520_732.746_000)
        XCTAssertLessThan(
            CloudTimestampPrecision.microseconds(serverOpened),
            CloudTimestampPrecision.microseconds(localOpened)
        )
        XCTAssertTrue(CloudTimestampPrecision.wireIsAtLeast(serverOpened, localOpened))

        let id = UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!
        var local = ScriptDocument(
            id: id,
            title: "Stage notes",
            body: "Matched content",
            tags: ["sync-qa"],
            lastOpenedAt: localOpened,
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_980),
            updatedAt: Date(timeIntervalSince1970: 1_784_520_741.598_824)
        )
        var server = local
        // Damaged/drifted created_at from a prior buggy content update (.734 → .733).
        server.createdAt = Date(timeIntervalSince1970: 1_784_520_732.733_000)
        server.updatedAt = Date(timeIntervalSince1970: 1_784_520_741.598_000)
        server.lastOpenedAt = serverOpened

        // Fingerprint ignores createdAt: UUID + editable content only.
        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(server)
        )
        XCTAssertTrue(
            CloudScriptWrite(desired: local, expectedRemote: nil)
                .currentMatchesDesired(server)
        )

        // Genuinely older open (previous millisecond) does not cover desired.
        var olderOpen = server
        olderOpen.lastOpenedAt = Date(timeIntervalSince1970: 1_784_520_732.745_000)
        XCTAssertFalse(
            CloudScriptWrite(desired: local, expectedRemote: nil)
                .currentMatchesDesired(olderOpen)
        )

        // Editable content still diverges fingerprints (tags).
        var differentTags = local
        differentTags.tags = ["handoff"]
        XCTAssertNotEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(differentTags)
        )

        // createdAt-only drift is not a content conflict.
        var onlyCreateDrift = local
        onlyCreateDrift.createdAt = Date(timeIntervalSince1970: 1_784_520_732.735_000)
        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(onlyCreateDrift)
        )

        // updatedAt OCC remains microsecond-exact and unchanged.
        let olderUpdated = Date(timeIntervalSince1970: Double(1_700_000_000_100_000) / 1_000_000)
        let halfMsNewer = Date(timeIntervalSince1970: Double(1_700_000_000_100_500) / 1_000_000)
        XCTAssertFalse(CloudTimestampPrecision.matches(olderUpdated, halfMsNewer))
        XCTAssertEqual(
            CloudTimestampPrecision.microseconds(halfMsNewer)
                - CloudTimestampPrecision.microseconds(olderUpdated),
            500
        )
        local.updatedAt = olderUpdated
        server.updatedAt = halfMsNewer
        XCTAssertEqual(CloudScriptFingerprint.make(local), CloudScriptFingerprint.make(server))
        XCTAssertFalse(CloudScriptVersion.matches(local, server))
    }

    /// Wire-truncated lastOpenedAt must not force CloudScriptVersion mismatch or
    /// repeat open uploads when content is identical.
    func testCloudScriptVersionWireLastOpenedDoesNotForceRepeatUpload() {
        let id = UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!
        var local = ScriptDocument(
            id: id,
            title: "Open recency",
            body: "same",
            lastOpenedAt: Date(timeIntervalSince1970: 1_784_520_732.746_402),
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_980),
            updatedAt: Date(timeIntervalSince1970: 1_784_520_741.598_000)
        )
        var remote = local
        remote.lastOpenedAt = Date(timeIntervalSince1970: 1_784_520_732.746_000)
        remote.createdAt = Date(timeIntervalSince1970: 1_784_520_732.734_000)

        // Same updatedAt at µs (server-echoed) + wire-equal lastOpenedAt.
        XCTAssertTrue(CloudScriptVersion.matches(
            CloudScriptVersion.mergingMetadata(contentFrom: remote, local: local, remote: remote),
            remote
        ))

        let merged = CloudScriptVersion.mergingMetadata(
            contentFrom: remote,
            local: local,
            remote: remote
        )
        XCTAssertTrue(
            CloudTimestampPrecision.wireMatches(merged.lastOpenedAt, remote.lastOpenedAt)
        )
        // Merged open is wire-normalized; must not re-upload solely for sub-ms noise.
        XCTAssertTrue(CloudScriptVersion.matches(merged, remote))

        // True multi-ms newer open still advances.
        local.lastOpenedAt = Date(timeIntervalSince1970: 1_784_520_732.750_402)
        let advanced = CloudScriptVersion.mergingMetadata(
            contentFrom: local,
            local: local,
            remote: remote
        )
        XCTAssertTrue(
            CloudTimestampPrecision.wireIsAtLeast(
                try XCTUnwrap(advanced.lastOpenedAt),
                try XCTUnwrap(local.lastOpenedAt)
            )
        )
        XCTAssertFalse(CloudScriptVersion.matches(advanced, remote))
    }

    /// Simulates Supabase insert + open reconciliation: truncates createdAt and
    /// lastOpenedAt to wire ms, then validates with currentMatchesDesired the way
    /// SupabaseCloudRepository does on insert and updateLastOpenedIfNeeded.
    func testInitialUploadWithWireTruncatedCreatedAtAndLastOpenedAtDoesNotFail() async throws {
        let accountID = UUID()
        // Exact production-shaped desired row that failed Release Mac QA.
        var local = ScriptDocument(
            id: UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!,
            title: "Opening remarks",
            body: "Hello stage",
            lastOpenedAt: Date(timeIntervalSince1970: 1_784_520_732.746_402),
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_980),
            updatedAt: Date(timeIntervalSince1970: 1_784_520_741.598_824)
        )
        let repo = WireTruncatingCloudLibraryRepository(accountID: accountID)

        // Direct insert path mirrors SupabaseCloudRepository.insertScript.
        let write = CloudScriptWrite(desired: local, expectedRemote: nil)
        let echoed = try await repo.writeScripts([write], accountID: accountID)
        XCTAssertEqual(echoed.count, 1)
        let serverRow = try XCTUnwrap(echoed.first)
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(serverRow.createdAt),
            CloudTimestampPrecision.wireMilliseconds(local.createdAt)
        )
        XCTAssertNotEqual(
            CloudTimestampPrecision.microseconds(serverRow.createdAt),
            CloudTimestampPrecision.microseconds(local.createdAt)
        )
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(try XCTUnwrap(serverRow.lastOpenedAt)),
            CloudTimestampPrecision.wireMilliseconds(try XCTUnwrap(local.lastOpenedAt))
        )
        XCTAssertLessThan(
            CloudTimestampPrecision.microseconds(try XCTUnwrap(serverRow.lastOpenedAt)),
            CloudTimestampPrecision.microseconds(try XCTUnwrap(local.lastOpenedAt))
        )
        XCTAssertTrue(
            write.currentMatchesDesired(serverRow),
            "Insert must accept wire-truncated createdAt + lastOpenedAt server echo"
        )

        // Metadata-only open update path: desired still sub-ms, current already
        // wire-truncated from insert — must not throw incompleteRemoteSnapshot.
        let openWrite = CloudScriptWrite(desired: local, expectedRemote: serverRow)
        let afterOpen = try await repo.writeScripts([openWrite], accountID: accountID)
        XCTAssertEqual(afterOpen.count, 1)
        XCTAssertTrue(openWrite.currentMatchesDesired(try XCTUnwrap(afterOpen.first)))

        // Full engine path: first upload establishes a baseline; no false conflict.
        let firstInput = CloudSyncInput(
            library: LibrarySnapshot(
                scripts: [local],
                folders: [],
                settings: .init(),
                seeded: true
            ),
            state: .empty(accountID: accountID)
        )
        await repo.reset(accountID: accountID)

        let first = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: firstInput,
            repository: repo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertEqual(first.summary.uploadedScripts, 1)
        XCTAssertEqual(first.persistenceUpdate.records.count, 1)
        XCTAssertFalse(
            first.mergedLibrary.scripts.contains { $0.title.contains("Local conflict") }
        )
        let baseline = try XCTUnwrap(first.persistenceUpdate.records.first)
        XCTAssertEqual(
            baseline.lastSyncedFingerprint,
            CloudScriptFingerprint.make(local)
        )

        // Second pass: local still sub-ms, remote wire-truncated, baseline set.
        let remoteOptional = try await repo.fetchScript(id: local.id, accountID: accountID)
        let remote = try XCTUnwrap(remoteOptional)
        let secondState = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [local.id: baseline],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: secondState,
            detectedAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertFalse(plan.applyLocally.contains { $0.title.contains("Local conflict") })
        XCTAssertFalse(plan.upload.contains { $0.title.contains("Local conflict") })
        // Sub-ms open noise must not force a content re-upload.
        XCTAssertTrue(
            plan.upload.isEmpty
                || plan.upload.allSatisfy {
                    CloudScriptFingerprint.make($0) == CloudScriptFingerprint.make(local)
                }
        )
        XCTAssertEqual(plan.records.count, 1)

        // No-baseline retry after a prior insert left a remote row.
        let noBaselinePlan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: .empty(accountID: accountID),
            detectedAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertFalse(noBaselinePlan.applyLocally.contains { $0.title.contains("Local conflict") })
        XCTAssertFalse(noBaselinePlan.upload.contains { $0.title.contains("Local conflict") })
        XCTAssertEqual(
            noBaselinePlan.records.first?.lastSyncedFingerprint,
            CloudScriptFingerprint.make(local)
        )

        // Advance open by a full millisecond: plan should still be content-safe.
        local.lastOpenedAt = Date(timeIntervalSince1970: 1_784_520_732.750_402)
        let advancedPlan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: secondState,
            detectedAt: Date(timeIntervalSince1970: 2_001)
        )
        XCTAssertFalse(advancedPlan.upload.contains { $0.title.contains("Local conflict") })
        if let upload = advancedPlan.upload.first {
            XCTAssertEqual(CloudScriptFingerprint.make(upload), CloudScriptFingerprint.make(local))
            XCTAssertTrue(
                CloudTimestampPrecision.wireIsAtLeast(
                    try XCTUnwrap(upload.lastOpenedAt),
                    try XCTUnwrap(local.lastOpenedAt)
                )
            )
        }
    }

    /// Production third failure: tags edit applied, server returned authoritative
    /// updated_at, but created_at slipped .734 → .733. Fingerprint must accept
    /// the successful response; retry must not invent a Local conflict.
    func testExistingContentUpdateWithCreatedAtDriftIsAcceptedAndRetryIsClean() async throws {
        let accountID = UUID()
        let id = UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!
        let baselineCreated = Date(timeIntervalSince1970: 1_784_520_732.734_000)
        let baselineUpdated = Date(timeIntervalSince1970: 1_784_520_741.598_000)
        var remote = ScriptDocument(
            id: id,
            title: "QA script",
            body: "body",
            tags: ["prior"],
            lastOpenedAt: Date(timeIntervalSince1970: 1_784_520_732.746_000),
            createdAt: baselineCreated,
            updatedAt: baselineUpdated
        )
        var local = remote
        local.tags = ["sync-qa", "handoff"]
        local.updatedAt = Date(timeIntervalSince1970: 1_784_521_301.793_238)

        let repo = WireTruncatingCloudLibraryRepository(accountID: accountID)
        // Seed remote at baseline (already wire-aligned createdAt).
        _ = try await repo.writeScripts(
            [CloudScriptWrite(desired: remote, expectedRemote: nil)],
            accountID: accountID
        )
        // Simulate server that already has baseline; content update drifts created_at.
        await repo.setDriftCreatedAtOnNextContentUpdate(byMilliseconds: -1)

        let baselineRecord = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: id,
            lastSyncedUpdatedAt: baselineUpdated,
            lastSyncedFingerprint: CloudScriptFingerprint.make(remote)
        )
        let write = CloudScriptWrite(desired: local, expectedRemote: remote)
        let echoed = try await repo.writeScripts([write], accountID: accountID)
        let serverRow = try XCTUnwrap(echoed.first)
        XCTAssertEqual(serverRow.tags, ["sync-qa", "handoff"])
        // Drifted created_at like production .734 → .733.
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(serverRow.createdAt),
            1_784_520_732_733
        )
        XCTAssertNotEqual(
            CloudTimestampPrecision.wireMilliseconds(serverRow.createdAt),
            CloudTimestampPrecision.wireMilliseconds(local.createdAt)
        )
        XCTAssertTrue(
            write.currentMatchesDesired(serverRow),
            "Successful content update with created_at drift must be accepted"
        )
        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(serverRow)
        )

        // Engine path: upload tags, establish new baseline; no Local conflict.
        let input = CloudSyncInput(
            library: LibrarySnapshot(
                scripts: [local],
                folders: [],
                settings: .init(),
                seeded: true
            ),
            state: CloudLocalSyncState(
                accountID: accountID,
                currentAccountRecords: [id: baselineRecord],
                scriptIDsOwnedByOtherAccounts: [],
                currentAccountFolderRecords: [:],
                folderIDsOwnedByOtherAccounts: [],
                tombstonesByScriptID: [:],
                tombstonesByFolderID: [:]
            )
        )
        // Reset seed + drift for a clean engine run against already-remote row.
        await repo.reset(accountID: accountID)
        remote.tags = ["prior"]
        remote.createdAt = baselineCreated
        remote.updatedAt = baselineUpdated
        _ = try await repo.writeScripts(
            [CloudScriptWrite(desired: remote, expectedRemote: nil)],
            accountID: accountID
        )
        await repo.setDriftCreatedAtOnNextContentUpdate(byMilliseconds: -1)

        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: input,
            repository: repo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertEqual(result.summary.uploadedScripts, 1)
        XCTAssertFalse(
            result.mergedLibrary.scripts.contains { $0.title.contains("Local conflict") }
        )
        let newBaseline = try XCTUnwrap(result.persistenceUpdate.records.first)
        XCTAssertEqual(
            newBaseline.lastSyncedFingerprint,
            CloudScriptFingerprint.make(local)
        )

        // Retry with local still on .734 and remote on drifted .733 + new tags.
        let remoteAfterOptional = try await repo.fetchScript(id: id, accountID: accountID)
        let remoteAfter = try XCTUnwrap(remoteAfterOptional)
        let retryPlan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remoteAfter],
            state: CloudLocalSyncState(
                accountID: accountID,
                currentAccountRecords: [id: newBaseline],
                scriptIDsOwnedByOtherAccounts: [],
                currentAccountFolderRecords: [:],
                folderIDsOwnedByOtherAccounts: [],
                tombstonesByScriptID: [:],
                tombstonesByFolderID: [:]
            ),
            detectedAt: Date(timeIntervalSince1970: 9_000)
        )
        XCTAssertFalse(retryPlan.upload.contains { $0.title.contains("Local conflict") })
        XCTAssertFalse(retryPlan.applyLocally.contains { $0.title.contains("Local conflict") })
        // Content already agrees; no forced re-upload of tags.
        XCTAssertTrue(
            retryPlan.upload.isEmpty
                || retryPlan.upload.allSatisfy {
                    CloudScriptFingerprint.make($0) == CloudScriptFingerprint.make(local)
                }
        )
    }

    /// Fourth production failure: content already matches remote (tags applied),
    /// created_at drifted .734→.733, baseline still OLD v1 fingerprint, local
    /// open `.872156` vs remote `.871`. Plan must metadata-only advance open;
    /// must not throw scriptConflict; baseline must re-anchor to v2.
    func testProductionMetadataOnlyOpenAdvanceHealsOldV1BaselineWithoutContentConflict() async throws {
        let accountID = UUID()
        let id = UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!

        // Exact local durable row after third-fix partial heal.
        let local = ScriptDocument(
            id: id,
            title: "QA script",
            body: "body",
            source: .manual,
            folderID: nil,
            tags: ["sync-qa", "handoff"],
            outline: [],
            lastOpenedAt: Date(timeIntervalSince1970: 1_784_521_290.872_156),
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_000),
            updatedAt: Date(timeIntervalSince1970: 1_784_521_301.793_238)
        )
        // Exact remote after successful tags update (created_at drift, server clocks).
        let remote = ScriptDocument(
            id: id,
            title: "QA script",
            body: "body",
            source: .manual,
            folderID: nil,
            tags: ["sync-qa", "handoff"],
            outline: [],
            lastOpenedAt: Date(timeIntervalSince1970: 1_784_521_290.871_000),
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.733_000),
            updatedAt: Date(timeIntervalSince1970: 1_784_521_303.075_535)
        )

        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(remote),
            "v2 fingerprints ignore createdAt drift and match on editable content"
        )
        XCTAssertTrue(
            CloudScriptOpenUpdate.needsAdvancement(
                desired: local.lastOpenedAt,
                current: remote.lastOpenedAt
            )
        )

        // Stale v1-era baseline (wrong hash; not equal to either v2 fingerprint).
        let staleV1Fingerprint = "b1be6d8d00000000000000000000000000000000000000000000000000000000"
        let staleBaseline = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: id,
            lastSyncedUpdatedAt: Date(timeIntervalSince1970: 1_784_520_741.598_000),
            lastSyncedFingerprint: staleV1Fingerprint
        )
        XCTAssertNotEqual(staleV1Fingerprint, CloudScriptFingerprint.make(local))
        XCTAssertNotEqual(staleV1Fingerprint, CloudScriptFingerprint.make(remote))

        // Plan: matching content + stale baseline → reconcile, open-only upload.
        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: CloudLocalSyncState(
                accountID: accountID,
                currentAccountRecords: [id: staleBaseline],
                scriptIDsOwnedByOtherAccounts: [],
                currentAccountFolderRecords: [:],
                folderIDsOwnedByOtherAccounts: [],
                tombstonesByScriptID: [:],
                tombstonesByFolderID: [:]
            ),
            detectedAt: Date(timeIntervalSince1970: 9_000)
        )
        XCTAssertFalse(plan.upload.contains { $0.title.contains("Local conflict") })
        XCTAssertEqual(plan.upload.count, 1, "Open advancement must upload merged metadata")
        let desired = try XCTUnwrap(plan.upload.first)
        XCTAssertEqual(CloudScriptFingerprint.make(desired), CloudScriptFingerprint.make(remote))
        XCTAssertTrue(
            CloudScriptOpenUpdate.needsAdvancement(
                desired: desired.lastOpenedAt,
                current: remote.lastOpenedAt
            )
        )

        // Repository boundary: open OCC is updated_at only (not last_opened_at).
        let repo = WireTruncatingCloudLibraryRepository(accountID: accountID)
        // Seed exact remote row (preserve authoritative updated_at / open).
        await repo.seedExact(remote)

        let write = CloudScriptWrite(desired: desired, expectedRemote: remote)
        // Direct write path mirrors Supabase updateLastOpenedIfNeeded.
        let written = try await repo.writeScripts([write], accountID: accountID)
        let afterOpen = try XCTUnwrap(written.first)
        XCTAssertTrue(write.currentMatchesDesired(afterOpen))
        XCTAssertTrue(
            CloudTimestampPrecision.wireIsAtLeast(
                try XCTUnwrap(afterOpen.lastOpenedAt),
                try XCTUnwrap(desired.lastOpenedAt)
            )
        )
        // Content untouched; created_at drift preserved (not rewritten).
        XCTAssertEqual(afterOpen.tags, ["sync-qa", "handoff"])
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(afterOpen.createdAt),
            1_784_520_732_733
        )

        // Full engine: heal baseline, no scriptConflict / Local conflict.
        let input = CloudSyncInput(
            library: LibrarySnapshot(
                scripts: [local],
                folders: [],
                settings: .init(),
                seeded: true
            ),
            state: CloudLocalSyncState(
                accountID: accountID,
                currentAccountRecords: [id: staleBaseline],
                scriptIDsOwnedByOtherAccounts: [],
                currentAccountFolderRecords: [:],
                folderIDsOwnedByOtherAccounts: [],
                tombstonesByScriptID: [:],
                tombstonesByFolderID: [:]
            )
        )
        await repo.reset(accountID: accountID)
        await repo.seedExact(remote)

        let result = try await LibrarySyncEngine.synchronize(
            accountID: accountID,
            input: input,
            repository: repo,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertFalse(
            result.mergedLibrary.scripts.contains { $0.title.contains("Local conflict") }
        )
        let healed = try XCTUnwrap(result.persistenceUpdate.records.first)
        XCTAssertEqual(healed.lastSyncedFingerprint, CloudScriptFingerprint.make(local))
        XCTAssertNotEqual(healed.lastSyncedFingerprint, staleV1Fingerprint)

        let remoteFinalOptional = try await repo.fetchScript(id: id, accountID: accountID)
        let remoteFinal = try XCTUnwrap(remoteFinalOptional)
        XCTAssertTrue(
            CloudTimestampPrecision.wireIsAtLeast(
                try XCTUnwrap(remoteFinal.lastOpenedAt),
                Date(timeIntervalSince1970: 1_784_521_290.872_000)
            )
        )
        // updated_at OCC precision still rejects half-ms stale content deletes.
        let older = Date(timeIntervalSince1970: Double(1_700_000_000_100_000) / 1_000_000)
        let newer = Date(timeIntervalSince1970: Double(1_700_000_000_100_500) / 1_000_000)
        XCTAssertFalse(CloudTimestampPrecision.matches(older, newer))
    }

    func testOpenUpdatePolicyIdentityScopeAndMonotonicFilter() {
        XCTAssertEqual(
            CloudScriptOpenUpdate.scopeFilterColumns,
            ["id", "user_id"]
        )
        XCTAssertFalse(CloudScriptOpenUpdate.scopeFilterColumns.contains("last_opened_at"))
        XCTAssertFalse(CloudScriptOpenUpdate.scopeFilterColumns.contains("updated_at"))
        let desired = Date(timeIntervalSince1970: 1_784_521_290.872_156)
        let current = Date(timeIntervalSince1970: 1_784_521_290.871_000)
        XCTAssertTrue(CloudScriptOpenUpdate.needsAdvancement(desired: desired, current: current))
        let openToWrite = CloudScriptOpenUpdate.valueToWrite(desired: desired)
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(openToWrite),
            1_784_521_290_872
        )
        let filter = CloudScriptOpenUpdate.monotonicOpenOrFilter(
            openToWrite: openToWrite,
            timestamp: { date in
                // Mirror SupabaseCloudRepository.timestamp shape for the test.
                let us = CloudTimestampPrecision.microseconds(date)
                let whole = us / 1_000_000
                let frac = us % 1_000_000
                return "2026-07-20T00:00:\(String(format: "%02d", Int(whole % 60))).\(String(format: "%06d", frac))Z"
            }
        )
        XCTAssertTrue(filter.contains("last_opened_at.is.null"))
        XCTAssertTrue(filter.contains("last_opened_at.lt.\""))
        XCTAssertTrue(filter.contains("\""))
        XCTAssertFalse(filter.contains("last_opened_at.eq."))
    }

    /// Stale open write must not regress a newer concurrent open when updated_at
    /// is unchanged (the race the pure updated_at-only OCC allowed).
    func testStaleOpenWriteDoesNotRegressNewerOpenUnderSameUpdatedAt() async throws {
        let accountID = UUID()
        let id = UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!
        let updated = Date(timeIntervalSince1970: 1_784_521_303.075_535)
        let newerOpen = Date(timeIntervalSince1970: 1_784_521_290.875_000)
        let staleOpen = Date(timeIntervalSince1970: 1_784_521_290.872_156)

        let remote = ScriptDocument(
            id: id,
            title: "QA script",
            body: "body",
            tags: ["sync-qa", "handoff"],
            lastOpenedAt: newerOpen,
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.733_000),
            updatedAt: updated
        )
        let repo = WireTruncatingCloudLibraryRepository(accountID: accountID)
        await repo.seedExact(remote)

        var staleDesired = remote
        staleDesired.lastOpenedAt = staleOpen
        let write = CloudScriptWrite(desired: staleDesired, expectedRemote: remote)
        let written = try await repo.writeScripts([write], accountID: accountID)
        let after = try XCTUnwrap(written.first)
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(try XCTUnwrap(after.lastOpenedAt)),
            CloudTimestampPrecision.wireMilliseconds(newerOpen),
            "Monotonic open filter must keep the newer concurrent open"
        )
        XCTAssertTrue(
            CloudTimestampPrecision.matches(after.updatedAt, updated),
            "Open-only path must not rewrite updated_at"
        )
    }

    /// Open path with stale updated_at after remote content moved must fail closed
    /// and must not rewrite server open/content.
    func testOpenPathStaleOCCAgainstMovedContentFailsClosed() async throws {
        let accountID = UUID()
        let id = UUID()
        let priorUpdated = Date(timeIntervalSince1970: 100)
        let moved = ScriptDocument(
            id: id,
            title: "Remote",
            body: "server moved",
            tags: ["a"],
            lastOpenedAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        let repo = WireTruncatingCloudLibraryRepository(accountID: accountID)
        await repo.seedExact(moved)

        var openOnly = moved
        openOnly.body = "local still old content"
        openOnly.lastOpenedAt = Date(timeIntervalSince1970: 60)
        openOnly.updatedAt = priorUpdated
        let staleExpected = ScriptDocument(
            id: id,
            title: "Remote",
            body: "remote body",
            tags: ["a"],
            lastOpenedAt: Date(timeIntervalSince1970: 50),
            updatedAt: priorUpdated
        )
        do {
            _ = try await repo.writeScripts(
                [CloudScriptWrite(desired: openOnly, expectedRemote: staleExpected)],
                accountID: accountID
            )
            XCTFail("Stale updated_at OCC against moved content must fail closed")
        } catch {
            XCTAssertEqual(error as? CloudRepositoryError, .scriptConflict(openOnly))
        }
        let stillOptional = try await repo.fetchScript(id: id, accountID: accountID)
        let still = try XCTUnwrap(stillOptional)
        XCTAssertEqual(still.body, "server moved")
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(try XCTUnwrap(still.lastOpenedAt)),
            50_000 // 50.000 wire ms from epoch seconds
        )
    }

    func testProtectedLocalContentSurfacesQuarantineCounts() {
        let foreign = ScriptDocument(title: "Quarantined")
        let input = CloudSyncInput(
            library: LibrarySnapshot(
                scripts: [foreign],
                folders: [],
                settings: .init(),
                seeded: true
            ),
            state: CloudLocalSyncState(
                accountID: UUID(),
                currentAccountRecords: [:],
                scriptIDsOwnedByOtherAccounts: [foreign.id],
                currentAccountFolderRecords: [:],
                folderIDsOwnedByOtherAccounts: [],
                tombstonesByScriptID: [:],
                tombstonesByFolderID: [:]
            )
        )
        XCTAssertEqual(input.protectedLocalContent.scriptCount, 1)
        XCTAssertTrue(input.protectedLocalContent.adoptionRequiredOrQuarantined)
        XCTAssertFalse(input.protectedLocalContent.isEmpty)
    }
}

/// Mirrors Supabase insert/update wire behavior for precision tests.
///
/// - Insert: truncates createdAt / lastOpenedAt / updatedAt to wire ms.
/// - Content update (expectedRemote set, fingerprint differs): applies editable
///   fields, assigns a new authoritative updatedAt, **does not rewrite**
///   createdAt from desired (correct shipping behavior). Optional one-shot
///   createdAt drift simulates the legacy buggy encoder for healing tests.
/// - Open-only update: OCC on exact µs `updatedAt` only (not `last_opened_at`),
///   matching shipping `CloudScriptOpenUpdate` policy.
private actor WireTruncatingCloudLibraryRepository: CloudLibraryRepository {
    private var accountID: UUID
    private var scripts: [UUID: ScriptDocument] = [:]
    private var folders: [UUID: ScriptFolder] = [:]
    private var settings: ReaderSettings?
    private var driftCreatedAtOnNextContentUpdateMs: Int64?
    /// Legacy buggy adapter: require exact last_opened OCC (production failure).
    private var requireLastOpenedOCC = false

    init(accountID: UUID) {
        self.accountID = accountID
    }

    func reset(accountID: UUID) {
        self.accountID = accountID
        scripts = [:]
        folders = [:]
        settings = nil
        driftCreatedAtOnNextContentUpdateMs = nil
        requireLastOpenedOCC = false
    }

    func seedExact(_ script: ScriptDocument) {
        scripts[script.id] = script
    }

    func setDriftCreatedAtOnNextContentUpdate(byMilliseconds delta: Int64) {
        driftCreatedAtOnNextContentUpdateMs = delta
    }

    func setRequireLastOpenedOCC(_ value: Bool) {
        requireLastOpenedOCC = value
    }

    func fetchScripts(accountID: UUID, updatedAfter: Date?) async throws -> [ScriptDocument] {
        try verify(accountID)
        return Array(scripts.values).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func fetchScript(id: UUID, accountID: UUID) async throws -> ScriptDocument? {
        try verify(accountID)
        return scripts[id]
    }

    func writeScripts(
        _ writes: [CloudScriptWrite],
        accountID: UUID
    ) async throws -> [ScriptDocument] {
        try verify(accountID)
        var written: [ScriptDocument] = []
        for write in writes {
            if let expected = write.expectedRemote {
                guard let current = scripts[write.desired.id] else {
                    throw CloudRepositoryError.scriptConflict(write.desired)
                }
                // OCC: expected must match current updatedAt at microsecond precision.
                guard CloudTimestampPrecision.matches(current.updatedAt, expected.updatedAt) else {
                    throw CloudRepositoryError.scriptConflict(write.desired)
                }

                let contentChanged = CloudScriptFingerprint.make(current)
                    != CloudScriptFingerprint.make(write.desired)
                if contentChanged {
                    var stored = write.desired
                    // Immutable createdAt: keep server value (optionally apply
                    // one-shot legacy drift for healing regression tests).
                    stored.createdAt = current.createdAt
                    if let delta = driftCreatedAtOnNextContentUpdateMs {
                        let ms = CloudTimestampPrecision.wireMilliseconds(stored.createdAt) + delta
                        stored.createdAt = Date(timeIntervalSince1970: Double(ms) / 1_000)
                        driftCreatedAtOnNextContentUpdateMs = nil
                    }
                    // Authoritative server edit clock (µs), like PG trigger.
                    stored.updatedAt = Date(timeIntervalSince1970: 1_784_521_303.075_535)
                    if let opened = write.desired.lastOpenedAt {
                        let currentOpen = current.lastOpenedAt
                        if currentOpen == nil
                            || !CloudTimestampPrecision.wireIsAtLeast(
                                currentOpen!,
                                opened
                            ) {
                            stored.lastOpenedAt = CloudScriptOpenUpdate.valueToWrite(
                                desired: opened
                            )
                        } else {
                            stored.lastOpenedAt = current.lastOpenedAt
                        }
                    } else {
                        stored.lastOpenedAt = current.lastOpenedAt
                    }
                    guard write.currentMatchesDesired(stored) else {
                        throw CloudRepositoryError.incompleteRemoteSnapshot
                    }
                    scripts[stored.id] = stored
                    written.append(stored)
                    continue
                }

                // Metadata / open path — shipping: updated_at OCC + monotonic open.
                if requireLastOpenedOCC {
                    // Legacy: exact last_opened_at equality (production-brittle).
                    throw CloudRepositoryError.scriptConflict(write.desired)
                }
                guard let desiredOpen = write.desired.lastOpenedAt,
                      CloudScriptOpenUpdate.needsAdvancement(
                          desired: desiredOpen,
                          current: current.lastOpenedAt
                      ) else {
                    written.append(current)
                    continue
                }
                let openToWrite = CloudScriptOpenUpdate.valueToWrite(desired: desiredOpen)
                // Monotonic apply: only if server open is null or strictly older
                // at wire ms (PostgREST: is.null OR lt canonical write value).
                if let serverOpen = current.lastOpenedAt {
                    let serverMs = CloudTimestampPrecision.wireMilliseconds(serverOpen)
                    let writeMs = CloudTimestampPrecision.wireMilliseconds(openToWrite)
                    if serverMs >= writeMs {
                        written.append(current)
                        continue
                    }
                }
                var stored = current
                stored.lastOpenedAt = openToWrite
                guard write.currentMatchesDesired(stored) else {
                    throw CloudRepositoryError.scriptConflict(write.desired)
                }
                scripts[stored.id] = stored
                written.append(stored)
                continue
            }

            var stored = write.desired
            stored.createdAt = CloudTimestampPrecision.wireNormalized(write.desired.createdAt)
            stored.updatedAt = CloudTimestampPrecision.wireNormalized(write.desired.updatedAt)
            if let opened = write.desired.lastOpenedAt {
                stored.lastOpenedAt = CloudScriptOpenUpdate.valueToWrite(desired: opened)
            }
            guard write.currentMatchesDesired(stored) else {
                throw CloudRepositoryError.incompleteRemoteSnapshot
            }
            scripts[stored.id] = stored
            written.append(stored)
        }
        return written
    }

    func deleteScript(expected: ScriptDocument, accountID: UUID) async throws {
        try verify(accountID)
        scripts.removeValue(forKey: expected.id)
    }

    func fetchFolders(accountID: UUID) async throws -> [ScriptFolder] {
        try verify(accountID)
        return Array(folders.values)
    }

    func fetchFolder(id: UUID, accountID: UUID) async throws -> ScriptFolder? {
        try verify(accountID)
        return folders[id]
    }

    func writeFolders(_ writes: [CloudFolderWrite], accountID: UUID) async throws {
        try verify(accountID)
        for write in writes {
            var stored = write.desired
            stored.createdAt = CloudTimestampPrecision.wireNormalized(write.desired.createdAt)
            guard write.currentMatchesDesired(stored) else {
                throw CloudRepositoryError.incompleteRemoteSnapshot
            }
            folders[stored.id] = stored
        }
    }

    func deleteFolder(expected: ScriptFolder, accountID: UUID) async throws {
        try verify(accountID)
        folders.removeValue(forKey: expected.id)
    }

    func fetchSettings(accountID: UUID) async throws -> ReaderSettings? {
        try verify(accountID)
        return settings
    }

    func saveSettings(_ settings: ReaderSettings, accountID: UUID) async throws {
        try verify(accountID)
        self.settings = settings
    }

    private func verify(_ accountID: UUID) throws {
        guard accountID == self.accountID else {
            throw CloudRepositoryError.accountChanged
        }
    }
}

/// In-memory repository that counts every remote entry point for race tests.
private actor CountingInMemoryCloudLibraryRepository: CloudLibraryRepository {
    let accountID: UUID
    private(set) var fetchCallCount = 0
    private(set) var writeCallCount = 0
    private(set) var deleteCallCount = 0
    private var scripts: [UUID: ScriptDocument] = [:]
    private var folders: [UUID: ScriptFolder] = [:]
    private var settings: ReaderSettings?

    init(accountID: UUID, scripts: [ScriptDocument] = [], settings: ReaderSettings? = nil) {
        self.accountID = accountID
        self.scripts = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        self.settings = settings
    }

    var totalRemoteCalls: Int { fetchCallCount + writeCallCount + deleteCallCount }

    func fetchScripts(accountID: UUID, updatedAfter: Date?) async throws -> [ScriptDocument] {
        fetchCallCount += 1
        try verify(accountID)
        return Array(scripts.values)
    }

    func fetchScript(id: UUID, accountID: UUID) async throws -> ScriptDocument? {
        fetchCallCount += 1
        try verify(accountID)
        return scripts[id]
    }

    func writeScripts(
        _ writes: [CloudScriptWrite],
        accountID: UUID
    ) async throws -> [ScriptDocument] {
        writeCallCount += 1
        try verify(accountID)
        var written: [ScriptDocument] = []
        for write in writes {
            scripts[write.desired.id] = write.desired
            written.append(write.desired)
        }
        return written
    }

    func deleteScript(expected: ScriptDocument, accountID: UUID) async throws {
        deleteCallCount += 1
        try verify(accountID)
        scripts.removeValue(forKey: expected.id)
    }

    func fetchFolders(accountID: UUID) async throws -> [ScriptFolder] {
        fetchCallCount += 1
        try verify(accountID)
        return Array(folders.values)
    }

    func fetchFolder(id: UUID, accountID: UUID) async throws -> ScriptFolder? {
        fetchCallCount += 1
        try verify(accountID)
        return folders[id]
    }

    func writeFolders(_ writes: [CloudFolderWrite], accountID: UUID) async throws {
        writeCallCount += 1
        try verify(accountID)
        for write in writes {
            folders[write.desired.id] = write.desired
        }
    }

    func deleteFolder(expected: ScriptFolder, accountID: UUID) async throws {
        deleteCallCount += 1
        try verify(accountID)
        folders.removeValue(forKey: expected.id)
    }

    func fetchSettings(accountID: UUID) async throws -> ReaderSettings? {
        fetchCallCount += 1
        try verify(accountID)
        return settings
    }

    func saveSettings(_ settings: ReaderSettings, accountID: UUID) async throws {
        writeCallCount += 1
        try verify(accountID)
        self.settings = settings
    }

    private func verify(_ accountID: UUID) throws {
        guard accountID == self.accountID else {
            throw CloudRepositoryError.accountChanged
        }
    }
}
