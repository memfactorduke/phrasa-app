import AuthenticationServices
import Foundation
import Observation
import Supabase
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif
#if canImport(PhrasaSync)
import PhrasaSync
#endif
#if canImport(PhrasaSyncSupabase)
import PhrasaSyncSupabase
#endif

enum CloudAvailability: Equatable, Sendable {
    case ready
    case offlineOnly
    case unavailable(String)
}

enum CloudSyncIdentityPolicy {
    static func shouldResetSyncStatus(
        from currentState: CloudAuthState,
        to nextState: CloudAuthState
    ) -> Bool {
        switch nextState {
        case .signedOut:
            return true
        case .signedIn(let nextUser), .passwordRecovery(let nextUser):
            switch currentState {
            case .signedIn(let currentUser), .passwordRecovery(let currentUser):
                return currentUser.id != nextUser.id
            case .signedOut:
                return true
            case .loading:
                return false
            }
        case .loading:
            return false
        }
    }

    static func resolvedSyncStatus(
        currentAuthState: CloudAuthState,
        nextAuthState: CloudAuthState,
        currentSyncStatus: CloudSyncStatus
    ) -> CloudSyncStatus {
        shouldResetSyncStatus(from: currentAuthState, to: nextAuthState)
            ? .idle
            : currentSyncStatus
    }
}

/// Keeps one validated deep link ready while a mutually exclusive cloud action
/// finishes. Callback URLs are intentionally memory-only because they contain
/// one-time authentication codes.
struct PendingAuthCallbackQueue {
    private(set) var pendingURL: URL?
    private(set) var activeURL: URL?
    private var attemptedURLs: Set<URL> = []

    var hasWork: Bool { pendingURL != nil || activeURL != nil }

    /// The newest distinct callback is the user's current intent. Repeated
    /// delivery of a pending, active, or already-attempted one-time link is a
    /// no-op, so the same code is never exchanged twice in one app session.
    @discardableResult
    mutating func enqueue(_ url: URL) -> Bool {
        guard url != pendingURL, url != activeURL, !attemptedURLs.contains(url) else {
            return false
        }
        pendingURL = url
        return true
    }

    mutating func beginNext() -> URL? {
        guard activeURL == nil, let pendingURL else { return nil }
        self.pendingURL = nil
        activeURL = pendingURL
        attemptedURLs.insert(pendingURL)
        return pendingURL
    }

    mutating func finish(_ url: URL) {
        if activeURL == url { activeURL = nil }
    }
}

/// Owns cloud configuration, account state, and explicit library sync without
/// becoming a requirement for local editing. If configuration or networking is
/// unavailable, the coordinator reports that state and never changes local data.
@MainActor
@Observable
final class CloudCoordinator {
    private(set) var availability: CloudAvailability
    private(set) var authState: CloudAuthState
    private(set) var syncStatus: CloudSyncStatus = .idle
    private(set) var accountMessage: String?
    private(set) var isAuthenticating = false
    private(set) var isDeletingAccount = false

    @ObservationIgnored private let auth: SupabaseAuthService?
    @ObservationIgnored private let repository: (any CloudLibraryRepository)?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var authCallbackQueue = PendingAuthCallbackQueue()
    @ObservationIgnored private var isDrainingAuthCallback = false
    @ObservationIgnored private var synchronizationLane = CloudSynchronizationLane()

