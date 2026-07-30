import Foundation
import XCTest
@testable import Phrasa

@MainActor
final class CloudAccountSyncRuntimeTests: XCTestCase {
    func testStageEditorDraftDoesNotScheduleCloudPush() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        var edited = try XCTUnwrap(harness.library.scripts.first)
        edited.body = "Keystroke only"
        XCTAssertTrue(harness.library.stageEditorDraft(edited, editorOriginID: UUID()))

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.runtime.synchronizationPassCount, 0)
        XCTAssertEqual(harness.runtime.networkSynchronizeAttempts, 0)
        let fetchCount = await harness.repository.fetchCallCount
        let writeCount = await harness.repository.writeCallCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(writeCount, 0)
    }

    func testDurableSaveSchedulesOneCoalescedPushAfterCommit() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        var edited = try XCTUnwrap(harness.library.scripts.first)
        edited.body = "Durable body A"
        let savedA = await harness.library.update(edited)
        XCTAssertTrue(savedA)
        edited.body = "Durable body B"
        let savedB = await harness.library.update(edited)
        XCTAssertTrue(savedB)

        // Wait for the coalesced pass to finish remote I/O, not merely start.
        // networkSynchronizeAttempts only increments after live preflight passes.
        try await waitUntil {
            harness.runtime.synchronizationPassCount >= 1
                && harness.runtime.networkSynchronizeAttempts >= 1
        }
        XCTAssertEqual(harness.runtime.synchronizationPassCount, 1)
        XCTAssertEqual(harness.runtime.networkSynchronizeAttempts, 1)
        let fetchCount = await harness.repository.fetchCallCount
        XCTAssertGreaterThan(fetchCount, 0)
    }

    func testLocalSaveFailureSchedulesNoPush() async throws {
        let harness = try await makeHarness(signedIn: true, failingSaves: true)
        defer { harness.cleanup() }

        var edited = try XCTUnwrap(harness.library.scripts.first)
        edited.body = "Will fail to persist"
        let saved = await harness.library.update(edited)
        XCTAssertFalse(saved)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(harness.runtime.synchronizationPassCount, 0)
        XCTAssertEqual(harness.runtime.networkSynchronizeAttempts, 0)
        let fetchCount = await harness.repository.fetchCallCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testLaunchAuthRestoredAndForegroundPullTriggersCoalesce() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        harness.runtime.handleLaunch()
        harness.runtime.handleForeground()
        harness.runtime.handleAuthStateChange()

        try await waitUntil { harness.runtime.synchronizationPassCount >= 1 }
        XCTAssertLessThanOrEqual(harness.runtime.synchronizationPassCount, 2)
        XCTAssertGreaterThanOrEqual(harness.runtime.networkSynchronizeAttempts, 1)
        let fetchCount = await harness.repository.fetchCallCount
        XCTAssertGreaterThanOrEqual(fetchCount, 1)
    }

    func testManualSyncNowStateTransitions() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        await harness.runtime.syncNow()
        XCTAssertEqual(harness.runtime.userPresentation, .synced)
        XCTAssertEqual(harness.runtime.synchronizationPassCount, 1)
        XCTAssertNotNil(harness.runtime.lastManualSyncAt)
        XCTAssertTrue(harness.coordinator.syncStatus.isSucceeded)
    }

    func testAbsentConfigRemainsOfflineOnlyWithoutNag() async {
        let coordinator = CloudCoordinator.live(infoDictionary: [:], environment: [:])
        let runtime = CloudAccountSyncRuntime(
            coordinator: coordinator,
            durablePushDebounce: .milliseconds(10)
        )
        XCTAssertEqual(coordinator.availability, .offlineOnly)
        XCTAssertNil(runtime.userPresentation)

        runtime.handleLaunch()
        runtime.handleForeground()
        runtime.noteDurableCloudRelevantMutation()
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(runtime.synchronizationPassCount, 0)
        XCTAssertNil(runtime.userPresentation)
    }

    func testDirtyDraftAtPrepareStartIsIneligible() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        var edited = try XCTUnwrap(harness.library.scripts.first)
        edited.body = "Unsaved staged"
        XCTAssertTrue(harness.library.stageEditorDraft(edited, editorOriginID: UUID()))

        await harness.runtime.syncNow()
        XCTAssertEqual(harness.runtime.networkSynchronizeAttempts, 0)
        let dirtyFetch = await harness.repository.fetchCallCount
        let dirtyWrite = await harness.repository.writeCallCount
        XCTAssertEqual(dirtyFetch, 0)
        XCTAssertEqual(dirtyWrite, 0)
        guard case .deferred = harness.coordinator.syncStatus else {
            return XCTFail("Expected deferred sync status, got \(harness.coordinator.syncStatus)")
        }
        XCTAssertEqual(harness.runtime.userPresentation, .needsAttention)
    }

    func testDraftStagedAfterPrepareBeforeNetworkFailsClosedWithZeroRemoteCalls() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        let accountID = try XCTUnwrap(harness.coordinator.signedInUser?.id)
        let outcome = try await harness.library.prepareCloudSync(for: accountID)
        guard case .ready = outcome else {
            return XCTFail("Expected ready prepare before interleaving stage")
        }
        let lease = try XCTUnwrap(harness.library.cloudSyncEligibilityLease)
        XCTAssertTrue(harness.library.isCloudSyncEligibilityLeaseValid(lease))

        var edited = try XCTUnwrap(harness.library.scripts.first)
        edited.body = "Interleaved draft"
        XCTAssertTrue(harness.library.stageEditorDraft(edited, editorOriginID: UUID()))
        XCTAssertFalse(harness.library.isCloudSyncEligibilityLeaseValid(lease))

        await harness.repository.resetCounts()
        await harness.runtime.syncNow()
        XCTAssertEqual(harness.runtime.networkSynchronizeAttempts, 0)
        let raceFetch = await harness.repository.fetchCallCount
        let raceWrite = await harness.repository.writeCallCount
        let raceDelete = await harness.repository.deleteCallCount
        XCTAssertEqual(raceFetch, 0)
        XCTAssertEqual(raceWrite, 0)
        XCTAssertEqual(raceDelete, 0)
    }

    func testLivePreflightBarrierStagesDraftWithZeroRemoteCalls() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        // Deterministic race: after prepare succeeds, the engine's final
        // preflight barrier stages a draft on MainActor before remote access.
        harness.runtime.testPreflightBarrier = { [library = harness.library] in
            var edited = library.scripts[0]
            edited.body = "Barrier-staged draft"
            XCTAssertTrue(library.stageEditorDraft(edited, editorOriginID: UUID()))
        }

        await harness.repository.resetCounts()
        harness.runtime.resetTestCounters()
        await harness.runtime.syncNow()

        XCTAssertEqual(harness.runtime.networkSynchronizeAttempts, 0)
        let fetchCount = await harness.repository.fetchCallCount
        let writeCount = await harness.repository.writeCallCount
        let deleteCount = await harness.repository.deleteCallCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(deleteCount, 0)
        guard case .deferred = harness.coordinator.syncStatus else {
            return XCTFail("Expected deferred after barrier-staged draft")
        }
        XCTAssertEqual(harness.runtime.userPresentation, .needsAttention)
    }

    func testQuarantinedContentNeverSilentlyClaimedOnSyncPrepare() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("library.json")
        let quarantined = ScriptDocument(title: "Legacy restored", body: "device only")
        let snapshot = LibrarySnapshot(
            scripts: [quarantined],
            folders: [],
            settings: .init(),
            seeded: true
        )
        // Snapshot-only JSON upgrades by quarantining unowned content.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL)

        let library = LibraryStore(persistence: PersistenceClient(fileURL: fileURL))
        await library.load()
        XCTAssertEqual(library.scripts.count, 1)

        let accountID = UUID()
        let outcome = try await library.prepareCloudSync(for: accountID)
        guard case .ready(let input) = outcome else {
            return XCTFail("Expected ready prepare with quarantined local-only content")
        }
        XCTAssertTrue(
            input.state.scriptIDsOwnedByOtherAccounts.contains(quarantined.id),
            "Quarantined script must not be claimed by the first signed-in account"
        )
        XCTAssertNil(input.state.currentAccountRecords[quarantined.id])
        XCTAssertEqual(input.excludedLocalScriptCount, 1)
        XCTAssertNil(
            CloudSyncDisclosure.deviceOnlyWarning(
                for: CloudSyncSummary(
                    uploadedScripts: 0,
                    downloadedScripts: 0,
                    completedAt: .now
                )
            )
        )
        XCTAssertTrue(
            CloudSyncDisclosure.deviceOnlyWarning(
                for: CloudSyncSummary(
                    uploadedScripts: 0,
                    downloadedScripts: 0,
                    completedAt: .now,
                    excludedLocalScriptCount: 1,
                    excludedLocalFolderCount: 0
                )
            )?.contains("deferred") == true
        )
    }

    func testCallbackURLRoutingAndStaleAccountResultsRemainFailClosed() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        await harness.coordinator.handleOpenURL(
            URL(string: "phrasa://auth/unexpected?code=nope")!
        )
        XCTAssertEqual(
            harness.coordinator.accountMessage,
            "Cloud accounts are not available in this build. Phrasa still works offline."
        )

        let accountA = try XCTUnwrap(harness.coordinator.signedInUser?.id)
        let prepared = try await harness.library.prepareCloudSync(for: accountA)
        guard case .ready(let input) = prepared else {
            return XCTFail("Expected ready input")
        }
        let token = try XCTUnwrap(harness.coordinator.beginSynchronization())
        harness.coordinator.seedAuthStateForTesting(
            .signedIn(CloudUser(id: UUID(), email: "other@example.com"))
        )
        let result = await harness.coordinator.synchronize(
            token,
            local: input,
            preflight: CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        )
        XCTAssertNil(result)
        XCTAssertFalse(harness.coordinator.syncStatus.isSucceeded)
    }

    func testMarkOpenedDoesNotScheduleCloudPush() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        let id = try XCTUnwrap(harness.library.scripts.first?.id)
        let opened = await harness.library.markOpened(id)
        XCTAssertTrue(opened)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(harness.runtime.synchronizationPassCount, 0)
        let fetchCount = await harness.repository.fetchCallCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testReaderSettingsSaveDoesNotScheduleCloudPush() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        var settings = harness.library.settings
        settings.fontSize = 64
        let saved = await harness.library.saveSettings(settings)
        XCTAssertTrue(saved)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(harness.runtime.synchronizationPassCount, 0)
        let fetchCount = await harness.repository.fetchCallCount
        XCTAssertEqual(fetchCount, 0)
    }

    // MARK: - Harness

    private struct Harness {
        let library: LibraryStore
        let repository: CountingCloudLibraryRepository
        let coordinator: CloudCoordinator
        let runtime: CloudAccountSyncRuntime
        let cleanup: () -> Void
    }

    private func makeHarness(
        signedIn: Bool = false,
        failingSaves: Bool = false
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("library.json")
        let script = ScriptDocument(
            title: "Seed",
            body: "Hello",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let snapshot = LibrarySnapshot(
            scripts: [script],
            folders: [],
            settings: .init(),
            seeded: true
        )

        let persistence: any LibraryPersistence
        if failingSaves {
            persistence = FailingUpsertPersistence(snapshot: snapshot)
        } else {
            let client = PersistenceClient(fileURL: fileURL)
            try await client.replace(with: snapshot)
            persistence = client
        }

        let library = LibraryStore(persistence: persistence)
        await library.load()

        let user = CloudUser(id: UUID(), email: "reader@example.com")
        let repository = CountingCloudLibraryRepository(accountID: user.id)
        let coordinator: CloudCoordinator
        if signedIn {
            coordinator = CloudCoordinator.testing(
                authState: .signedIn(user),
                repository: repository
            )
        } else {
            coordinator = CloudCoordinator.testing(
                authState: .signedOut,
                repository: repository
            )
        }

        let runtime = CloudAccountSyncRuntime(
            coordinator: coordinator,
            durablePushDebounce: .milliseconds(20)
        )
        runtime.attach(library: library)
        // Do not call start() here: testing coordinators have nil auth and
        // start() is a no-op for observation. Avoid automatic launch pulls so
        // individual tests control triggers.
        if signedIn {
            // Present as ready/synced for signed-in local mode with no prior sync.
            runtime.resetTestCounters()
            await repository.resetCounts()
        }

        return Harness(
            library: library,
            repository: repository,
            coordinator: coordinator,
            runtime: runtime,
            cleanup: { try? FileManager.default.removeItem(at: directory) }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not met before timeout")
    }
}

// MARK: - Helpers

private extension CloudSyncStatus {
    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

private actor CountingCloudLibraryRepository: CloudLibraryRepository {
    let accountID: UUID
    private(set) var fetchCallCount = 0
    private(set) var writeCallCount = 0
    private(set) var deleteCallCount = 0
    private var scripts: [ScriptDocument] = []
    private var folders: [ScriptFolder] = []
    private var settings: ReaderSettings?

    init(accountID: UUID) {
        self.accountID = accountID
    }

    func resetCounts() {
        fetchCallCount = 0
        writeCallCount = 0
        deleteCallCount = 0
    }

    func fetchScripts(accountID: UUID, updatedAfter: Date?) async throws -> [ScriptDocument] {
        fetchCallCount += 1
        try check(accountID)
        return scripts
    }

    func fetchScript(id: UUID, accountID: UUID) async throws -> ScriptDocument? {
        fetchCallCount += 1
        try check(accountID)
        return scripts.first { $0.id == id }
    }

    func fetchFolders(accountID: UUID) async throws -> [ScriptFolder] {
        fetchCallCount += 1
        try check(accountID)
        return folders
    }

    func fetchFolder(id: UUID, accountID: UUID) async throws -> ScriptFolder? {
        fetchCallCount += 1
        try check(accountID)
        return folders.first { $0.id == id }
    }

    func fetchSettings(accountID: UUID) async throws -> ReaderSettings? {
        fetchCallCount += 1
        try check(accountID)
        return settings
    }

    func writeFolders(_ writes: [CloudFolderWrite], accountID: UUID) async throws {
        writeCallCount += 1
        try check(accountID)
        for write in writes {
            if let index = folders.firstIndex(where: { $0.id == write.desired.id }) {
                folders[index] = write.desired
            } else {
                folders.append(write.desired)
            }
        }
    }

    func writeScripts(
        _ writes: [CloudScriptWrite],
        accountID: UUID
    ) async throws -> [ScriptDocument] {
        writeCallCount += 1
        try check(accountID)
        var written: [ScriptDocument] = []
        for write in writes {
            if let index = scripts.firstIndex(where: { $0.id == write.desired.id }) {
                scripts[index] = write.desired
            } else {
                scripts.append(write.desired)
            }
            written.append(write.desired)
        }
        return written
    }

    func deleteScript(expected: ScriptDocument, accountID: UUID) async throws {
        deleteCallCount += 1
        try check(accountID)
        scripts.removeAll { $0.id == expected.id }
    }

    func deleteFolder(expected: ScriptFolder, accountID: UUID) async throws {
        deleteCallCount += 1
        try check(accountID)
        folders.removeAll { $0.id == expected.id }
    }

    func saveSettings(_ settings: ReaderSettings, accountID: UUID) async throws {
        writeCallCount += 1
        try check(accountID)
        self.settings = settings
    }

    private func check(_ accountID: UUID) throws {
        guard accountID == self.accountID else {
            throw CloudRepositoryError.accountChanged
        }
    }
}

private final class FailingUpsertPersistence: LibraryPersistence, @unchecked Sendable {
    private var snapshot: LibrarySnapshot

    init(snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> LibrarySnapshot { snapshot }

    func replace(with snapshot: LibrarySnapshot) async throws {
        self.snapshot = snapshot
    }

    func upsert(_ script: ScriptDocument) async throws {
        throw NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Simulated durable save failure"
        ])
    }

    func deleteScript(id: UUID) async throws {}
    func saveFolders(_ folders: [ScriptFolder]) async throws {}
    func deleteFolder(id: UUID, updatedScripts: [ScriptDocument]) async throws {}
    func saveSettings(_ settings: ReaderSettings, seeded: Bool) async throws {}

    func prepareCloudSync(
        accountID: UUID,
        localScriptIDs: Set<UUID>,
        localFolderIDs: Set<UUID>
    ) async throws -> CloudLocalSyncState {
        .empty(accountID: accountID)
    }

    func applyCloudSync(
        snapshot: LibrarySnapshot,
        update: CloudSyncPersistenceUpdate
    ) async throws {
        self.snapshot = snapshot
    }
}
