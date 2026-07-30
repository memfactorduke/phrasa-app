import Foundation
import XCTest
import PhrasaDomain
import PhrasaPersistence
import PhrasaSync
@testable import PhrasaMac

/// Deterministic Mac account/sync runtime tests (no live Supabase network).
@MainActor
final class MacCloudAccountSyncRuntimeTests: XCTestCase {
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
        XCTAssertEqual(fetchCount, 0)
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

    func testAbsentConfigRemainsOfflineOnlyWithoutNag() {
        let coordinator = CloudCoordinator.live(infoDictionary: [:], environment: [:])
        let runtime = MacCloudAccountSyncRuntime(
            coordinator: coordinator,
            durablePushDebounce: .milliseconds(10)
        )
        XCTAssertEqual(coordinator.availability, .offlineOnly)
        XCTAssertNil(runtime.userPresentation)

        runtime.handleLaunch()
        runtime.handleForeground()
        XCTAssertNil(runtime.userPresentation)
    }

    func testPinnedProductionURLWithoutKeyIsIncompleteOrOffline() {
        // One-sided config must not build a half-ready client.
        do {
            _ = try CloudConfiguration.load(
                infoDictionary: [
                    CloudConfiguration.urlInfoKey: CloudConfiguration.productionProjectURLString
                ],
                environment: [:],
                sourcePolicy: .release
            )
            XCTFail("Expected incomplete configuration when key is missing")
        } catch {
            XCTAssertEqual(error as? CloudConfigurationError, .incompleteConfiguration)
        }

        let coordinator = CloudCoordinator.live(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: CloudConfiguration.productionProjectURLString,
                CloudConfiguration.publishableKeyInfoKey: ""
            ],
            environment: [:]
        )
        // Empty key normalizes to absent → offlineOnly when both effectively empty.
        // If only URL present and key blank after normalize, load returns incomplete throw
        // → unavailable. Either is acceptable fail-closed offline behavior.
        switch coordinator.availability {
        case .offlineOnly, .unavailable:
            break
        case .ready:
            XCTFail("Empty publishable key must not enable cloud")
        }
    }

    func testPrepareIssuesLeaseAndStageInvalidates() async throws {
        let harness = try await makeHarness(signedIn: true)
        defer { harness.cleanup() }

        let accountID = try XCTUnwrap(harness.coordinator.signedInUser?.id)
        let prepared = try await harness.library.prepareCloudSync(for: accountID)
        guard case .ready = prepared else {
            return XCTFail("Expected ready prepare")
        }
        let lease = try XCTUnwrap(harness.library.cloudSyncEligibilityLease)
        XCTAssertTrue(harness.library.isCloudSyncEligibilityLeaseValid(lease))

        var edited = try XCTUnwrap(harness.library.scripts.first)
        edited.body = "Stage after prepare"
        XCTAssertTrue(harness.library.stageEditorDraft(edited, editorOriginID: UUID()))
        XCTAssertFalse(harness.library.isCloudSyncEligibilityLeaseValid(lease))
        XCTAssertNil(harness.library.cloudSyncEligibilityLease)
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

    func testEmailAccountDeletionStaysAutomaticAndAppleRequiresReauthorization() {
        let emailUser = CloudUser(id: UUID(), email: "a@example.com", identityProviders: ["email"])
        XCTAssertEqual(AccountDeletionPolicy.route(for: emailUser), .automatic)
        XCTAssertFalse(AccountDeletionPolicy.requiresAppleReauthorization(for: emailUser))

        let appleUser = CloudUser(id: UUID(), email: "a@example.com", identityProviders: ["apple"])
        XCTAssertEqual(
            AccountDeletionPolicy.route(for: appleUser),
            .appleLinkedRequiresReauthorization
        )
        XCTAssertTrue(AccountDeletionPolicy.hasAppleIdentity(appleUser))
        XCTAssertTrue(AccountDeletionPolicy.requiresAppleReauthorization(for: appleUser))
        XCTAssertTrue(
            AccountDeletionPolicy.deletionFooter(for: appleUser)
                .contains("confirm with Apple")
        )
        XCTAssertFalse(
            AccountDeletionPolicy.deletionFooter(for: appleUser)
                .contains("does not revoke")
        )
    }

    // MARK: - Harness

    private final class Harness {
        var library: MacLibraryStore!
        let repository: MacCountingCloudLibraryRepository
        let coordinator: CloudCoordinator
        let runtime: MacCloudAccountSyncRuntime
        private let directory: URL

        init(
            library: MacLibraryStore,
            repository: MacCountingCloudLibraryRepository,
            coordinator: CloudCoordinator,
            runtime: MacCloudAccountSyncRuntime,
            directory: URL
        ) {
            self.library = library
            self.repository = repository
            self.coordinator = coordinator
            self.runtime = runtime
            self.directory = directory
        }

        func cleanup() {
            // Release the store/persistence client before unlinking SQLite,
            // WAL, and SHM. Removing a live database produces macOS
            // "vnode unlinked while in use" integrity warnings.
            library = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness(
        signedIn: Bool = false,
        failingSaves: Bool = false
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhrasaMacCloudRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("library.sqlite3")
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
            persistence = MacFailingUpsertPersistence(snapshot: snapshot)
        } else {
            let client = LibraryPersistenceFactory.makeShipping(fileURL: dbURL)
            try await client.replace(with: snapshot)
            persistence = client
        }

        let library = MacLibraryStore(persistence: persistence)
        await library.load()

        let user = CloudUser(id: UUID(), email: "reader@example.com")
        let repository = MacCountingCloudLibraryRepository(accountID: user.id)
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

        let runtime = MacCloudAccountSyncRuntime(
            coordinator: coordinator,
            durablePushDebounce: .milliseconds(20)
        )
        runtime.attach(library: library)
        if signedIn {
            runtime.resetTestCounters()
            await repository.resetCounts()
        }

        return Harness(
            library: library,
            repository: repository,
            coordinator: coordinator,
            runtime: runtime,
            directory: directory
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

actor MacCountingCloudLibraryRepository: CloudLibraryRepository {
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

private final class MacFailingUpsertPersistence: LibraryPersistence, @unchecked Sendable {
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