    static func live(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CloudCoordinator {
        live(infoDictionary: bundle.infoDictionary ?? [:], environment: environment)
    }

    /// Same construction rules as app launch. Prefer this overload in tests so
    /// absent or partial Info.plist keys can be asserted without a custom Bundle.
    /// `SupabaseClientFactory.make` runs only after `CloudConfiguration.load`
    /// returns a fully validated configuration.
    static func live(
        infoDictionary: [String: Any],
        environment: [String: String]
    ) -> CloudCoordinator {
        do {
            guard let configuration = try CloudConfiguration.load(
                infoDictionary: infoDictionary,
                environment: environment
            ) else {
                // Intentionally no SupabaseClient, auth service, or repository.
                return CloudCoordinator(availability: .offlineOnly, auth: nil, repository: nil)
            }
            // Platform-scoped keychain so iOS and Mac sessions never share storage.
            #if os(macOS)
            let keychainService = "com.phrasa.mac.supabase.auth"
            #else
            let keychainService = "com.phrasa.app.supabase.auth"
            #endif
            let client = SupabaseClientFactory.make(
                configuration: configuration,
                keychainService: keychainService
            )
            return CloudCoordinator(
                availability: .ready,
                auth: SupabaseAuthService(
                    client: client,
                    signInRedirectURL: configuration.redirectURL,
                    passwordRecoveryRedirectURL: configuration.passwordRecoveryRedirectURL
                ),
                repository: SupabaseCloudRepository(client: client)
            )
        } catch {
            return CloudCoordinator(
                availability: .unavailable(error.localizedDescription),
                auth: nil,
                repository: nil
            )
        }
    }

    init(
        availability: CloudAvailability,
        auth: SupabaseAuthService?,
        repository: (any CloudLibraryRepository)?
    ) {
        self.availability = availability
        self.auth = auth
        self.repository = repository
        authState = auth == nil ? .signedOut : .loading
    }

    /// Unit-test factory: seeds auth presentation without constructing a
    /// Supabase client. Production code must use `live(...)`.
    static func testing(
        availability: CloudAvailability = .ready,
        authState: CloudAuthState,
        repository: (any CloudLibraryRepository)?
    ) -> CloudCoordinator {
        let coordinator = CloudCoordinator(
            availability: availability,
            auth: nil,
            repository: repository
        )
        coordinator.applyAuthState(authState)
        return coordinator
    }

    /// Unit-test seam for identity transitions without a live auth service.
    func seedAuthStateForTesting(_ state: CloudAuthState) {
        applyAuthState(state)
    }

    var signedInUser: CloudUser? {
        switch authState {
        case .signedIn(let user), .passwordRecovery(let user): user
        case .loading, .signedOut: nil
        }
    }

    var canSync: Bool {
        signedInUser != nil
            && repository != nil
            && syncStatus != .syncing
            && !isAuthenticating
            && !isDeletingAccount
            && !authCallbackQueue.hasWork
            && !isDrainingAuthCallback
            && synchronizationLane.activeToken == nil
    }

    var isSynchronizing: Bool { syncStatus == .syncing }

    /// Reserve preparation, network work, and local application as one lane so
    /// two taps cannot race full-library snapshots out of order.
    func beginSynchronization() -> CloudSynchronizationToken? {
        guard canSync, let accountID = signedInUser?.id else { return nil }
        let token = synchronizationLane.begin(accountID: accountID)
        syncStatus = .syncing
        return token
    }

    func start() {
        guard observationTask == nil, let auth else { return }
        observationTask = Task { [weak self, auth] in
            for await state in auth.stateChanges {
                guard !Task.isCancelled else { return }
                self?.applyObservedAuthState(state)
            }
        }
    }

    func signIn(email: String, password: String) async {
        await performAuth(successMessage: nil) {
            _ = try await auth?.signIn(email: email, password: password)
        }
    }

    func signUp(email: String, password: String) async {
        await performAuth(successMessage: nil) {
            guard let result = try await auth?.signUp(email: email, password: password) else { return }
            if case .confirmationRequired(let address) = result {
                accountMessage = "Check \(address) to confirm your account, then return to Phrasa."
            }
        }
    }

    func sendPasswordReset(email: String) async {
        await performAuth(successMessage: "Password reset instructions are on their way.") {
            try await auth?.sendPasswordReset(email: email)
        }
    }

    @discardableResult
    func completePasswordRecovery(password: String) async -> Bool {
        guard case .passwordRecovery(let user) = authState else {
            accountMessage = "Request a new password-reset link before changing your password."
            return false
        }
        guard password.count >= 8 else {
            accountMessage = "Use at least 8 characters for your new password."
            return false
        }

        let succeeded = await performAuth(successMessage: "Your password has been updated.") {
            try await auth?.updateRecoveredPassword(password)
        }
        if succeeded { applyAuthState(.signedIn(user)) }
        return succeeded
    }

    func signOut() async {
        let succeeded = await performAuth(successMessage: nil) { try await auth?.signOut() }
        if succeeded { syncStatus = .idle }
    }

    /// Email/password and other non-Apple accounts. Apple-linked accounts must
    /// use `deleteAppleLinkedAccount` after a fresh SIWA reauthorization.
    @discardableResult
    func deleteAccount(expectedUserID: UUID) async -> Bool {
        guard let prep = prepareAccountDeletion(expectedUserID: expectedUserID) else {
            return false
        }
        if AccountDeletionPolicy.requiresAppleReauthorization(for: prep.user) {
            accountMessage = AccountDeletionError.appleReauthorizationRequired.errorDescription
            return false
        }

        return await performAccountDeletion(expectedUserID: expectedUserID) {
            try await prep.auth.deleteOwnAccount(expectedUserID: expectedUserID)
        }
    }

    /// Apple-linked path: one-time authorization code from SIWA reauth is sent to
    /// the server-side revoke-then-delete function. Fail-closed when revoke is incomplete.
    @discardableResult
    func deleteAppleLinkedAccount(
        expectedUserID: UUID,
        reauthorization: AppleSignInSupport.DeletionReauthorization
    ) async -> Bool {
        guard let prep = prepareAccountDeletion(expectedUserID: expectedUserID) else {
            return false
        }
        guard AccountDeletionPolicy.requiresAppleReauthorization(for: prep.user) else {
            // Defense in depth: non-Apple accounts never take the Apple code path.
            return await performAccountDeletion(expectedUserID: expectedUserID) {
                try await prep.auth.deleteOwnAccount(expectedUserID: expectedUserID)
            }
        }

        do {
            try AppleSignInSupport.validateDeletionReauthorization(reauthorization)
        } catch {
            accountMessage = Self.friendlyCloudMessage(for: error)
            return false
        }

        return await performAccountDeletion(expectedUserID: expectedUserID) {
            try await prep.auth.deleteAppleLinkedAccount(
                expectedUserID: expectedUserID,
                reauthorization: reauthorization
            )
        }
    }

    private struct AccountDeletionPrep {
        let auth: SupabaseAuthService
        let user: CloudUser
    }

    private func prepareAccountDeletion(expectedUserID: UUID) -> AccountDeletionPrep? {
        guard syncStatus != .syncing else {
            accountMessage = "Sync is still finishing. Please wait before deleting this account."
            return nil
        }
        guard !isDeletingAccount && !isAuthenticating else {
            accountMessage = "Another account action is already in progress. Please wait for it to finish."
            return nil
        }
        guard !authCallbackQueue.hasWork && !isDrainingAuthCallback else {
            accountMessage = "A sign-in link is still finishing. Please wait before deleting this account."
            schedulePendingAuthCallbackDrain()
            return nil
        }
        guard let auth, let user = signedInUser, user.id == expectedUserID else {
            accountMessage = "The signed-in account changed before deletion was confirmed. Nothing was deleted; review the account and try again."
            return nil
        }
        return AccountDeletionPrep(auth: auth, user: user)
    }

    private func performAccountDeletion(
        expectedUserID: UUID,
        operation: () async throws -> AccountDeletionResult
    ) async -> Bool {
        isDeletingAccount = true
        isAuthenticating = true
        accountMessage = nil
        defer {
            isDeletingAccount = false
            isAuthenticating = false
            schedulePendingAuthCallbackDrain()
        }

        do {
            let result = try await operation()
            let currentUserID = auth?.currentUserID
            syncStatus = .idle
            if AccountDeletionAuthStatePolicy.replacementAccountIsActive(
                expectedUserID: expectedUserID,
                currentUserID: currentUserID
            ) {
                accountMessage = "The original cloud account and its cloud data were deleted. A different account became active while deletion was finishing, so Phrasa left that account signed in and unchanged. Content on this device was left unchanged."
            } else if AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: result,
                expectedUserID: expectedUserID,
                currentUserID: currentUserID
            ) {
                applyAuthState(.signedOut)
                accountMessage = "Your cloud account and its cloud data were deleted. Everything already stored on this device was left unchanged."
            } else {
                accountMessage = "Your cloud account and its cloud data were deleted, but Phrasa could not confirm that this device cleared its old sign-in. Everything already stored on this device was left unchanged. Close and reopen Phrasa before signing in again."
            }
            return true
        } catch {
            let currentUserID = auth?.currentUserID
            let replacementAccountIsActive = AccountDeletionAuthStatePolicy
                .replacementAccountIsActive(
                    expectedUserID: expectedUserID,
                    currentUserID: currentUserID
                )
            if AccountDeletionAuthStatePolicy.shouldMarkSignedOut(
                after: error,
                expectedUserID: expectedUserID,
                currentUserID: currentUserID
            ) {
                applyAuthState(.signedOut)
            }
            accountMessage = replacementAccountIsActive
                ? "Phrasa could not confirm whether the original account's final deletion finished. A different account is now active and was left signed in and unchanged. Review both accounts before retrying."
                : Self.friendlyCloudMessage(for: error)
            return false
        }
    }

