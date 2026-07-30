import AuthenticationServices
import Foundation
import XCTest
@testable import Phrasa

final class CloudFoundationTests: XCTestCase {
    func testPendingAuthCallbackQueueKeepsLatestIntentAndExchangesEachLinkOnce() throws {
        let first = try XCTUnwrap(URL(string: "phrasa://auth/callback?code=first"))
        let second = try XCTUnwrap(URL(string: "phrasa://auth/callback?code=second"))
        let third = try XCTUnwrap(URL(string: "phrasa://auth/recovery?code=third"))
        var queue = PendingAuthCallbackQueue()

        XCTAssertTrue(queue.enqueue(first))
        XCTAssertFalse(queue.enqueue(first), "Repeated delivery must remain one pending exchange")
        XCTAssertTrue(queue.enqueue(second), "The newest distinct callback replaces stale intent")
        XCTAssertEqual(queue.beginNext(), second)
        XCTAssertFalse(queue.enqueue(second), "An active one-time code must not be queued again")

        XCTAssertTrue(queue.enqueue(third))
        queue.finish(second)
        XCTAssertEqual(queue.beginNext(), third)
        queue.finish(third)

        XCTAssertFalse(queue.hasWork)
        XCTAssertFalse(queue.enqueue(second), "An attempted one-time code must not be exchanged twice")
        XCTAssertFalse(queue.enqueue(third), "An attempted recovery code must not be exchanged twice")
    }

    func testPKCECallbackRoutesDistinguishRecoveryFromOrdinarySignIn() throws {
        let signInURL = URL(string: "phrasa://auth/callback")!
        let recoveryURL = URL(string: "phrasa://auth/recovery")!

        XCTAssertEqual(
            try CloudAuthCallbackKind.classify(
                URL(string: "phrasa://auth/callback?code=signup-code")!,
                signInRedirectURL: signInURL,
                passwordRecoveryRedirectURL: recoveryURL
            ),
            .signIn
        )
        XCTAssertEqual(
            try CloudAuthCallbackKind.classify(
                URL(string: "phrasa://auth/recovery?code=reset-code")!,
                signInRedirectURL: signInURL,
                passwordRecoveryRedirectURL: recoveryURL
            ),
            .passwordRecovery
        )
        XCTAssertThrowsError(
            try CloudAuthCallbackKind.classify(
                URL(string: "phrasa://auth/unexpected?code=code")!,
                signInRedirectURL: signInURL,
                passwordRecoveryRedirectURL: recoveryURL
            )
        )
    }

    func testPasswordRecoveryStateSurvivesStoreRecreationUntilCleared() async throws {
        let suiteName = "PhrasaTests.PasswordRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let userID = UUID()

        let firstStore = PasswordRecoveryStateStore(suiteName: suiteName)
        await firstStore.mark(userID: userID)

        let recreatedStore = PasswordRecoveryStateStore(suiteName: suiteName)
        let matchesOriginalUser = await recreatedStore.matches(userID: userID)
        let matchesDifferentUser = await recreatedStore.matches(userID: UUID())
        XCTAssertTrue(matchesOriginalUser)
        XCTAssertFalse(matchesDifferentUser)

        await recreatedStore.clear()
        let remainsAfterClear = await firstStore.matches(userID: userID)
        XCTAssertFalse(remainsAfterClear)
    }

    func testRecoveredPasswordRequiresEightMatchingCharacters() {
        XCTAssertEqual(
            RecoveredPasswordValidator.message(password: "short", confirmation: "short"),
            "Use at least 8 characters."
        )
        XCTAssertEqual(
            RecoveredPasswordValidator.message(password: "long-enough", confirmation: "different"),
            "The two passwords don't match."
        )
        XCTAssertNil(
            RecoveredPasswordValidator.message(
                password: "long-enough",
                confirmation: "long-enough"
            )
        )
    }

    func testAccountDeletionConfirmationCannotMoveBetweenUsers() throws {
        let expectedUserID = UUID()
        XCTAssertNoThrow(
            try AccountDeletionIdentityValidator.validate(
                expectedUserID: expectedUserID,
                currentUserID: expectedUserID
            )
        )
        XCTAssertThrowsError(
            try AccountDeletionIdentityValidator.validate(
                expectedUserID: expectedUserID,
                currentUserID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? AccountDeletionError, .accountChanged)
        }
    }

    func testEmailAccountDeletionRemainsAutomatic() {
        let user = CloudUser(
            id: UUID(),
            email: "reader@example.com",
            identityProviders: ["email"]
        )

        XCTAssertEqual(AccountDeletionPolicy.route(for: user), .automatic)
        XCTAssertFalse(AccountDeletionPolicy.requiresAppleReauthorization(for: user))
        XCTAssertTrue(
            AccountDeletionPolicy.deletionFooter(for: user)
                .contains("leaves all content and settings already saved on this device unchanged")
        )
        XCTAssertFalse(
            AccountDeletionPolicy.deletionFooter(for: user)
                .contains("Confirm with Apple")
        )
    }

    func testAppleLinkedAccountsRequireReauthorizationBeforeDeletion() {
        let user = CloudUser(
            id: UUID(),
            email: "private-relay@privaterelay.appleid.com",
            identityProviders: ["email", "apple"]
        )

        // Primary Sign in with Apple path must reauthorize to obtain a one-time
        // authorization code for server-side token revocation, then fail closed
        // until the edge function completes revoke + delete.
        XCTAssertEqual(
            AccountDeletionPolicy.route(for: user),
            .appleLinkedRequiresReauthorization
        )
        XCTAssertTrue(AccountDeletionPolicy.hasAppleIdentity(user))
        XCTAssertTrue(AccountDeletionPolicy.requiresAppleReauthorization(for: user))
        XCTAssertEqual(
            AccountDeletionPolicy.appleLinkedDeletionFunctionName,
            "delete-apple-linked-account"
        )
        XCTAssertTrue(
            AccountDeletionPolicy.deletionFooter(for: user)
                .contains("Sign in with Apple")
        )
        XCTAssertTrue(
            AccountDeletionPolicy.deletionFooter(for: user)
                .contains("confirm with Apple")
        )
        XCTAssertTrue(
            AccountDeletionPolicy.appleRevocationServerReleaseBlocker
                .contains("RELEASE BLOCKER")
        )
        XCTAssertFalse(
            AccountDeletionPolicy.deletionFooter(for: user)
                .contains("does not revoke")
        )
    }

    func testAppleDeletionReauthorizationPayloadValidation() {
        XCTAssertThrowsError(
            try AppleSignInSupport.validateDeletionReauthorization(
                .init(authorizationCode: "  ", clientId: AppleSignInSupport.SignInClientID.iOS)
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleSignInSupport.CredentialError,
                .missingAuthorizationCode
            )
        }
        XCTAssertThrowsError(
            try AppleSignInSupport.validateDeletionReauthorization(
                .init(authorizationCode: "code", clientId: "  ")
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleSignInSupport.CredentialError,
                .missingClientId
            )
        }
        XCTAssertNoThrow(
            try AppleSignInSupport.validateDeletionReauthorization(
                .init(
                    authorizationCode: "code",
                    clientId: AppleSignInSupport.SignInClientID.iOS
                )
            )
        )
        XCTAssertNoThrow(
            try AppleSignInSupport.validateDeletionReauthorization(
                .init(
                    authorizationCode: "code",
                    clientId: AppleSignInSupport.SignInClientID.mac
                )
            )
        )
        XCTAssertEqual(AppleSignInSupport.SignInClientID.iOS, "com.phrasa.app")
        XCTAssertEqual(AppleSignInSupport.SignInClientID.mac, "com.phrasa.mac")
        XCTAssertEqual(
            try AppleSignInSupport.currentSignInClientId(bundleIdentifier: "com.phrasa.app"),
            "com.phrasa.app"
        )
        XCTAssertThrowsError(
            try AppleSignInSupport.currentSignInClientId(bundleIdentifier: "  ")
        ) { error in
            XCTAssertEqual(
                error as? AppleSignInSupport.CredentialError,
                .missingClientId
            )
        }
    }