    func signInWithApple(idToken: String, nonce: String) async {
        await performAuth(successMessage: nil) {
            _ = try await auth?.signInWithApple(idToken: idToken, nonce: nonce)
        }
    }

    func reportAuthenticationFailure(_ error: Error) {
        accountMessage = Self.friendlyCloudMessage(for: error)
    }

    func handleOpenURL(_ url: URL) async {
        guard let auth else {
            accountMessage = "Cloud accounts are not available in this build. Phrasa still works offline."
            return
        }
        do {
            _ = try auth.validateCallbackURL(url)
        } catch {
            accountMessage = error.localizedDescription
            return
        }

        let wasQueued = authCallbackQueue.enqueue(url)
        if syncStatus == .syncing || isAuthenticating || isDeletingAccount || isDrainingAuthCallback {
            if wasQueued || authCallbackQueue.pendingURL == url {
                accountMessage = "Your sign-in link is ready and will finish after the current cloud action."
            }
            return
        }
        guard wasQueued else { return }
        await drainPendingAuthCallbackIfPossible()
    }

    /// Fetches both copies and resolves one-sided edits against durable content
    /// baselines. Divergent script edits are preserved as deterministic local
    /// conflict copies; divergent folder renames stop with named recovery steps.
    /// Cloud writes carry the exact fetched version as an optimistic concurrency
    /// check. The returned merged snapshot is applied atomically by the local
    /// store; this method never mutates that store itself.
    ///
    /// `preflight` is required and runs inside the engine immediately before the
    /// first repository call so a post-prepare `stageEditorDraft` fails closed
    /// with zero remote I/O. There is no default-clean shortcut. Callers must
    /// not hold a durable store lock across this method.
    func synchronize(
        _ token: CloudSynchronizationToken,
        local input: CloudSyncInput,
        preferences: CloudPreferenceResolution = .localOnly,
        preflight: @escaping CloudSyncPreflightValidator
    ) async -> CloudSyncResult? {
        guard synchronizationLane.isActive(token),
              signedInUser?.id == token.accountID,
              let repository
        else {
            finishSynchronization(
                .failed("Sign in before syncing. Your offline library is still available."),
                for: token
            )
            return nil
        }
        let accountID = token.accountID
        guard input.state.accountID == accountID else {
            finishSynchronization(
                .failed(
                    "The signed-in account changed before sync began. Nothing was uploaded; reopen Account & sync and try again."
                ),
                for: token
            )
            return nil
        }

        guard syncStatus == .syncing else {
            finishSynchronization(
                .failed("Sync could not start safely. Wait a moment and try again."),
                for: token
            )
            return nil
        }
        do {
            // Shared engine owns planning, remote I/O order, and merge assembly.
            // This coordinator only enforces UI/auth liveness around that work.
            return try await LibrarySyncEngine.synchronize(
                accountID: accountID,
                input: input,
                preferences: preferences,
                repository: repository,
                preflight: preflight,
                ensureAccount: { [weak self] in
                    guard let self else { throw CloudRepositoryError.accountChanged }
                    try await MainActor.run {
                        try self.ensureSignedInAccount(accountID)
                    }
                }
            )
        } catch let eligibility as CloudSyncEligibilityError {
            switch eligibility {
            case .deferred(let reason):
                reportLocalSyncDeferred(reason, for: token)
            }
            return nil
        } catch {
            finishSynchronization(
                .failed(Self.friendlyCloudMessage(for: error)),
                for: token
            )
            return nil
        }
    }

    func reportLocalMergeFailure(
        _ error: Error,
        for token: CloudSynchronizationToken
    ) {
        if let applicationError = error as? CloudSyncApplicationError {
            finishSynchronization(
                .failed(
                    applicationError.errorDescription
                        ?? "Your offline library changed during sync and was left unchanged."
                ),
                for: token
            )
        } else {
            finishSynchronization(
                .failed(
                    "Cloud data arrived, but Phrasa could not save it on this device. Your existing offline library was left unchanged."
                ),
                for: token
            )
        }
    }

    func reportLocalSyncApplied(
        _ summary: CloudSyncSummary,
        for token: CloudSynchronizationToken
    ) {
        finishSynchronization(.succeeded(summary), for: token)
    }

    func reportLocalSyncPreparationFailure(
        _ error: Error,
        for token: CloudSynchronizationToken
    ) {
        if let eligibilityError = error as? CloudSyncEligibilityError,
           case .deferred(let reason) = eligibilityError {
            reportLocalSyncDeferred(reason, for: token)
            return
        }
        finishSynchronization(
            .failed(
                "Phrasa could not save the account-safety record needed for sync, so nothing was uploaded. Your offline library is unchanged."
            ),
            for: token
        )
    }

    /// Explicit not-eligible outcome (dirty editor). Releases the lane without
    /// treating the request as a transport or persistence failure.
    func reportLocalSyncDeferred(
        _ reason: CloudSyncDeferredReason,
        for token: CloudSynchronizationToken
    ) {
        finishSynchronization(.deferred(reason), for: token)
    }