    func testAppleLinkedDeletionErrorMapperFailClosedCodes() {
        XCTAssertEqual(
            AppleLinkedDeletionErrorMapper.map(
                AccountLifecycleBackendError(
                    code: AppleLinkedDeletionServerCode.notConfigured.rawValue,
                    message: "not configured"
                )
            ),
            .appleRevocationNotConfigured
        )
        XCTAssertEqual(
            AppleLinkedDeletionErrorMapper.map(
                AccountLifecycleBackendError(
                    code: AppleLinkedDeletionServerCode.appleRevokeFailed.rawValue,
                    message: "revoke failed"
                )
            ),
            .appleRevocationFailed
        )
        XCTAssertEqual(
            AppleLinkedDeletionErrorMapper.map(
                AccountLifecycleBackendError(
                    code: AppleLinkedDeletionServerCode.partialRevokedDeleteFailed.rawValue,
                    message: "partial"
                )
            ),
            .appleRevokedButAccountDeletionFailed
        )
        XCTAssertEqual(
            AppleLinkedDeletionErrorMapper.mapHTTP(
                statusCode: 503,
                body: Data(#"{"code":"APPLE_REVOCATION_NOT_CONFIGURED","message":"missing"}"#.utf8)
            ),
            .appleRevocationNotConfigured
        )
        XCTAssertEqual(
            AppleLinkedDeletionErrorMapper.mapHTTP(statusCode: 404, body: Data()),
            .appleRevocationNotConfigured
        )
    }

    func testAppleLinkedDeletionWorkflowRejectsEmptyAuthorizationCode() async {
        let remote = FakeAppleLinkedAccountDeletionRemote()
        do {
            _ = try await AppleLinkedAccountDeletionWorkflow(remote: remote).deleteAccount(
                userID: UUID(),
                reauthorization: .init(
                    authorizationCode: "",
                    clientId: AppleSignInSupport.SignInClientID.iOS
                )
            )
            XCTFail("Expected empty authorization code to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppleSignInSupport.CredentialError,
                .missingAuthorizationCode
            )
        }
        let calls = await remote.invokeCount
        XCTAssertEqual(calls, 0)
    }

    func testAppleLinkedDeletionWorkflowRejectsEmptyClientId() async {
        let remote = FakeAppleLinkedAccountDeletionRemote()
        do {
            _ = try await AppleLinkedAccountDeletionWorkflow(remote: remote).deleteAccount(
                userID: UUID(),
                reauthorization: .init(authorizationCode: "fresh-code", clientId: "")
            )
            XCTFail("Expected empty client id to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppleSignInSupport.CredentialError,
                .missingClientId
            )
        }
        let calls = await remote.invokeCount
        XCTAssertEqual(calls, 0)
    }

    func testAppleLinkedDeletionWorkflowPropagatesNotConfiguredWithoutClearingSessionOnTransportMap(
    ) async {
        let userID = UUID()
        let remote = FakeAppleLinkedAccountDeletionRemote(
            error: AccountLifecycleBackendError(
                code: AppleLinkedDeletionServerCode.notConfigured.rawValue,
                message: "secrets missing"
            )
        )
        do {
            _ = try await AppleLinkedAccountDeletionWorkflow(remote: remote).deleteAccount(
                userID: userID,
                reauthorization: .init(
                    authorizationCode: "fresh-code",
                    clientId: AppleSignInSupport.SignInClientID.mac
                )
            )
            XCTFail("Expected not-configured to fail closed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .appleRevocationNotConfigured)
        }
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [.invoke])
        // Fail-closed before success: session clear only runs after 2xx.
        XCTAssertFalse(events.contains(.clearLocalSession))
    }

    func testAppleLinkedDeletionWorkflowClearsSessionAfterServerSuccess() async throws {
        let userID = UUID()
        let remote = FakeAppleLinkedAccountDeletionRemote()
        let result = try await AppleLinkedAccountDeletionWorkflow(remote: remote).deleteAccount(
            userID: userID,
            reauthorization: .init(
                authorizationCode: "fresh-code",
                clientId: AppleSignInSupport.SignInClientID.iOS
            )
        )
        XCTAssertEqual(result, AccountDeletionResult(sessionCleared: true))
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [.invoke, .clearLocalSession])
        let expected = await remote.recordedExpectedUserIDs()
        XCTAssertEqual(expected, [userID])
        let clientIds = await remote.recordedClientIDs()
        XCTAssertEqual(clientIds, [AppleSignInSupport.SignInClientID.iOS])
    }

    func testScriptFingerprintIgnoresCreatedAtDriftAndKeysOnEditableContent() {
        // v2 digest deliberately excludes createdAt (immutable metadata / wire
        // drift). Production QA: local 1784519223.273941 vs server …273000 must
        // not fingerprint-conflict when editable content matches.
        let localCreated = Date(timeIntervalSince1970: 1_784_519_223.273_941)
        let serverCreated = Date(timeIntervalSince1970: 1_784_519_223.273_000)
        let id = UUID()
        let local = ScriptDocument(
            id: id,
            title: "Talk",
            body: "Body",
            createdAt: localCreated,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        var server = local
        server.createdAt = serverCreated
        server.updatedAt = Date(timeIntervalSince1970: 60)

        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(server)
        )
        XCTAssertTrue(
            CloudScriptWrite(desired: local, expectedRemote: nil)
                .currentMatchesDesired(server)
        )

        // Even a whole-second createdAt shift is still the same content row.
        var shiftedCreate = local
        shiftedCreate.createdAt = Date(timeIntervalSince1970: 1_784_519_224.0)
        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(shiftedCreate)
        )