    func clearAccountMessage() { accountMessage = nil }

    private func ensureSignedInAccount(_ expectedAccountID: UUID) throws {
        guard signedInUser?.id == expectedAccountID else {
            throw CloudRepositoryError.accountChanged
        }
    }

    private func applyObservedAuthState(_ state: CloudAuthState) {
        // supabase-swift 2.51.0 emits `.signedIn` for a PKCE code exchange,
        // including recovery links. Once the explicitly classified recovery
        // callback wins, do not let that generic event hide the password form.
        if case .passwordRecovery(let recoveringUser) = authState,
           case .signedIn(let observedUser) = state,
           recoveringUser.id == observedUser.id {
            return
        }
        applyAuthState(state)
    }

    private func applyAuthState(_ state: CloudAuthState) {
        let shouldReset = CloudSyncIdentityPolicy.shouldResetSyncStatus(
            from: authState,
            to: state
        )
        let resolvedStatus = CloudSyncIdentityPolicy.resolvedSyncStatus(
            currentAuthState: authState,
            nextAuthState: state,
            currentSyncStatus: syncStatus
        )
        authState = state
        syncStatus = resolvedStatus
        if shouldReset {
            synchronizationLane.reset()
            schedulePendingAuthCallbackDrain()
        }
    }

    private func finishSynchronization(
        _ status: CloudSyncStatus,
        for token: CloudSynchronizationToken
    ) {
        guard let resolvedStatus = synchronizationLane.resolvedCompletionStatus(
            status,
            for: token,
            currentAccountID: signedInUser?.id
        ) else { return }
        syncStatus = resolvedStatus
        schedulePendingAuthCallbackDrain()
    }