        // Editable content still keys the digest.
        var differentBody = local
        differentBody.body = "Other body"
        XCTAssertNotEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(differentBody)
        )
    }

    func testAccountDeletionPreflightsThenInvokesDeleteWithoutStorage() async throws {
        let userID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let remote = FakeAccountDeletionRemote()
        let workflow = AccountDeletionWorkflow(remote: remote)

        let result = try await workflow.deleteAccount(userID: userID)

        XCTAssertEqual(result, AccountDeletionResult(sessionCleared: true))
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [
            .rpc("CHECK"),
            .rpc("DELETE"),
            .clearLocalSession,
        ])
        let expectedUserIDs = await remote.recordedExpectedUserIDs()
        XCTAssertEqual(expectedUserIDs, [userID, userID])
        let cleanupUserIDs = await remote.recordedCleanupExpectedUserIDs()
        XCTAssertEqual(cleanupUserIDs, [userID])
    }

    func testAccountDeletionMissingMigrationStopsBeforeDelete() async {
        let remote = FakeAccountDeletionRemote(
            preflightError: AccountLifecycleBackendError(
                code: "PGRST202",
                message: "Could not find public.delete_own_account"
            )
        )

        do {
            _ = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: UUID())
            XCTFail("Expected deletion to fail closed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .migrationUnavailable)
        }
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [.rpc("CHECK")])
    }

    func testAccountDeletionRejectsUnexpectedlySuccessfulPreflight() async {
        let remote = FakeAccountDeletionRemote(preflightError: nil)

        do {
            _ = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: UUID())
            XCTFail("Expected an unexpectedly successful CHECK call to fail closed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .preflightFailed)
        }
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [.rpc("CHECK")])
    }

    func testAccountDeletionRequiresExactPreflightGuard() async {
        let remote = FakeAccountDeletionRemote(
            preflightError: AccountLifecycleBackendError(
                code: "22023",
                message: "A different input was invalid."
            )
        )

        do {
            _ = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: UUID())
            XCTFail("Expected an unrelated 22023 error to fail closed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .preflightFailed)
        }
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [.rpc("CHECK")])
    }

    func testAccountDeletionRejectsPreflightMessageWithoutExpectedSQLState() async {
        let remote = FakeAccountDeletionRemote(
            preflightError: AccountLifecycleBackendError(
                code: nil,
                message: "Account deletion was not confirmed."
            )
        )

        do {
            _ = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: UUID())
            XCTFail("Expected a message without SQLSTATE 22023 to fail closed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .preflightFailed)
        }
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [.rpc("CHECK")])
    }

    func testAccountDeletionReportsFinalDeletionFailureWithoutStorageSideEffects() async {
        let userID = UUID()
        let remote = FakeAccountDeletionRemote(
            finalError: AccountLifecycleBackendError(code: "08006", message: "connection lost")
        )

        do {
            _ = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: userID)
            XCTFail("Expected final deletion to fail")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .finalDeletionFailed)
        }
        let events = await remote.recordedEvents()
        XCTAssertEqual(events, [.rpc("CHECK"), .rpc("DELETE")])
        XCTAssertFalse(events.contains(.clearLocalSession))
    }

    func testUnconfirmedFinalDeletionClearsLocalSessionForSafety() async {
        let userID = UUID()
        let remote = FakeAccountDeletionRemote(finalTransportShouldFail: true)

        do {
            _ = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: userID)
            XCTFail("Expected the lost final response to be reported as unconfirmed")
        } catch {
            XCTAssertEqual(
                error as? AccountDeletionError,
                .finalDeletionUnconfirmed(sessionCleared: true)
            )
        }
        let events = await remote.recordedEvents()
        XCTAssertTrue(events.contains(.rpc("DELETE")))
        XCTAssertEqual(events.last, .clearLocalSession)
    }

    func testAlreadyDeletedAccountIsSuccessfulAndClearsLocalSession() async throws {
        let remote = FakeAccountDeletionRemote(
            finalError: AccountLifecycleBackendError(
                code: "P0002",
                message: "The authenticated account no longer exists."
            )
        )

        let result = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: UUID())

        XCTAssertEqual(result, AccountDeletionResult(sessionCleared: true))
        let events = await remote.recordedEvents()
        XCTAssertEqual(Array(events.suffix(2)), [.rpc("DELETE"), .clearLocalSession])
    }

    func testSuccessfulAccountDeletionReportsUnconfirmedLocalCleanup() async throws {
        let remote = FakeAccountDeletionRemote(sessionCleared: false)
        let result = try await AccountDeletionWorkflow(remote: remote).deleteAccount(userID: UUID())
        XCTAssertEqual(result, AccountDeletionResult(sessionCleared: false))
    }

    func testSuccessfulDeletionPreservesAReplacementSession() async throws {
        let deletedUserID = UUID()
        let remote = FakeAccountDeletionRemote(differentAccountPreserved: true)

        let result = try await AccountDeletionWorkflow(remote: remote)
            .deleteAccount(userID: deletedUserID)

        XCTAssertEqual(
            result,
            AccountDeletionResult(
                sessionCleared: false,
                differentAccountPreserved: true
            )
        )
        XCTAssertFalse(
            AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: result,
                expectedUserID: deletedUserID,
                currentUserID: UUID()
            )
        )
        let cleanupUserIDs = await remote.recordedCleanupExpectedUserIDs()
        XCTAssertEqual(cleanupUserIDs, [deletedUserID])
    }

    func testLocalSessionGuardNeverClearsAReplacementAccount() {
        let deletedUserID = UUID()
        let replacementUserID = UUID()

        XCTAssertEqual(
            AccountDeletionSessionGuard.action(
                expectedUserID: deletedUserID,
                currentUserID: replacementUserID
            ),
            .preserveDifferentAccount
        )
        XCTAssertEqual(
            AccountDeletionSessionGuard.action(
                expectedUserID: deletedUserID,
                currentUserID: deletedUserID
            ),
            .clearExpectedAccount
        )
        XCTAssertEqual(
            AccountDeletionSessionGuard.action(
                expectedUserID: deletedUserID,
                currentUserID: nil
            ),
            .alreadyCleared
        )
    }

    func testAuthMutationLockKeepsAReplacementSignInBehindDeletionCleanup() async {
        let deletedUserID = UUID()
        let replacementUserID = UUID()
        let lock = AuthMutationLock()
        let session = FakeSessionIdentity(userID: deletedUserID)
        let deletionCheckedIdentity = AsyncTestGate()
        let allowDeletionCleanup = AsyncTestGate()
        let replacementReachedLock = AsyncTestGate()

        let deletion = Task {
            await lock.withLock {
                let currentUserID = await session.currentUserID()
                guard currentUserID == deletedUserID else { return }
                await deletionCheckedIdentity.open()
                await allowDeletionCleanup.wait()

                // This models the SDK's identity-less local sign-out call: once
                // it starts, it clears the local session it owns. The shared
                // lock must keep a replacement sign-in from reaching it here.
                await session.replace(with: nil)
            }
        }
        await deletionCheckedIdentity.wait()

        let replacement = Task {
            await replacementReachedLock.open()
            await lock.withLock {
                await session.replace(with: replacementUserID)
            }
        }
        await replacementReachedLock.wait()
        while await lock.queuedOperationCount == 0 {
            await Task.yield()
        }

        let identityBeforeCleanup = await session.currentUserID()
        XCTAssertEqual(identityBeforeCleanup, deletedUserID)

        await allowDeletionCleanup.open()
        await deletion.value
        await replacement.value

        let finalIdentity = await session.currentUserID()
        XCTAssertEqual(finalIdentity, replacementUserID)
    }

    func testCoordinatorPolicyDoesNotOverwriteAReplacementAfterStaleSuccessfulCleanup() {
        let deletedUserID = UUID()
        let replacementUserID = UUID()
        let staleResult = AccountDeletionResult(sessionCleanup: .cleared)

        XCTAssertFalse(
            AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: staleResult,
                expectedUserID: deletedUserID,
                currentUserID: replacementUserID
            )
        )
        XCTAssertTrue(
            AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: staleResult,
                expectedUserID: deletedUserID,
                currentUserID: deletedUserID
            )
        )
        XCTAssertTrue(
            AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: staleResult,
                expectedUserID: deletedUserID,
                currentUserID: nil
            )
        )
    }

    func testCoordinatorPolicyDoesNotOverwriteAReplacementAfterStaleUnconfirmedError() {
        let deletedUserID = UUID()
        let replacementUserID = UUID()
        let staleError = AccountDeletionError.finalDeletionUnconfirmed(
            sessionCleared: true
        )

        XCTAssertFalse(
            AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: staleError,
                expectedUserID: deletedUserID,
                currentUserID: replacementUserID
            )
        )
        XCTAssertTrue(
            AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: staleError,
                expectedUserID: deletedUserID,
                currentUserID: nil
            )
        )
    }

    func testUnconfirmedDeletionDoesNotSignOutAReplacementSession() async {
        let deletedUserID = UUID()
        let remote = FakeAccountDeletionRemote(
            finalTransportShouldFail: true,
            differentAccountPreserved: true
        )

        do {
            _ = try await AccountDeletionWorkflow(remote: remote)
                .deleteAccount(userID: deletedUserID)
            XCTFail("Expected the final response to remain unconfirmed")
        } catch {
            XCTAssertEqual(
                error as? AccountDeletionError,
                .finalDeletionUnconfirmedForDifferentAccount
            )
            XCTAssertFalse(
                AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                    after: error,
                    expectedUserID: deletedUserID,
                    currentUserID: UUID()
                )
            )
        }
        let cleanupUserIDs = await remote.recordedCleanupExpectedUserIDs()
        XCTAssertEqual(cleanupUserIDs, [deletedUserID])
    }

    func testOfflineConfigurationIsAllowed() throws {
        let configuration = try CloudConfiguration.load(
            infoDictionary: [:],
            environment: [:]
        )
        XCTAssertNil(configuration)
    }

    func testWhitespaceOnlyInfoPlistCloudKeysResolveAsAbsent() throws {
        let configuration = try CloudConfiguration.load(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: "   ",
                CloudConfiguration.publishableKeyInfoKey: "\n\t",
            ],
            environment: [:]
        )
        XCTAssertNil(
            configuration,
            "Blank shipping keys must not create a half-configured cloud client"
        )
    }

    func testLoadNilConfigurationIsTheOnlyPathToOfflineOnlyAvailability() throws {
        // Document the contract used by CloudCoordinator.live(): absent keys →
        // nil configuration → offlineOnly with no SupabaseClientFactory call.
        let missing = try CloudConfiguration.load(infoDictionary: [:], environment: [:])
        XCTAssertNil(missing)

        XCTAssertThrowsError(
            try CloudConfiguration.load(
                infoDictionary: [CloudConfiguration.urlInfoKey: "https://example.supabase.co"],
                environment: [:]
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .incompleteConfiguration)
        }
        XCTAssertThrowsError(
            try CloudConfiguration.load(
                infoDictionary: [CloudConfiguration.publishableKeyInfoKey: "sb_publishable_test"],
                environment: [:]
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .incompleteConfiguration)
        }
    }

    @MainActor
    func testAbsentConfigurationThroughLiveCreatesNoNetworkCapableCloudStack() async {
        // Prove the production factory path — not a hand-built coordinator with
        // pre-set nils. load() nil is the only branch that returns offlineOnly,
        // and that branch never reaches SupabaseClientFactory.make.
        XCTAssertNil(
            try CloudConfiguration.load(infoDictionary: [:], environment: [:])
        )
        let coordinator = CloudCoordinator.live(infoDictionary: [:], environment: [:])

        XCTAssertEqual(coordinator.availability, .offlineOnly)
        // init sets .loading only when an auth service exists; .signedOut means
        // live() did not construct SupabaseAuthService (and therefore no client).
        XCTAssertEqual(coordinator.authState, .signedOut)
        XCTAssertNil(coordinator.signedInUser)
        // canSync requires a non-nil repository and a signed-in user.
        XCTAssertFalse(coordinator.canSync)
        // No synchronization token can be minted without canSync.
        XCTAssertNil(coordinator.beginSynchronization())
        XCTAssertFalse(coordinator.isSynchronizing)
        XCTAssertEqual(coordinator.syncStatus, .idle)

        // start() only opens an auth state stream when auth is non-nil.
        coordinator.start()
        await Task.yield()
        XCTAssertEqual(coordinator.authState, .signedOut)
        XCTAssertEqual(coordinator.availability, .offlineOnly)
        XCTAssertEqual(coordinator.syncStatus, .idle)

        // Auth, recovery, and deep-link entry points refuse without a client —
        // no network-capable path is reachable.
        await coordinator.signIn(email: "reader@example.com", password: "password")
        XCTAssertEqual(
            coordinator.accountMessage,
            "Cloud accounts are not available in this build. Phrasa still works offline."
        )
        await coordinator.signUp(email: "reader@example.com", password: "password")
        XCTAssertEqual(
            coordinator.accountMessage,
            "Cloud accounts are not available in this build. Phrasa still works offline."
        )
        await coordinator.sendPasswordReset(email: "reader@example.com")
        XCTAssertEqual(
            coordinator.accountMessage,
            "Cloud accounts are not available in this build. Phrasa still works offline."
        )
        await coordinator.signInWithApple(idToken: "token", nonce: "nonce")
        XCTAssertEqual(
            coordinator.accountMessage,
            "Cloud accounts are not available in this build. Phrasa still works offline."
        )
        await coordinator.handleOpenURL(
            URL(string: "phrasa://auth/callback?code=should-not-exchange")!
        )
        XCTAssertEqual(
            coordinator.accountMessage,
            "Cloud accounts are not available in this build. Phrasa still works offline."
        )
        await coordinator.signOut()
        let deleted = await coordinator.deleteAccount(expectedUserID: UUID())
        XCTAssertFalse(deleted)

        XCTAssertEqual(coordinator.authState, .signedOut)
        XCTAssertEqual(coordinator.availability, .offlineOnly)
        XCTAssertFalse(coordinator.canSync)
        XCTAssertNil(coordinator.beginSynchronization())
        XCTAssertEqual(coordinator.syncStatus, .idle)
        XCTAssertFalse(coordinator.isAuthenticating)
        XCTAssertFalse(coordinator.isDeletingAccount)
        XCTAssertFalse(coordinator.isSynchronizing)
    }

    @MainActor
    func testShippingInfoPlistPinnedURLEmptyKeyDoesNotConstructClient() async throws {
        // Shipping pins the production URL and leaves the publishable key empty.
        // Without both sides, load must not yield a ready configuration or client.
        let shippingInfo = try XCTUnwrap(Bundle(for: CloudCoordinator.self).infoDictionary)
        let productionURL = CloudConfiguration.productionProjectURLString

        let urlValue = shippingInfo[CloudConfiguration.urlInfoKey] as? String
        XCTAssertTrue(
            urlValue == productionURL || urlValue == "$(PHRASA_SUPABASE_URL)",
            "Shipping Info.plist must carry the pinned production URL or its placeholder"
        )

        // Release ignores env overrides; empty key stays incomplete (no client).
        XCTAssertThrowsError(
            try CloudConfiguration.load(
                infoDictionary: shippingInfo,
                environment: [
                    "SUPABASE_URL": "https://evil.example.com",
                    "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_evil",
                ],
                sourcePolicy: .release
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .incompleteConfiguration)
        }

        let coordinator = CloudCoordinator.live(
            infoDictionary: shippingInfo,
            environment: [:]
        )
        guard case .unavailable = coordinator.availability else {
            return XCTFail(
                "Pinned URL + empty publishable key must be unavailable, got \(coordinator.availability)"
            )
        }
        XCTAssertEqual(coordinator.authState, .signedOut)
        XCTAssertFalse(coordinator.canSync)
        XCTAssertNil(coordinator.beginSynchronization())
    }

    func testUnresolvedBuildSettingPlaceholdersResolveAsAbsent() throws {
        let configuration = try CloudConfiguration.load(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: "$(PHRASA_SUPABASE_URL)",
                CloudConfiguration.publishableKeyInfoKey: "$(PHRASA_SUPABASE_PUBLISHABLE_KEY)",
            ],
            environment: [:]
        )
        XCTAssertNil(
            configuration,
            "Unresolved $(NAME) placeholders must stay offline-only"
        )
    }

    @MainActor
    func testIncompleteConfigurationThroughLiveIsUnavailableWithoutClientOrSync() {
        // Half-filled keys throw before any client is built; live maps that to
        // unavailable with auth/repository still nil.
        let coordinator = CloudCoordinator.live(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: "https://example.supabase.co",
            ],
            environment: [:]
        )
        guard case .unavailable(let message) = coordinator.availability else {
            return XCTFail("Expected unavailable availability, got \(coordinator.availability)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(coordinator.authState, .signedOut)
        XCTAssertFalse(coordinator.canSync)
        XCTAssertNil(coordinator.beginSynchronization())
        XCTAssertNil(coordinator.signedInUser)
    }

    func testSecretKeyIsRejected() {
        XCTAssertThrowsError(
            try CloudConfiguration(
                projectURL: URL(string: "https://example.supabase.co")!,
                publishableKey: "sb_secret_do-not-ship"
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .privilegedKey)
        }
    }

    func testServiceRoleJWTIsRejected() throws {
        let payload = Data(#"{"role":"service_role"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(
            try CloudConfiguration(
                projectURL: URL(string: "https://example.supabase.co")!,
                publishableKey: "header.\(payload).signature"
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .privilegedKey)
        }
    }

    func testSyncPlanUsesBaselineInsteadOfDeviceClocksForOneSidedChanges() throws {
        let accountID = UUID()
        let id = UUID()
        let baseline = ScriptDocument(
            id: id,
            title: "Shared baseline",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: id,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [id: record],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
        var cloudEdit = baseline
        cloudEdit.title = "Cloud edit from a slow clock"
        cloudEdit.updatedAt = Date(timeIntervalSince1970: 50)

        let downloadPlan = try CloudScriptSyncPlan.make(
            local: [baseline],
            remote: [cloudEdit],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(downloadPlan.applyLocally.map(\.title), [cloudEdit.title])
        XCTAssertEqual(downloadPlan.applyLocally.first?.updatedAt, baseline.updatedAt)
        XCTAssertEqual(downloadPlan.upload.map(\.title), [cloudEdit.title])

        var localEdit = baseline
        localEdit.body = "Offline work from a slow clock"
        localEdit.updatedAt = Date(timeIntervalSince1970: 25)
        let uploadPlan = try CloudScriptSyncPlan.make(
            local: [localEdit],
            remote: [baseline],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(uploadPlan.upload.map(\.body), [localEdit.body])
        XCTAssertEqual(uploadPlan.upload.first?.updatedAt, baseline.updatedAt)
        XCTAssertEqual(uploadPlan.applyLocally.map(\.body), [localEdit.body])
    }

    func testCloudOutlineCodecPreservesNoteOnlyRowsAndDropsEmptyPlaceholders() throws {
        let noteOnly = OutlinePoint(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            text: "   ",
            note: "Pause before the reveal"
        )
        let empty = OutlinePoint(text: " \n", note: "\t")

        let encoded = try XCTUnwrap(
            CloudOutlinePoint.cloudPoints(from: [empty, noteOnly])
        )

        XCTAssertEqual(encoded.count, 1)
        XCTAssertEqual(encoded.first?.point, noteOnly)
        XCTAssertNil(CloudOutlinePoint(empty).point)
    }

    func testCloudOutlineJSONRoundTripPreservesANoteOnlyRow() throws {
        let original = OutlinePoint(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            text: "",
            note: "Supporting detail without a heading"
        )

        let data = try JSONEncoder().encode(CloudOutlinePoint(original))
        let decoded = try JSONDecoder().decode(CloudOutlinePoint.self, from: data)

        XCTAssertEqual(decoded.point, original)
    }

    func testScriptFingerprintIncludesNoteOnlyOutlineRows() {
        let noteOnly = OutlinePoint(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            text: "",
            note: "Remember the source"
        )
        let empty = OutlinePoint(text: "  ", note: "\n")
        let withoutOutline = ScriptDocument(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            title: "Outline fingerprint",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        var withNoteOnly = withoutOutline
        withNoteOnly.outline = [empty, noteOnly]
        var normalized = withoutOutline
        normalized.outline = [noteOnly]

        XCTAssertNotEqual(
            CloudScriptFingerprint.make(withoutOutline),
            CloudScriptFingerprint.make(withNoteOnly)
        )
        XCTAssertEqual(
            CloudScriptFingerprint.make(withNoteOnly),
            CloudScriptFingerprint.make(normalized)
        )

        normalized.outline[0].note = "A changed source"
        XCTAssertNotEqual(
            CloudScriptFingerprint.make(withNoteOnly),
            CloudScriptFingerprint.make(normalized)
        )
    }

    func testScriptFingerprintNormalizesRoundTripContentAndIgnoresMutableTimestamps() {
        let id = UUID()
        let point = OutlinePoint(text: "Keep", note: "")
        var local = ScriptDocument(
            id: id,
            title: "Temporary",
            body: "Same body",
            tags: ["one", "two"],
            outline: [OutlinePoint(text: "   "), point],
            lastOpenedAt: Date(timeIntervalSince1970: 10),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123_456_4),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        local.title = " \n"
        var fetched = local
        fetched.title = "Untitled script"
        fetched.outline = [point]
        fetched.lastOpenedAt = Date(timeIntervalSince1970: 100)
        fetched.createdAt = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        fetched.updatedAt = Date(timeIntervalSince1970: 200)

        XCTAssertEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(fetched)
        )
        fetched.body = "Actually changed"
        XCTAssertNotEqual(
            CloudScriptFingerprint.make(local),
            CloudScriptFingerprint.make(fetched)
        )
    }

    func testSyncPlanMergesTwoDeviceOpenRecencyWithoutAContentConflict() throws {
        let accountID = UUID()
        let baseline = ScriptDocument(
            title: "Shared content",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: baseline.id,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
        )
        let state = scriptState(accountID: accountID, record: record)
        var local = baseline
        local.lastOpenedAt = Date(timeIntervalSince1970: 20)
        var remote = baseline
        remote.lastOpenedAt = Date(timeIntervalSince1970: 30)

        let remoteLatest = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 40)
        )
        XCTAssertTrue(remoteLatest.upload.isEmpty)
        XCTAssertEqual(remoteLatest.applyLocally.first?.lastOpenedAt, remote.lastOpenedAt)

        local.lastOpenedAt = Date(timeIntervalSince1970: 35)
        let localLatest = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 40)
        )
        XCTAssertEqual(localLatest.upload.first?.lastOpenedAt, local.lastOpenedAt)
        XCTAssertTrue(localLatest.applyLocally.isEmpty)
    }

    func testConcurrentRemoteOpenIsCarriedOntoALocalContentEdit() throws {
        let accountID = UUID()
        let baseline = ScriptDocument(
            title: "Shared content",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: baseline.id,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
        )
        var localEdit = baseline
        localEdit.body = "Local content edit"
        localEdit.updatedAt = Date(timeIntervalSince1970: 20)
        var remotelyOpened = baseline
        remotelyOpened.lastOpenedAt = Date(timeIntervalSince1970: 30)

        let plan = try CloudScriptSyncPlan.make(
            local: [localEdit],
            remote: [remotelyOpened],
            state: scriptState(accountID: accountID, record: record),
            detectedAt: Date(timeIntervalSince1970: 40)
        )

        XCTAssertEqual(plan.upload.map(\.body), [localEdit.body])
        XCTAssertEqual(plan.upload.first?.lastOpenedAt, remotelyOpened.lastOpenedAt)
        XCTAssertEqual(plan.applyLocally, plan.upload)
    }

    func testSyncPlanCombinesMutableTimestampMaximaForIdenticalContent() throws {
        let accountID = UUID()
        let baseline = ScriptDocument(
            title: "Same final content",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: baseline.id,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
        )
        var local = baseline
        local.updatedAt = Date(timeIntervalSince1970: 50)
        local.lastOpenedAt = Date(timeIntervalSince1970: 90)
        var remote = baseline
        remote.updatedAt = Date(timeIntervalSince1970: 80)
        remote.lastOpenedAt = Date(timeIntervalSince1970: 60)

        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: scriptState(accountID: accountID, record: record),
            detectedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(plan.upload.first?.updatedAt, remote.updatedAt)
        XCTAssertEqual(plan.upload.first?.lastOpenedAt, local.lastOpenedAt)
        XCTAssertEqual(plan.applyLocally, plan.upload)
    }

    func testSyncPlanPreservesDivergentScriptsAsADeterministicConflictCopy() throws {
        let accountID = UUID()
        let baseline = ScriptDocument(title: "Shared", folderID: UUID())
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
            tombstonesByFolderID: [:]
        )
        var local = baseline
        local.body = "Local edit"
        var remote = baseline
        remote.body = "Cloud edit"

        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: state,
            detectedAt: .now
        )
        let expectedConflict = CloudScriptConflictCopy.make(
            local: local,
            accountID: accountID
        )
        XCTAssertEqual(plan.upload, [expectedConflict])
        XCTAssertNil(expectedConflict.folderID)
        XCTAssertEqual(plan.applyLocally, [remote])
        XCTAssertEqual(
            Set(plan.records.map(\.scriptID)),
            [baseline.id, expectedConflict.id]
        )

        // Simulate the upload succeeding but local persistence failing. The
        // next plan must reuse the same conflict identity and download it,
        // never create a second duplicate.
        let retryPlan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote, expectedConflict],
            state: state,
            detectedAt: Date.now.addingTimeInterval(1)
        )
        XCTAssertTrue(retryPlan.upload.isEmpty)
        XCTAssertEqual(
            Set(retryPlan.applyLocally.map(\.id)),
            [remote.id, expectedConflict.id]
        )
    }

    func testSyncPlanPreservesOneSidedScripts() throws {
        let accountID = UUID()
        let local = ScriptDocument(title: "Local")
        let remote = ScriptDocument(title: "Remote")
        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [remote],
            state: .empty(accountID: accountID),
            detectedAt: .now
        )
        XCTAssertEqual(plan.upload, [local])
        XCTAssertEqual(plan.applyLocally, [remote])
    }

    func testSyncPlanPropagatesKnownLocalDeletionToExactCloudVersion() throws {
        let accountID = UUID()
        let scriptID = UUID()
        let remote = ScriptDocument(
            id: scriptID,
            title: "Stale cloud copy",
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

        let plan = try CloudScriptSyncPlan.make(
            local: [],
            remote: [remote],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 40)
        )

        XCTAssertEqual(plan.deleteRemotely.map(\.tombstone), [tombstone])
        XCTAssertEqual(plan.deleteRemotely.map(\.expectedRemote), [remote])
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.upload.isEmpty)
    }

    func testSyncPlanRestoresCloudEditThatDivergedFromDeletedBaseline() throws {
        let accountID = UUID()
        let scriptID = UUID()
        let remote = ScriptDocument(
            id: scriptID,
            title: "Edited after deletion",
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        let baseline = ScriptDocument(
            id: scriptID,
            title: "Deleted baseline",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: scriptID,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
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

        let plan = try CloudScriptSyncPlan.make(
            local: [],
            remote: [remote],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 50)
        )

        XCTAssertEqual(plan.applyLocally, [remote])
        XCTAssertEqual(plan.clearedTombstoneIDs, [scriptID])
        XCTAssertTrue(plan.deleteRemotely.isEmpty)
    }

    func testSyncPlanPropagatesKnownRemoteDeletionInsteadOfReuploadingLocalCopy() throws {
        let accountID = UUID()
        let local = ScriptDocument(
            title: "Deleted on another device",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: local.id,
            lastSyncedUpdatedAt: local.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(local)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [local.id: record],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
        let detectedAt = Date(timeIntervalSince1970: 30)

        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [],
            state: state,
            detectedAt: detectedAt,
            verifiedRemoteAbsenceIDs: [local.id]
        )

        XCTAssertTrue(plan.upload.isEmpty)
        XCTAssertEqual(
            plan.deleteLocally,
            [ScriptDeletionTombstone(scriptID: local.id, deletedAt: detectedAt)]
        )
        XCTAssertEqual(plan.tombstones, plan.deleteLocally)
    }

    func testSyncPlanPreservesAnUnverifiedRemoteAbsence() throws {
        let accountID = UUID()
        let local = ScriptDocument(
            title: "Still present locally",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: local.id,
            lastSyncedUpdatedAt: local.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(local)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [local.id: record],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )

        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(
            CloudScriptSyncPlan.remoteAbsenceCandidateIDs(remote: [], state: state),
            [local.id]
        )
        XCTAssertTrue(plan.deleteLocally.isEmpty)
        XCTAssertTrue(plan.tombstones.isEmpty)
        XCTAssertTrue(plan.upload.isEmpty)
        XCTAssertEqual(plan.records, [record])
    }

    func testKeysetPageValidationRequiresStrictlyIncreasingExactCountedPages() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let fourthID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        var accumulated: [Int] = []
        var expectedTotal: Int?

        XCTAssertFalse(try SupabaseCloudRepository.appendCompleteKeysetPage(
            [1, 2],
            rowIDs: [firstID, secondID],
            after: nil,
            reportedCount: 4,
            expectedTotal: &expectedTotal,
            accumulated: &accumulated
        ))
        XCTAssertTrue(try SupabaseCloudRepository.appendCompleteKeysetPage(
            [3, 4],
            rowIDs: [thirdID, fourthID],
            after: secondID,
            reportedCount: 2,
            expectedTotal: &expectedTotal,
            accumulated: &accumulated
        ))
        XCTAssertEqual(accumulated, [1, 2, 3, 4])

        var invalid: [Int] = []
        var invalidExpectedTotal: Int?
        XCTAssertThrowsError(try SupabaseCloudRepository.appendCompleteKeysetPage(
            [1],
            rowIDs: [firstID],
            after: secondID,
            reportedCount: 1,
            expectedTotal: &invalidExpectedTotal,
            accumulated: &invalid
        ))

        var truncated = [1, 2]
        var originalTotal: Int? = 4
        XCTAssertThrowsError(try SupabaseCloudRepository.appendCompleteKeysetPage(
            [3],
            rowIDs: [thirdID],
            after: secondID,
            reportedCount: 1,
            expectedTotal: &originalTotal,
            accumulated: &truncated
        ))
    }

    func testConditionalFolderDeleteTimestampPreservesServerMicroseconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123456)

        XCTAssertEqual(
            SupabaseCloudRepository.timestamp(date),
            "2023-11-14T22:13:20.123456Z"
        )
    }

    func testSyncPlanUploadsOfflineEditDespiteClockSkewAndRemoteAbsence() throws {
        let accountID = UUID()
        let baseline = ScriptDocument(
            title: "Shared baseline",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        var local = baseline
        local.body = "Real offline work"
        local.updatedAt = Date(timeIntervalSince1970: 20)
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: local.id,
            lastSyncedUpdatedAt: baseline.updatedAt,
            lastSyncedFingerprint: CloudScriptFingerprint.make(baseline)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [local.id: record],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )

        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 200),
            verifiedRemoteAbsenceIDs: [local.id]
        )

        XCTAssertEqual(plan.upload, [local])
        XCTAssertTrue(plan.deleteLocally.isEmpty)
        XCTAssertTrue(plan.tombstones.isEmpty)
    }

    func testSyncPlanNeverUploadsScriptOwnedByAnotherAccount() throws {
        let accountB = UUID()
        let local = ScriptDocument(title: "Account A private script")
        let stateForB = CloudLocalSyncState(
            accountID: accountB,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [local.id],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )

        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [],
            state: stateForB,
            detectedAt: .now
        )

        XCTAssertTrue(plan.upload.isEmpty)
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.records.isEmpty)
    }

    func testSyncInputCountsOnlyProtectedContentStillPresentOnThisDevice() {
        let accountID = UUID()
        let accountOwnedScript = ScriptDocument(title: "This account")
        let otherAccountScript = ScriptDocument(title: "Another account")
        let quarantinedScript = ScriptDocument(title: "Unverified restored script")
        let otherAccountFolder = ScriptFolder(name: "Another account folder")
        let accountOwnedFolder = ScriptFolder(name: "This account folder")
        let staleProtectedScriptID = UUID()
        let staleProtectedFolderID = UUID()
        let library = LibrarySnapshot(
            scripts: [accountOwnedScript, otherAccountScript, quarantinedScript],
            folders: [otherAccountFolder, accountOwnedFolder],
            settings: .init(),
            seeded: true
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [accountOwnedScript.id: CloudScriptSyncRecord(
                accountID: accountID,
                scriptID: accountOwnedScript.id,
                lastSyncedUpdatedAt: nil
            )],
            // The persistence layer puts both prior-account and quarantined
            // IDs in this protected set. Neither may be claimed implicitly.
            scriptIDsOwnedByOtherAccounts: [
                otherAccountScript.id,
                quarantinedScript.id,
                staleProtectedScriptID,
            ],
            currentAccountFolderRecords: [accountOwnedFolder.id: CloudFolderSyncRecord(
                accountID: accountID,
                folderID: accountOwnedFolder.id,
                hasSynced: false
            )],
            folderIDsOwnedByOtherAccounts: [
                otherAccountFolder.id,
                staleProtectedFolderID,
            ],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )

        let input = CloudSyncInput(library: library, state: state)

        XCTAssertEqual(input.excludedLocalScriptCount, 2)
        XCTAssertEqual(input.excludedLocalFolderCount, 1)
    }

    func testSuccessfulSyncDisclosureDefaultsToNoneAndReportsExactProtectedCounts() {
        let ordinarySummary = CloudSyncSummary(
            uploadedScripts: 3,
            downloadedScripts: 2,
            completedAt: .now
        )

        XCTAssertEqual(ordinarySummary.excludedLocalScriptCount, 0)
        XCTAssertEqual(ordinarySummary.excludedLocalFolderCount, 0)
        XCTAssertNil(CloudSyncDisclosure.deviceOnlyWarning(for: ordinarySummary))

        let protectedSummary = CloudSyncSummary(
            uploadedScripts: 3,
            downloadedScripts: 2,
            completedAt: .now,
            excludedLocalScriptCount: 1,
            excludedLocalFolderCount: 2
        )
        XCTAssertEqual(
            CloudSyncDisclosure.deviceOnlyWarning(for: protectedSummary),
            "Needs attention: 1 script and 2 folders remain only on this device because they belong to another account or have unverified ownership. Explicit adoption is deferred until backup confirmation is trustworthy."
        )
    }

    func testReleaseConfigurationPinsProductionHostAndIgnoresEnv() throws {
        let production = CloudConfiguration.productionProjectURLString
        let accepted = try CloudConfiguration.load(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: production,
                CloudConfiguration.publishableKeyInfoKey: "sb_publishable_shipping",
            ],
            environment: [
                "SUPABASE_URL": "https://evil.example.com",
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_evil",
                "EXPO_PUBLIC_SUPABASE_URL": "https://evil.example.com",
            ],
            sourcePolicy: .release
        )
        XCTAssertEqual(accepted?.projectURL.host, CloudConfiguration.productionProjectHost)
        XCTAssertEqual(accepted?.publishableKey, "sb_publishable_shipping")

        XCTAssertThrowsError(
            try CloudConfiguration.load(
                infoDictionary: [
                    CloudConfiguration.urlInfoKey: "https://other.supabase.co",
                    CloudConfiguration.publishableKeyInfoKey: "sb_publishable_shipping",
                ],
                environment: [:],
                sourcePolicy: .release
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .invalidProjectURL)
        }

        let offline = try CloudConfiguration.load(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: "$(PHRASA_SUPABASE_URL)",
                CloudConfiguration.publishableKeyInfoKey: "",
            ],
            environment: [
                "SUPABASE_URL": production,
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_env",
            ],
            sourcePolicy: .release
        )
        XCTAssertNil(offline)
    }

    func testDebugLocalhostOverrideAndExpoEnvIgnored() throws {
        let localhost = try CloudConfiguration.load(
            infoDictionary: [:],
            environment: [
                "SUPABASE_URL": "http://localhost:54321",
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_local",
            ],
            sourcePolicy: .debug
        )
        XCTAssertEqual(localhost?.projectURL.host, "localhost")

        let expoIgnored = try CloudConfiguration.load(
            infoDictionary: [:],
            environment: [
                "EXPO_PUBLIC_SUPABASE_URL": CloudConfiguration.productionProjectURLString,
                "EXPO_PUBLIC_SUPABASE_ANON_KEY": "sb_publishable_anon",
            ],
            sourcePolicy: .debug
        )
        XCTAssertNil(expoIgnored)
    }

    func testSyncStatusAndExcludedCountsResetWhenIdentityChangesFromAToB() {
        let accountA = CloudUser(id: UUID(), email: "a@example.com")
        let accountB = CloudUser(id: UUID(), email: "b@example.com")
        let accountAStatus = CloudSyncStatus.succeeded(CloudSyncSummary(
            uploadedScripts: 1,
            downloadedScripts: 2,
            completedAt: .now,
            excludedLocalScriptCount: 3,
            excludedLocalFolderCount: 4
        ))

        let resolved = CloudSyncIdentityPolicy.resolvedSyncStatus(
            currentAuthState: .signedIn(accountA),
            nextAuthState: .signedIn(accountB),
            currentSyncStatus: accountAStatus
        )

        XCTAssertEqual(resolved, .idle)
    }

    func testSyncStatusAndExcludedCountsResetWhenAccountBecomesSignedOut() {
        let accountA = CloudUser(id: UUID(), email: "a@example.com")
        let accountAStatus = CloudSyncStatus.succeeded(CloudSyncSummary(
            uploadedScripts: 0,
            downloadedScripts: 0,
            completedAt: .now,
            excludedLocalScriptCount: 1,
            excludedLocalFolderCount: 2
        ))

        let resolved = CloudSyncIdentityPolicy.resolvedSyncStatus(
            currentAuthState: .passwordRecovery(accountA),
            nextAuthState: .signedOut,
            currentSyncStatus: accountAStatus
        )

        XCTAssertEqual(resolved, .idle)
    }

    func testSameUserRefreshAndRecoveryTransitionsPreserveSyncStatus() {
        let accountID = UUID()
        let originalUser = CloudUser(id: accountID, email: "before@example.com")
        let refreshedUser = CloudUser(id: accountID, email: "after@example.com")
        let status = CloudSyncStatus.succeeded(CloudSyncSummary(
            uploadedScripts: 1,
            downloadedScripts: 1,
            completedAt: .now,
            excludedLocalScriptCount: 2,
            excludedLocalFolderCount: 1
        ))

        let refreshedStatus = CloudSyncIdentityPolicy.resolvedSyncStatus(
            currentAuthState: .signedIn(originalUser),
            nextAuthState: .signedIn(refreshedUser),
            currentSyncStatus: status
        )
        let recoveryStatus = CloudSyncIdentityPolicy.resolvedSyncStatus(
            currentAuthState: .signedIn(refreshedUser),
            nextAuthState: .passwordRecovery(refreshedUser),
            currentSyncStatus: refreshedStatus
        )
        let completedRecoveryStatus = CloudSyncIdentityPolicy.resolvedSyncStatus(
            currentAuthState: .passwordRecovery(refreshedUser),
            nextAuthState: .signedIn(refreshedUser),
            currentSyncStatus: recoveryStatus
        )

        XCTAssertEqual(refreshedStatus, status)
        XCTAssertEqual(recoveryStatus, status)
        XCTAssertEqual(completedRecoveryStatus, status)
    }

    func testLateAccountACompletionCannotOverwriteAnActiveAccountBSync() {
        let accountAID = UUID()
        let accountBID = UUID()
        var lane = CloudSynchronizationLane()
        let accountAToken = lane.begin(accountID: accountAID)

        // An observed or callback-driven identity transition invalidates A,
        // after which B is allowed to begin its own synchronization.
        lane.reset()
        let accountBToken = lane.begin(accountID: accountBID)
        let accountBStatus = CloudSyncStatus.succeeded(CloudSyncSummary(
            uploadedScripts: 2,
            downloadedScripts: 3,
            completedAt: .now
        ))

        XCTAssertNil(lane.resolvedCompletionStatus(
            .failed("Late account A failure"),
            for: accountAToken,
            currentAccountID: accountBID
        ))
        XCTAssertEqual(lane.activeToken, accountBToken)
        XCTAssertEqual(
            lane.resolvedCompletionStatus(
                accountBStatus,
                for: accountBToken,
                currentAccountID: accountBID
            ),
            accountBStatus
        )
        XCTAssertNil(lane.activeToken)
    }

    func testLateCompletionCannotOverwriteSameAccountAfterSignOutAndResignIn() {
        let accountID = UUID()
        var lane = CloudSynchronizationLane()
        let signedOutGeneration = lane.begin(accountID: accountID)

        // Re-signing into the same account creates a distinct operation
        // lifetime even though the account UUID is unchanged.
        lane.reset()
        let resignedInGeneration = lane.begin(accountID: accountID)
        XCTAssertNotEqual(signedOutGeneration, resignedInGeneration)

        XCTAssertNil(lane.resolvedCompletionStatus(
            .succeeded(CloudSyncSummary(
                uploadedScripts: 99,
                downloadedScripts: 99,
                completedAt: .now
            )),
            for: signedOutGeneration,
            currentAccountID: accountID
        ))
        XCTAssertEqual(lane.activeToken, resignedInGeneration)

        let currentStatus = CloudSyncStatus.failed("Current generation result")
        XCTAssertEqual(
            lane.resolvedCompletionStatus(
                currentStatus,
                for: resignedInGeneration,
                currentAccountID: accountID
            ),
            currentStatus
        )
        XCTAssertNil(lane.activeToken)
    }

    func testLegacyScriptRecordNeverInfersRemoteDeletion() throws {
        let accountID = UUID()
        let local = ScriptDocument(title: "Legacy local copy")
        let record = CloudScriptSyncRecord(
            accountID: accountID,
            scriptID: local.id,
            lastSyncedUpdatedAt: local.updatedAt
        )
        let state = scriptState(accountID: accountID, record: record)

        let plan = try CloudScriptSyncPlan.make(
            local: [local],
            remote: [],
            state: state,
            detectedAt: .now,
            verifiedRemoteAbsenceIDs: [local.id]
        )

        XCTAssertEqual(plan.upload, [local])
        XCTAssertTrue(plan.deleteLocally.isEmpty)
        XCTAssertTrue(plan.tombstones.isEmpty)
        XCTAssertTrue(CloudScriptSyncPlan.remoteAbsenceCandidateIDs(
            remote: [],
            state: state
        ).isEmpty)
    }

    func testOptimisticWritesCarryFetchedVersionsAndRejectRacedValues() {
        let existingScript = ScriptDocument(
            title: "Fetched script",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        var desiredScript = existingScript
        desiredScript.body = "Local edit"
        desiredScript.updatedAt = Date(timeIntervalSince1970: 20)
        let newScript = ScriptDocument(title: "Brand new")
        let scriptWrites = CloudScriptWrite.make(
            desired: [desiredScript, newScript],
            from: [existingScript]
        )
        XCTAssertEqual(scriptWrites[0].expectedRemote, existingScript)
        XCTAssertNil(scriptWrites[1].expectedRemote)
        XCTAssertTrue(scriptWrites[0].currentMatchesDesired(desiredScript))
        var serverTimestampedScript = desiredScript
        serverTimestampedScript.updatedAt = Date(timeIntervalSince1970: 999)
        XCTAssertTrue(scriptWrites[0].currentMatchesDesired(serverTimestampedScript))
        var racedScript = desiredScript
        racedScript.body = "Another device won"
        XCTAssertFalse(scriptWrites[0].currentMatchesDesired(racedScript))
        var openedDesired = desiredScript
        openedDesired.lastOpenedAt = Date(timeIntervalSince1970: 50)
        let openedWrite = CloudScriptWrite(
            desired: openedDesired,
            expectedRemote: existingScript
        )
        var newerRemoteOpen = openedDesired
        newerRemoteOpen.lastOpenedAt = Date(timeIntervalSince1970: 60)
        XCTAssertTrue(openedWrite.currentMatchesDesired(newerRemoteOpen))
        var olderRemoteOpen = openedDesired
        olderRemoteOpen.lastOpenedAt = Date(timeIntervalSince1970: 40)
        XCTAssertFalse(openedWrite.currentMatchesDesired(olderRemoteOpen))

        let existingFolder = ScriptFolder(
            name: "Fetched folder",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let desiredFolder = ScriptFolder(
            id: existingFolder.id,
            name: "Local rename",
            createdAt: existingFolder.createdAt
        )
        let newFolder = ScriptFolder(name: "Brand new folder")
        let folderWrites = CloudFolderWrite.make(
            desired: [desiredFolder, newFolder],
            from: [existingFolder]
        )
        XCTAssertEqual(folderWrites[0].expectedRemote, existingFolder)
        XCTAssertNil(folderWrites[1].expectedRemote)
        XCTAssertTrue(folderWrites[0].currentMatchesDesired(desiredFolder))
        let racedFolder = ScriptFolder(
            id: existingFolder.id,
            name: "Another device rename",
            createdAt: existingFolder.createdAt
        )
        XCTAssertFalse(folderWrites[0].currentMatchesDesired(racedFolder))
    }

    func testFolderSyncNeverUploadsAnotherAccountsFolderOrFolderLink() throws {
        let accountB = UUID()
        let accountAFolder = ScriptFolder(name: "Account A confidential project")
        let accountBFolder = ScriptFolder(name: "Account B project")
        let stateForB = CloudLocalSyncState(
            accountID: accountB,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [accountBFolder.id: CloudFolderSyncRecord(
                accountID: accountB,
                folderID: accountBFolder.id,
                hasSynced: false
            )],
            folderIDsOwnedByOtherAccounts: [accountAFolder.id],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )

        let plan = try CloudFolderSyncPlan.make(
            local: [accountAFolder, accountBFolder],
            remote: [],
            state: stateForB,
            detectedAt: .now
        )

        XCTAssertEqual(plan.upload, [accountBFolder])
        XCTAssertFalse(plan.allowedFolderIDs.contains(accountAFolder.id))
        let script = ScriptDocument(
            title: "Created for B inside A's local folder",
            folderID: accountAFolder.id
        )
        XCTAssertNil(plan.removingForeignFolderLinks(from: [script]).first?.folderID)
    }

    func testFolderSyncPropagatesLocalDeletionWithoutDownloadingOldCloudRow() throws {
        let accountID = UUID()
        let folder = ScriptFolder(
            name: "Old cloud folder",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let tombstone = FolderDeletionTombstone(
            folderID: folder.id,
            deletedAt: Date(timeIntervalSince1970: 20)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [folder.id: CloudFolderSyncRecord(
                accountID: accountID,
                folderID: folder.id,
                hasSynced: true,
                lastSyncedName: folder.name,
                lastSyncedCreatedAt: folder.createdAt
            )],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [folder.id: tombstone]
        )

        let plan = try CloudFolderSyncPlan.make(
            local: [],
            remote: [folder],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(plan.deleteRemotely.map(\.tombstone), [tombstone])
        XCTAssertEqual(plan.deleteRemotely.map(\.expectedRemote), [folder])
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertFalse(plan.allowedFolderIDs.contains(folder.id))
    }

    func testFolderSyncPropagatesKnownRemoteDeletionInsteadOfReuploading() throws {
        let accountID = UUID()
        let folder = ScriptFolder(
            name: "Deleted on another device",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [folder.id: CloudFolderSyncRecord(
                accountID: accountID,
                folderID: folder.id,
                hasSynced: true,
                lastSyncedName: folder.name,
                lastSyncedCreatedAt: folder.createdAt
            )],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
        let detectedAt = Date(timeIntervalSince1970: 30)

        let plan = try CloudFolderSyncPlan.make(
            local: [folder],
            remote: [],
            state: state,
            detectedAt: detectedAt,
            verifiedRemoteAbsenceIDs: [folder.id]
        )

        XCTAssertTrue(plan.upload.isEmpty)
        XCTAssertEqual(
            plan.deleteLocally,
            [FolderDeletionTombstone(folderID: folder.id, deletedAt: detectedAt)]
        )
        XCTAssertEqual(plan.tombstones, plan.deleteLocally)
        XCTAssertFalse(plan.allowedFolderIDs.contains(folder.id))
    }

    func testFolderBaselineTreatsServerRoundedCreationDateAsTheSameGeneration() throws {
        let accountID = UUID()
        let folderID = UUID()
        let localCreationDate = Date(
            timeIntervalSince1970: 1_700_000_000.123_456_4
        )
        let fetchedCreationDate = Date(
            timeIntervalSince1970: 1_700_000_000.123_456
        )
        let remote = ScriptFolder(
            id: folderID,
            name: "Just uploaded",
            createdAt: fetchedCreationDate
        )
        let record = CloudFolderSyncRecord(
            accountID: accountID,
            folderID: folderID,
            hasSynced: true,
            lastSyncedName: remote.name,
            lastSyncedCreatedAt: localCreationDate
        )

        let plan = try CloudFolderSyncPlan.make(
            local: [],
            remote: [remote],
            state: folderState(accountID: accountID, record: record),
            detectedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )

        XCTAssertEqual(plan.deleteRemotely.map(\.expectedRemote), [remote])
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(CloudFolderSyncPlan.matches(
            remote,
            baseline: ScriptFolder(
                id: folderID,
                name: remote.name,
                createdAt: localCreationDate
            )
        ))
    }

    func testFolderSyncPreservesUnverifiedAbsenceOfTheSharedBaseline() throws {
        let accountID = UUID()
        let baseline = ScriptFolder(
            name: "Shared folder",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let record = CloudFolderSyncRecord(
            accountID: accountID,
            folderID: baseline.id,
            hasSynced: true,
            lastSyncedName: baseline.name,
            lastSyncedCreatedAt: baseline.createdAt
        )
        let state = folderState(accountID: accountID, record: record)

        let plan = try CloudFolderSyncPlan.make(
            local: [baseline],
            remote: [],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(
            CloudFolderSyncPlan.remoteAbsenceCandidateIDs(remote: [], state: state),
            [baseline.id]
        )
        XCTAssertTrue(plan.deleteLocally.isEmpty)
        XCTAssertTrue(plan.tombstones.isEmpty)
        XCTAssertTrue(plan.upload.isEmpty)
        XCTAssertTrue(plan.allowedFolderIDs.contains(baseline.id))
    }

    func testFolderSyncUploadsLocalRenameOrRecreationInsteadOfAcceptingRemoteAbsence() throws {
        let accountID = UUID()
        let baseline = ScriptFolder(
            name: "Original",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let record = CloudFolderSyncRecord(
            accountID: accountID,
            folderID: baseline.id,
            hasSynced: true,
            lastSyncedName: baseline.name,
            lastSyncedCreatedAt: baseline.createdAt
        )
        let state = folderState(accountID: accountID, record: record)
        let renamed = ScriptFolder(
            id: baseline.id,
            name: "Renamed offline",
            createdAt: baseline.createdAt
        )
        let recreated = ScriptFolder(
            id: baseline.id,
            name: "Recreated offline",
            createdAt: Date(timeIntervalSince1970: 30)
        )

        let renamedPlan = try CloudFolderSyncPlan.make(
            local: [renamed],
            remote: [],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 40),
            verifiedRemoteAbsenceIDs: [baseline.id]
        )
        let recreatedPlan = try CloudFolderSyncPlan.make(
            local: [recreated],
            remote: [],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 40),
            verifiedRemoteAbsenceIDs: [baseline.id]
        )

        XCTAssertEqual(renamedPlan.upload, [renamed])
        XCTAssertEqual(recreatedPlan.upload, [recreated])
        XCTAssertTrue(renamedPlan.deleteLocally.isEmpty)
        XCTAssertTrue(recreatedPlan.deleteLocally.isEmpty)
    }

    func testFolderSyncDownloadsOneSidedRemoteRenameFromTheBaseline() throws {
        let accountID = UUID()
        let baseline = ScriptFolder(
            name: "Original",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let remoteRename = ScriptFolder(
            id: baseline.id,
            name: "Renamed in cloud",
            createdAt: baseline.createdAt
        )
        let record = CloudFolderSyncRecord(
            accountID: accountID,
            folderID: baseline.id,
            hasSynced: true,
            lastSyncedName: baseline.name,
            lastSyncedCreatedAt: baseline.createdAt
        )

        let plan = try CloudFolderSyncPlan.make(
            local: [baseline],
            remote: [remoteRename],
            state: folderState(accountID: accountID, record: record),
            detectedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(plan.applyLocally, [remoteRename])
        XCTAssertTrue(plan.upload.isEmpty)
    }

    func testFolderSyncAbortsWhenBothSidesDivergeFromTheBaseline() {
        let accountID = UUID()
        let baseline = ScriptFolder(
            name: "Original",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let local = ScriptFolder(
            id: baseline.id,
            name: "Local rename",
            createdAt: baseline.createdAt
        )
        let remote = ScriptFolder(
            id: baseline.id,
            name: "Remote rename",
            createdAt: baseline.createdAt
        )
        let record = CloudFolderSyncRecord(
            accountID: accountID,
            folderID: baseline.id,
            hasSynced: true,
            lastSyncedName: baseline.name,
            lastSyncedCreatedAt: baseline.createdAt
        )

        XCTAssertThrowsError(try CloudFolderSyncPlan.make(
            local: [local],
            remote: [remote],
            state: folderState(accountID: accountID, record: record),
            detectedAt: Date(timeIntervalSince1970: 20)
        )) { error in
            guard let repositoryError = error as? CloudRepositoryError else {
                return XCTFail("Expected a cloud repository conflict, got \(error)")
            }
            guard case .conflictingFolderEdits(
                let id,
                let deviceName,
                let cloudName
            ) = repositoryError else {
                return XCTFail("Expected conflicting folder edits, got \(error)")
            }
            XCTAssertEqual(id, local.id)
            XCTAssertEqual(deviceName, local.name)
            XCTAssertEqual(cloudName, remote.name)
            let recovery = repositoryError.localizedDescription
            XCTAssertTrue(recovery.contains("Export a backup"))
            XCTAssertTrue(recovery.contains(local.id.uuidString))
            XCTAssertTrue(recovery.contains("Device: “\(local.name)”"))
            XCTAssertTrue(recovery.contains("Cloud: “\(remote.name)”"))
            XCTAssertTrue(recovery.contains(
                "rename this device’s folder to “\(remote.name)”"
            ))
            XCTAssertTrue(recovery.contains(
                "rename the cloud folder to “\(local.name)”"
            ))
            XCTAssertFalse(recovery.localizedCaseInsensitiveContains("delete"))
        }
    }

    func testLegacyFolderRecordWithoutBaselineNeverInfersRemoteDeletion() throws {
        let accountID = UUID()
        let local = ScriptFolder(
            name: "Legacy local folder",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let legacyRecord = CloudFolderSyncRecord(
            accountID: accountID,
            folderID: local.id,
            hasSynced: true
        )
        let state = folderState(accountID: accountID, record: legacyRecord)

        let plan = try CloudFolderSyncPlan.make(
            local: [local],
            remote: [],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 20),
            verifiedRemoteAbsenceIDs: [local.id]
        )

        XCTAssertEqual(plan.upload, [local])
        XCTAssertTrue(plan.deleteLocally.isEmpty)
        XCTAssertTrue(plan.tombstones.isEmpty)
        XCTAssertTrue(CloudFolderSyncPlan.remoteAbsenceCandidateIDs(
            remote: [],
            state: state
        ).isEmpty)
    }

    func testFolderSyncRestoresFolderRecreatedAfterLocalDeletion() throws {
        let accountID = UUID()
        let folderID = UUID()
        let tombstone = FolderDeletionTombstone(
            folderID: folderID,
            deletedAt: Date(timeIntervalSince1970: 20)
        )
        let recreated = ScriptFolder(
            id: folderID,
            name: "Recreated later",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let baseline = ScriptFolder(
            id: folderID,
            name: "Original folder",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [folderID: CloudFolderSyncRecord(
                accountID: accountID,
                folderID: folderID,
                hasSynced: true,
                lastSyncedName: baseline.name,
                lastSyncedCreatedAt: baseline.createdAt
            )],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [folderID: tombstone]
        )

        let plan = try CloudFolderSyncPlan.make(
            local: [],
            remote: [recreated],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 40)
        )

        XCTAssertEqual(plan.applyLocally, [recreated])
        XCTAssertEqual(plan.clearedTombstoneIDs, [folderID])
        XCTAssertTrue(plan.deleteRemotely.isEmpty)
        XCTAssertTrue(plan.allowedFolderIDs.contains(folderID))
    }

    func testFolderSyncKeepsRemoteRecreationDespiteAnOlderRemoteDeviceClock() throws {
        let accountID = UUID()
        let folderID = UUID()
        let staleLocal = ScriptFolder(
            id: folderID,
            name: "Old local generation",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let recreatedRemote = ScriptFolder(
            id: folderID,
            name: "Recreated in cloud",
            // Generation is determined by divergence from the exact baseline,
            // not by comparing wall clocks from two devices.
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let state = CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [folderID: CloudFolderSyncRecord(
                accountID: accountID,
                folderID: folderID,
                hasSynced: true,
                lastSyncedName: staleLocal.name,
                lastSyncedCreatedAt: staleLocal.createdAt
            )],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )

        let plan = try CloudFolderSyncPlan.make(
            local: [staleLocal],
            remote: [recreatedRemote],
            state: state,
            detectedAt: Date(timeIntervalSince1970: 40)
        )

        XCTAssertEqual(plan.applyLocally, [recreatedRemote])
        XCTAssertTrue(plan.upload.isEmpty)
        XCTAssertTrue(plan.allowedFolderIDs.contains(folderID))
    }

    private func scriptState(
        accountID: UUID,
        record: CloudScriptSyncRecord
    ) -> CloudLocalSyncState {
        CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [record.scriptID: record],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [:],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
    }

    private func folderState(
        accountID: UUID,
        record: CloudFolderSyncRecord
    ) -> CloudLocalSyncState {
        CloudLocalSyncState(
            accountID: accountID,
            currentAccountRecords: [:],
            scriptIDsOwnedByOtherAccounts: [],
            currentAccountFolderRecords: [record.folderID: record],
            folderIDsOwnedByOtherAccounts: [],
            tombstonesByScriptID: [:],
            tombstonesByFolderID: [:]
        )
    }

    func testCloudSyncApplicationRejectsAStaleFullLibrarySnapshot() throws {
        let base = LibrarySnapshot(
            scripts: [ScriptDocument(title: "Before sync")],
            folders: [],
            settings: .init(),
            seeded: true
        )
        var editedDuringSync = base
        editedDuringSync.scripts[0].title = "Edited during sync"

        XCTAssertNoThrow(
            try CloudSyncApplicationPolicy.validate(base: base, current: base)
        )
        XCTAssertThrowsError(
            try CloudSyncApplicationPolicy.validate(
                base: base,
                current: editedDuringSync
            )
        ) { error in
            XCTAssertTrue(error is CloudSyncApplicationError)
        }
    }

    func testAppleNonceIsRandomAndHashedForTheRequest() throws {
        let nonce = try AppleSignInSupport.makeNonce()
        XCTAssertEqual(nonce.count, 32)
        XCTAssertEqual(
            AppleSignInSupport.hashedNonce("hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testAppleSignInNonceLifecycleAndPresentationPolicy() throws {
        let attempt = try AppleSignInSupport.beginAttempt()
        XCTAssertEqual(attempt.rawNonce.count, 32)
        XCTAssertEqual(attempt.hashedNonce, AppleSignInSupport.hashedNonce(attempt.rawNonce))
        XCTAssertNotEqual(attempt.rawNonce, attempt.hashedNonce)

        let second = try AppleSignInSupport.beginAttempt()
        XCTAssertNotEqual(attempt.rawNonce, second.rawNonce)

        // Presentation: Apple primary, email secondary — no "absent" copy.
        XCTAssertEqual(AppleSignInPresentation.primarySectionHeader, "Sign in with Apple")
        XCTAssertEqual(AppleSignInPresentation.secondarySectionHeader, "Email and password")
        XCTAssertTrue(AppleSignInPresentation.signedOutFooter.contains("primary"))
        XCTAssertTrue(AppleSignInPresentation.signedOutFooter.contains("optional"))
        XCTAssertFalse(AppleSignInPresentation.signedOutFooter.contains("not offered"))
        XCTAssertTrue(
            AppleSignInPresentation.providerNotEnabledMessage.contains("not enabled")
        )
        XCTAssertTrue(
            AppleSignInPresentation.capabilityMissingMessage.contains("capability")
        )
    }

    func testAppleSignInErrorMappingQuietOnCancelAndHonestOnFailures() {
        let canceled = ASAuthorizationError(.canceled)
        XCTAssertNil(AppleSignInSupport.userFacingFailureMessage(for: canceled))

        let failed = ASAuthorizationError(.failed)
        let failedMessage = AppleSignInSupport.userFacingFailureMessage(for: failed)
        XCTAssertNotNil(failedMessage)
        XCTAssertTrue(failedMessage?.contains("Apple sign-in") == true)
        XCTAssertFalse(failedMessage?.lowercased().contains("fatal") == true)

        let missingToken = AppleSignInSupport.CredentialError.missingIdentityToken
        XCTAssertTrue(
            AppleSignInSupport.userFacingFailureMessage(for: missingToken)?
                .contains("identity token") == true
        )

        let providerDisabled = NSError(
            domain: "supabase.auth",
            code: 400,
            userInfo: [
                NSLocalizedDescriptionKey: "Unsupported provider: provider is not enabled"
            ]
        )
        XCTAssertEqual(
            AppleSignInSupport.userFacingFailureMessage(for: providerDisabled),
            AppleSignInPresentation.providerNotEnabledMessage
        )
    }
}

private enum AccountDeletionTestEvent: Equatable, Sendable {
    case rpc(String)
    case clearLocalSession
}

private enum AppleLinkedDeletionTestEvent: Equatable, Sendable {
    case invoke
    case clearLocalSession
}

private actor FakeAppleLinkedAccountDeletionRemote: AppleLinkedAccountDeletionRemote {
    private let error: Error?
    private let sessionCleanup: AccountDeletionSessionCleanup
    private var events: [AppleLinkedDeletionTestEvent] = []
    private var expectedUserIDs: [UUID] = []
    private var clientIDs: [String] = []
    private(set) var invokeCount = 0

    init(
        error: Error? = nil,
        sessionCleared: Bool = true
    ) {
        self.error = error
        sessionCleanup = sessionCleared ? .cleared : .unconfirmed
    }

    func invokeAppleLinkedDeletion(
        expectedUserID: UUID,
        reauthorization: AppleSignInSupport.DeletionReauthorization
    ) async throws {
        invokeCount += 1
        events.append(.invoke)
        expectedUserIDs.append(expectedUserID)
        clientIDs.append(reauthorization.clientId)
        if let error { throw error }
    }

    func clearLocalSession(expectedUserID: UUID) async -> AccountDeletionSessionCleanup {
        events.append(.clearLocalSession)
        _ = expectedUserID
        return sessionCleanup
    }

    func recordedEvents() -> [AppleLinkedDeletionTestEvent] { events }
    func recordedExpectedUserIDs() -> [UUID] { expectedUserIDs }
    func recordedClientIDs() -> [String] { clientIDs }
}

private actor FakeAccountDeletionRemote: AccountDeletionRemote {
    private let preflightError: AccountLifecycleBackendError?
    private let finalError: AccountLifecycleBackendError?
    private let finalTransportShouldFail: Bool
    private let sessionCleanup: AccountDeletionSessionCleanup
    private var events: [AccountDeletionTestEvent] = []
    private var expectedUserIDs: [UUID] = []
    private var cleanupExpectedUserIDs: [UUID] = []

    init(
        preflightError: AccountLifecycleBackendError? = AccountLifecycleBackendError(
            code: "22023",
            message: "Account deletion was not confirmed."
        ),
        finalError: AccountLifecycleBackendError? = nil,
        finalTransportShouldFail: Bool = false,
        sessionCleared: Bool = true,
        differentAccountPreserved: Bool = false
    ) {
        self.preflightError = preflightError
        self.finalError = finalError
        self.finalTransportShouldFail = finalTransportShouldFail
        if differentAccountPreserved {
            sessionCleanup = .differentAccountPreserved
        } else {
            sessionCleanup = sessionCleared ? .cleared : .unconfirmed
        }
    }

    func invokeDeletionRPC(confirmation: String, expectedUserID: UUID) async throws {
        events.append(.rpc(confirmation))
        expectedUserIDs.append(expectedUserID)
        if confirmation == "CHECK", let preflightError { throw preflightError }
        if confirmation == "DELETE", let finalError { throw finalError }
        if confirmation == "DELETE", finalTransportShouldFail {
            throw AccountLifecycleTransportError(message: "response lost")
        }
    }

    func clearLocalSession(expectedUserID: UUID) async -> AccountDeletionSessionCleanup {
        events.append(.clearLocalSession)
        cleanupExpectedUserIDs.append(expectedUserID)
        return sessionCleanup
    }

    func recordedEvents() -> [AccountDeletionTestEvent] { events }
    func recordedExpectedUserIDs() -> [UUID] { expectedUserIDs }
    func recordedCleanupExpectedUserIDs() -> [UUID] { cleanupExpectedUserIDs }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor FakeSessionIdentity {
    private var userID: UUID?

    init(userID: UUID?) {
        self.userID = userID
    }

    func currentUserID() -> UUID? { userID }
    func replace(with userID: UUID?) { self.userID = userID }
}