    private func schedulePendingAuthCallbackDrain() {
        guard authCallbackQueue.hasWork else { return }
        Task { @MainActor [weak self] in
            await self?.drainPendingAuthCallbackIfPossible()
        }
    }

    private func drainPendingAuthCallbackIfPossible() async {
        guard !isDrainingAuthCallback,
              syncStatus != .syncing,
              !isAuthenticating,
              !isDeletingAccount,
              let auth,
              let url = authCallbackQueue.beginNext()
        else { return }

        isDrainingAuthCallback = true
        defer {
            authCallbackQueue.finish(url)
            isDrainingAuthCallback = false
            schedulePendingAuthCallbackDrain()
        }

        var callbackState: CloudAuthState?
        let succeeded = await performAuth(
            successMessage: nil,
            allowsQueuedAuthCallback: true
        ) {
            callbackState = try await auth.handleOpenURL(url)
        }
        if succeeded, let callbackState { applyAuthState(callbackState) }
    }

    @discardableResult
    private func performAuth(
        successMessage: String?,
        allowsQueuedAuthCallback: Bool = false,
        _ operation: () async throws -> Void
    ) async -> Bool {
        guard syncStatus != .syncing else {
            accountMessage = "Sync is still finishing. Please wait before changing accounts."
            return false
        }
        guard !isDeletingAccount else {
            accountMessage = "Account deletion is already in progress. Please wait for it to finish."
            return false
        }
        guard !isAuthenticating else {
            accountMessage = "Another account action is already in progress. Please wait for it to finish."
            return false
        }
        guard allowsQueuedAuthCallback || !authCallbackQueue.hasWork else {
            accountMessage = "A sign-in link is still finishing. Please wait before starting another account action."
            schedulePendingAuthCallbackDrain()
            return false
        }
        guard auth != nil else {
            accountMessage = "Cloud accounts are not available in this build. Phrasa still works offline."
            return false
        }
        isAuthenticating = true
        accountMessage = nil
        defer {
            isAuthenticating = false
            schedulePendingAuthCallbackDrain()
        }
        do {
            try await operation()
            if accountMessage == nil { accountMessage = successMessage }
            return true
        } catch {
            accountMessage = Self.friendlyCloudMessage(for: error)
            return false
        }
    }

    private static func friendlyCloudMessage(for error: Error) -> String {
        if let authError = error as? SupabaseAuthServiceError {
            return authError.errorDescription ?? "Phrasa could not finish that sign-in link."
        }
        if let deletionError = error as? AccountDeletionError {
            return deletionError.errorDescription ?? "Phrasa could not delete your account."
        }
        if let repositoryError = error as? CloudRepositoryError {
            return repositoryError.errorDescription ?? "Phrasa could not safely finish syncing."
        }
        // Sign in with Apple: cancellation is filtered by the account UI before
        // reportAuthenticationFailure; map real failures accessibly here.
        if error is ASAuthorizationError
            || error is AppleSignInSupport.CredentialError
            || error is AppleSignInSupport.NonceError
            || (error as NSError).domain == "Phrasa.AppleSignIn" {
            return AppleSignInSupport.userFacingFailureMessage(for: error)
                ?? "Apple sign-in did not finish. You can try again or use email and password."
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.code == NSURLErrorTimedOut {
            return "Cloud service is temporarily unreachable. Your library is safe on this device; try again later."
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("network") || message.contains("connect") || message.contains("timeout") {
            return "Cloud service is temporarily unreachable. Your library is safe on this device; try again later."
        }
        if message.contains("invalid login") || message.contains("invalid credentials") {
            return "That email and password did not match. Please check them and try again."
        }
        if message.contains("provider is not enabled")
            || message.contains("unsupported provider")
            || (message.contains("apple") && message.contains("provider")) {
            return AppleSignInPresentation.providerNotEnabledMessage
        }
        if message.contains("password") {
            return "That password was not accepted. Use at least 8 characters and choose a different password if needed."
        }
        return "Phrasa could not reach your cloud account. Your offline library is unchanged; please try again."
    }
}
