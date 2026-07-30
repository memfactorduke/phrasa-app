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

struct CloudUser: Equatable, Sendable {
    let id: UUID
    let email: String?
    let identityProviders: Set<String>

    init(id: UUID, email: String?, identityProviders: Set<String> = []) {
        self.id = id
        self.email = email
        self.identityProviders = Set(identityProviders.map { $0.lowercased() })
    }
}

enum CloudAuthState: Equatable, Sendable {
    case loading
    case signedOut
    case signedIn(CloudUser)
    case passwordRecovery(CloudUser)
}

enum CloudSignUpResult: Equatable, Sendable {
    case signedIn(CloudUser)
    case confirmationRequired(email: String)
}

/// Serializes every operation that can replace or clear Supabase's local
/// session. The SDK's local sign-out API has no "only sign out this user"
/// parameter, so account deletion must hold this lock from its initial identity
/// check through its final compare-and-clear cleanup.
actor AuthMutationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    #if DEBUG
    var queuedOperationCount: Int { waiters.count }
    #endif
}

struct SupabaseAuthService: Sendable {
    let client: SupabaseClient
    let signInRedirectURL: URL
    let passwordRecoveryRedirectURL: URL
    let recoveryStateStore: PasswordRecoveryStateStore
    let authMutationLock: AuthMutationLock

    init(
        client: SupabaseClient,
        signInRedirectURL: URL,
        passwordRecoveryRedirectURL: URL,
        recoveryStateStore: PasswordRecoveryStateStore = PasswordRecoveryStateStore(),
        authMutationLock: AuthMutationLock = AuthMutationLock()
    ) {
        self.client = client
        self.signInRedirectURL = signInRedirectURL
        self.passwordRecoveryRedirectURL = passwordRecoveryRedirectURL
        self.recoveryStateStore = recoveryStateStore
        self.authMutationLock = authMutationLock
    }

    var stateChanges: AsyncStream<CloudAuthState> {
        let upstream = client.auth.authStateChanges
        return AsyncStream { continuation in
            let task = Task {
                for await (event, session) in upstream {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .passwordRecovery:
                        if let session {
                            continuation.yield(.passwordRecovery(Self.user(from: session)))
                        }
                    case .initialSession, .signedIn, .signedOut, .tokenRefreshed, .userUpdated, .userDeleted:
                        if let session {
                            let user = Self.user(from: session)
                            if await recoveryStateStore.matches(userID: user.id) {
                                continuation.yield(.passwordRecovery(user))
                            } else {
                                continuation.yield(.signedIn(user))
                            }
                        } else {
                            await recoveryStateStore.clear()
                            continuation.yield(.signedOut)
                        }
                    case .mfaChallengeVerified:
                        break
                    @unknown default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func signIn(email: String, password: String) async throws -> CloudUser {
        let email = normalized(email)
        return try await authMutationLock.withLock { [client] in
            let session = try await client.auth.signIn(email: email, password: password)
            return Self.user(from: session)
        }
    }

    func signUp(email: String, password: String) async throws -> CloudSignUpResult {
        let normalizedEmail = normalized(email)
        return try await authMutationLock.withLock { [client] in
            let response = try await client.auth.signUp(
                email: normalizedEmail,
                password: password
            )
            if let session = response.session {
                return .signedIn(Self.user(from: session))
            }
            return .confirmationRequired(email: normalizedEmail)
        }
    }

    func sendPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(
            normalized(email),
            redirectTo: passwordRecoveryRedirectURL
        )
    }

    func updateRecoveredPassword(_ password: String) async throws {
        // supabase-swift 2.51.0 updates the authenticated recovery session
        // through AuthClient.update(user:). Never handle or store the password
        // anywhere outside the SDK request.
        try await authMutationLock.withLock { [client, recoveryStateStore] in
            _ = try await client.auth.update(user: UserAttributes(password: password))
            await recoveryStateStore.clear()
        }
    }

    /// Email/password (and other non-Apple) accounts: fail-closed `delete_own_account`.
    func deleteOwnAccount(expectedUserID: UUID) async throws -> AccountDeletionResult {
        try await authMutationLock.withLock { [client] in
            let userID = try await client.auth.session.user.id
            try AccountDeletionIdentityValidator.validate(
                expectedUserID: expectedUserID,
                currentUserID: userID
            )
            return try await AccountDeletionWorkflow(
                remote: SupabaseAccountDeletionRemote(client: client)
            ).deleteAccount(userID: userID)
        }
    }

    /// Apple-linked accounts: require a fresh SIWA authorization code, then call
    /// the server-side revoke-then-delete edge function (secrets stay server-only).
    func deleteAppleLinkedAccount(
        expectedUserID: UUID,
        reauthorization: AppleSignInSupport.DeletionReauthorization
    ) async throws -> AccountDeletionResult {
        try AppleSignInSupport.validateDeletionReauthorization(reauthorization)
        return try await authMutationLock.withLock { [client] in
            let userID = try await client.auth.session.user.id
            try AccountDeletionIdentityValidator.validate(
                expectedUserID: expectedUserID,
                currentUserID: userID
            )
            return try await AppleLinkedAccountDeletionWorkflow(
                remote: SupabaseAppleLinkedAccountDeletionRemote(client: client)
            ).deleteAccount(
                userID: userID,
                reauthorization: reauthorization
            )
        }
    }

    func signOut() async throws {
        try await authMutationLock.withLock { [client, recoveryStateStore] in
            try await client.auth.signOut(scope: .local)
            await recoveryStateStore.clear()
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> CloudUser {
        try await authMutationLock.withLock { [client] in
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idToken,
                    nonce: nonce
                )
            )
            return Self.user(from: session)
        }
    }

    /// Exchanges the PKCE code and explicitly classifies the callback route.
    /// supabase-swift 2.51.0 emits `.signedIn` (not `.passwordRecovery`) for
    /// PKCE exchanges, so the dedicated recovery URL is the durable signal.
    func validateCallbackURL(_ url: URL) throws -> CloudAuthCallbackKind {
        try CloudAuthCallbackKind.classify(
            url,
            signInRedirectURL: signInRedirectURL,
            passwordRecoveryRedirectURL: passwordRecoveryRedirectURL
        )
    }

    func handleOpenURL(_ url: URL) async throws -> CloudAuthState {
        try await authMutationLock.withLock {
            let kind = try validateCallbackURL(url)
            let session = try await client.auth.session(from: url)
            let user = Self.user(from: session)
            switch kind {
            case .signIn:
                if await recoveryStateStore.matches(userID: user.id) {
                    return .passwordRecovery(user)
                }
                return .signedIn(user)
            case .passwordRecovery:
                await recoveryStateStore.mark(userID: user.id)
                return .passwordRecovery(user)
            }
        }
    }

    func validUser() async throws -> CloudUser {
        Self.user(from: try await client.auth.session)
    }

    var currentUserID: UUID? { client.auth.currentSession?.user.id }

    private func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func user(from session: Session) -> CloudUser {
        var providers = Set(session.user.identities?.map(\.provider) ?? [])
        if let primaryProvider = session.user.appMetadata["provider"]?.stringValue {
            providers.insert(primaryProvider)
        }
        for provider in session.user.appMetadata["providers"]?.arrayValue ?? [] {
            if let name = provider.stringValue { providers.insert(name) }
        }
        return CloudUser(
            id: session.user.id,
            email: session.user.email,
            identityProviders: providers
        )
    }
}

actor PasswordRecoveryStateStore {
    private static let userIDKey = "phrasa.supabase.password-recovery-user-id"
    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
            self.defaults = defaults
        } else {
            defaults = .standard
        }
    }

    func mark(userID: UUID) {
        defaults.set(userID.uuidString.lowercased(), forKey: Self.userIDKey)
    }

    func matches(userID: UUID) -> Bool {
        defaults.string(forKey: Self.userIDKey) == userID.uuidString.lowercased()
    }

    func clear() {
        defaults.removeObject(forKey: Self.userIDKey)
    }
}

enum CloudAuthCallbackKind: Equatable, Sendable {
    case signIn
    case passwordRecovery

    static func classify(
        _ url: URL,
        signInRedirectURL: URL,
        passwordRecoveryRedirectURL: URL
    ) throws -> Self {
        if routesMatch(url, passwordRecoveryRedirectURL) { return .passwordRecovery }
        if routesMatch(url, signInRedirectURL) { return .signIn }
        throw SupabaseAuthServiceError.invalidCallback
    }

    private static func routesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && lhs.path == rhs.path
            && lhs.user == nil
            && lhs.password == nil
    }
}

enum RecoveredPasswordValidator {
    static func message(password: String, confirmation: String) -> String? {
        if password.count < 8 { return "Use at least 8 characters." }
        if password != confirmation { return "The two passwords don't match." }
        return nil
    }
}

enum AccountDeletionIdentityValidator {
    static func validate(expectedUserID: UUID, currentUserID: UUID) throws {
        guard expectedUserID == currentUserID else {
            throw AccountDeletionError.accountChanged
        }
    }
}

enum AccountDeletionRoute: Equatable, Sendable {
    /// Non-Apple accounts: run `delete_own_account` then clear the local session.
    case automatic
    /// Apple-linked: require a fresh SIWA authorization code, then server-side
    /// Apple token revoke followed by Phrasa account deletion (fail-closed).
    case appleLinkedRequiresReauthorization
}

enum AccountDeletionPolicy {
    /// Name of the Supabase Edge Function that holds Apple private credentials.
    /// Deployed only after secrets are configured; undeployed calls fail closed.
    static let appleLinkedDeletionFunctionName = "delete-apple-linked-account"

    static let emailDeletionFooter =
        "Deleting your cloud account removes cloud copies of synced scripts and folders and leaves all content and settings already saved on this device unchanged. This cannot be undone."

    static let appleLinkedDeletionFooter =
        "This account uses Sign in with Apple. After you type DELETE, Phrasa asks you to confirm with Apple again so it can revoke Apple access and then delete the cloud account. Content already saved on this device stays unchanged. If Apple confirmation or the server step fails, nothing is deleted."

    /// Release-blocker copy for operators (not shown as the primary footer).
    static let appleRevocationServerReleaseBlocker =
        "RELEASE BLOCKER: Apple-linked account deletion requires the deployed Supabase Edge Function delete-apple-linked-account with server-only Apple credentials (Team ID, Key ID, .p8 private key) and APPLE_CLIENT_IDS allowlisting both com.phrasa.app and com.phrasa.mac. Identity is taken from Apple’s exchange id_token only—not a client identity_token. Until that function is deployed and live-tested on iOS and Mac, Apple-linked deletion fails closed and does not remove data."

    static func route(for user: CloudUser) -> AccountDeletionRoute {
        hasAppleIdentity(user) ? .appleLinkedRequiresReauthorization : .automatic
    }

    static func requiresAppleReauthorization(for user: CloudUser) -> Bool {
        route(for: user) == .appleLinkedRequiresReauthorization
    }

    static func hasAppleIdentity(_ user: CloudUser) -> Bool {
        user.identityProviders.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "apple"
        }
    }

    static func deletionFooter(for user: CloudUser) -> String {
        switch route(for: user) {
        case .appleLinkedRequiresReauthorization:
            return appleLinkedDeletionFooter
        case .automatic:
            return emailDeletionFooter
        }
    }
}

struct AccountDeletionResult: Equatable, Sendable {
    let sessionCleanup: AccountDeletionSessionCleanup

    init(
        sessionCleared: Bool,
        differentAccountPreserved: Bool = false
    ) {
        if differentAccountPreserved {
            sessionCleanup = .differentAccountPreserved
        } else {
            sessionCleanup = sessionCleared ? .cleared : .unconfirmed
        }
    }

    init(sessionCleanup: AccountDeletionSessionCleanup) {
        self.sessionCleanup = sessionCleanup
    }

    var sessionCleared: Bool { sessionCleanup == .cleared }
    var differentAccountPreserved: Bool {
        sessionCleanup == .differentAccountPreserved
    }
}

enum AccountDeletionSessionCleanup: Equatable, Sendable {
    case cleared
    case unconfirmed
    case differentAccountPreserved
}

enum AccountDeletionLocalSessionAction: Equatable, Sendable {
    case alreadyCleared
    case clearExpectedAccount
    case preserveDifferentAccount
}

enum AccountDeletionSessionGuard {
    static func action(
        expectedUserID: UUID,
        currentUserID: UUID?
    ) -> AccountDeletionLocalSessionAction {
        guard let currentUserID else { return .alreadyCleared }
        return currentUserID == expectedUserID
            ? .clearExpectedAccount
            : .preserveDifferentAccount
    }
}

enum AccountDeletionAuthStatePolicy {
    static func replacementAccountIsActive(
        expectedUserID: UUID,
        currentUserID: UUID?
    ) -> Bool {
        guard let currentUserID else { return false }
        return currentUserID != expectedUserID
    }

    static func shouldMarkSignedOut(
        after result: AccountDeletionResult,
        expectedUserID: UUID,
        currentUserID: UUID?
    ) -> Bool {
        result.sessionCleared
            && !replacementAccountIsActive(
                expectedUserID: expectedUserID,
                currentUserID: currentUserID
            )
    }

    static func shouldMarkSignedOut(
        after error: Error,
        expectedUserID: UUID,
        currentUserID: UUID?
    ) -> Bool {
        guard let deletionError = error as? AccountDeletionError,
              case .finalDeletionUnconfirmed(let sessionCleared) = deletionError else {
            return false
        }
        return sessionCleared
            && !replacementAccountIsActive(
                expectedUserID: expectedUserID,
                currentUserID: currentUserID
            )
    }
}

struct AccountLifecycleBackendError: Error, Equatable, Sendable {
    let code: String?
    let message: String
}

struct AccountLifecycleTransportError: Error, Equatable, Sendable {
    let message: String
}

enum AccountDeletionError: LocalizedError, Equatable, Sendable {
    case accountChanged
    case migrationUnavailable
    case preflightFailed
    case finalDeletionFailed
    case finalDeletionUnconfirmed(sessionCleared: Bool)
    case finalDeletionUnconfirmedForDifferentAccount
    case appleReauthorizationRequired
    case appleAuthorizationCodeMissing
    case appleRevocationNotConfigured
    case appleRevocationFailed
    case appleRevokedButAccountDeletionFailed
    case appleLinkedDeletionRejected

    var errorDescription: String? {
        switch self {
        case .accountChanged:
            return "The signed-in account changed before deletion was confirmed. Nothing was deleted; review the account and try again."
        case .migrationUnavailable:
            return "Account deletion is not enabled on this server yet. Nothing was deleted."
        case .preflightFailed:
            return "Phrasa could not safely verify account deletion. Nothing was deleted; check your connection and try again."
        case .finalDeletionFailed:
            return "Phrasa could not delete your account. Your account and cloud data are still active; check your connection and try again."
        case .finalDeletionUnconfirmed(let sessionCleared):
            if sessionCleared {
                return "Phrasa could not confirm whether the final account deletion finished. This device was signed out for safety. Sign in again to check; if the account still exists, retry deletion."
            }
            return "Phrasa could not confirm whether the final account deletion finished or whether this device cleared its old sign-in. Close and reopen Phrasa before using cloud features."
        case .finalDeletionUnconfirmedForDifferentAccount:
            return "Phrasa could not confirm whether the original account's final deletion finished. A different account became active and was left signed in. Review both accounts before retrying."
        case .appleReauthorizationRequired:
            return "Because this account uses Sign in with Apple, confirm with Apple again before Phrasa can delete it. Nothing was deleted."
        case .appleAuthorizationCodeMissing:
            return "Apple did not return a one-time confirmation code. Nothing was deleted; try again."
        case .appleRevocationNotConfigured:
            return "Cloud account deletion for Sign in with Apple is not fully set up on the server yet. Nothing was deleted. Your offline library is unchanged."
        case .appleRevocationFailed:
            return "Phrasa could not revoke Apple access for this account, so the cloud account was left unchanged. Try again, or remove Phrasa under Apple ID → Sign in with Apple in Settings if the problem continues."
        case .appleRevokedButAccountDeletionFailed:
            return "Apple access may already have been revoked, but Phrasa could not finish deleting the cloud account. Sign in again if needed and retry deletion, or contact support if the account still appears."
        case .appleLinkedDeletionRejected:
            return "Phrasa could not complete Sign in with Apple account deletion. Nothing was deleted; check your connection and try again."
        }
    }
}

/// Stable error codes returned by the `delete-apple-linked-account` edge function.
enum AppleLinkedDeletionServerCode: String, Sendable {
    case notConfigured = "APPLE_REVOCATION_NOT_CONFIGURED"
    case invalidRequest = "INVALID_REQUEST"
    case unauthorized = "UNAUTHORIZED"
    case accountChanged = "ACCOUNT_CHANGED"
    case appleExchangeFailed = "APPLE_TOKEN_EXCHANGE_FAILED"
    case appleRevokeFailed = "APPLE_TOKEN_REVOKE_FAILED"
    case identityMismatch = "APPLE_IDENTITY_MISMATCH"
    case accountDeleteFailed = "ACCOUNT_DELETE_FAILED"
    case partialRevokedDeleteFailed = "APPLE_REVOKED_ACCOUNT_DELETE_FAILED"
}

protocol AccountDeletionRemote: Sendable {
    func invokeDeletionRPC(confirmation: String, expectedUserID: UUID) async throws
    func clearLocalSession(expectedUserID: UUID) async -> AccountDeletionSessionCleanup
}

protocol AppleLinkedAccountDeletionRemote: Sendable {
    func invokeAppleLinkedDeletion(
        expectedUserID: UUID,
        reauthorization: AppleSignInSupport.DeletionReauthorization
    ) async throws
    func clearLocalSession(expectedUserID: UUID) async -> AccountDeletionSessionCleanup
}

/// Fail-closed account deletion for the minimal backend contract.
///
/// Assumes only `delete_own_account` (and cascade over folders/scripts/
/// user_settings via `auth.users`). No Storage buckets, profiles, billing, or
/// analytics. The `CHECK` call proves the RPC exists without mutating data.
struct AccountDeletionWorkflow: Sendable {
    private let remote: any AccountDeletionRemote

    init(remote: any AccountDeletionRemote) {
        self.remote = remote
    }

    func deleteAccount(userID: UUID) async throws -> AccountDeletionResult {
        try await verifyDeletionRPC(expectedUserID: userID)

        do {
            try await remote.invokeDeletionRPC(
                confirmation: "DELETE",
                expectedUserID: userID
            )
        } catch let error as AccountLifecycleBackendError {
            if Self.isAccountAlreadyDeleted(error) {
                return AccountDeletionResult(
                    sessionCleanup: await remote.clearLocalSession(expectedUserID: userID)
                )
            }
            if Self.isMigrationMissing(error) {
                throw AccountDeletionError.migrationUnavailable
            }
            throw AccountDeletionError.finalDeletionFailed
        } catch {
            let sessionCleanup = await remote.clearLocalSession(expectedUserID: userID)
            if sessionCleanup == .differentAccountPreserved {
                throw AccountDeletionError.finalDeletionUnconfirmedForDifferentAccount
            }
            throw AccountDeletionError.finalDeletionUnconfirmed(
                sessionCleared: sessionCleanup == .cleared
            )
        }

        return AccountDeletionResult(
            sessionCleanup: await remote.clearLocalSession(expectedUserID: userID)
        )
    }

    private func verifyDeletionRPC(expectedUserID: UUID) async throws {
        do {
            try await remote.invokeDeletionRPC(
                confirmation: "CHECK",
                expectedUserID: expectedUserID
            )
        } catch let error as AccountLifecycleBackendError {
            let message = error.message.lowercased()
            if error.code == "22023"
                && message.contains("account deletion was not confirmed") {
                return
            }
            if Self.isMigrationMissing(error) {
                throw AccountDeletionError.migrationUnavailable
            }
            throw AccountDeletionError.preflightFailed
        } catch {
            throw AccountDeletionError.preflightFailed
        }

        // The migration contract requires CHECK to fail. An unexpected success
        // means the server-side guard cannot be trusted, so never delete.
        throw AccountDeletionError.preflightFailed
    }

    private static func isMigrationMissing(_ error: AccountLifecycleBackendError) -> Bool {
        let message = error.message.lowercased()
        return error.code == "PGRST202"
            || error.code == "42883"
            || message.contains("could not find") && message.contains("delete_own_account")
            || message.contains("does not exist") && message.contains("delete_own_account")
    }

    private static func isAccountAlreadyDeleted(_ error: AccountLifecycleBackendError) -> Bool {
        error.code == "P0002"
            && error.message.lowercased().contains("account no longer exists")
    }
}

/// Apple-linked deletion: fail closed until the server revokes Apple tokens, then
/// deletes the Supabase account. Never claims success when revoke is incomplete.
struct AppleLinkedAccountDeletionWorkflow: Sendable {
    private let remote: any AppleLinkedAccountDeletionRemote

    init(remote: any AppleLinkedAccountDeletionRemote) {
        self.remote = remote
    }

    func deleteAccount(
        userID: UUID,
        reauthorization: AppleSignInSupport.DeletionReauthorization
    ) async throws -> AccountDeletionResult {
        try AppleSignInSupport.validateDeletionReauthorization(reauthorization)

        do {
            try await remote.invokeAppleLinkedDeletion(
                expectedUserID: userID,
                reauthorization: reauthorization
            )
        } catch let error as AccountDeletionError {
            throw error
        } catch let error as AccountLifecycleBackendError {
            throw AppleLinkedDeletionErrorMapper.map(error)
        } catch {
            // Transport / unknown edge failures: do not clear the local session
            // optimistically — the server is fail-closed and may have deleted nothing.
            throw AccountDeletionError.appleLinkedDeletionRejected
        }

        return AccountDeletionResult(
            sessionCleanup: await remote.clearLocalSession(expectedUserID: userID)
        )
    }
}

enum AppleLinkedDeletionErrorMapper {
    static func map(_ error: AccountLifecycleBackendError) -> AccountDeletionError {
        let code = (error.code ?? "").uppercased()
        let message = error.message.lowercased()

        if code == AppleLinkedDeletionServerCode.notConfigured.rawValue
            || message.contains("not configured")
            || message.contains("apple_revocation_not_configured") {
            return .appleRevocationNotConfigured
        }
        if code == AppleLinkedDeletionServerCode.accountChanged.rawValue {
            return .accountChanged
        }
        if code == AppleLinkedDeletionServerCode.appleExchangeFailed.rawValue
            || code == AppleLinkedDeletionServerCode.appleRevokeFailed.rawValue {
            return .appleRevocationFailed
        }
        if code == AppleLinkedDeletionServerCode.identityMismatch.rawValue {
            return .appleLinkedDeletionRejected
        }
        if code == AppleLinkedDeletionServerCode.partialRevokedDeleteFailed.rawValue {
            return .appleRevokedButAccountDeletionFailed
        }
        if code == AppleLinkedDeletionServerCode.accountDeleteFailed.rawValue {
            return .finalDeletionFailed
        }
        if code == AppleLinkedDeletionServerCode.invalidRequest.rawValue
            || message.contains("authorization_code")
            || message.contains("authorization code") {
            return .appleAuthorizationCodeMissing
        }
        // Missing / undeployed function surfaces as HTTP non-2xx without our codes.
        if message.contains("not found")
            || message.contains("404")
            || message.contains("function") && message.contains("deploy") {
            return .appleRevocationNotConfigured
        }
        return .appleLinkedDeletionRejected
    }

    static func mapHTTP(statusCode: Int, body: Data) -> AccountDeletionError {
        if let payload = try? JSONDecoder().decode(
            AppleLinkedDeletionErrorBody.self,
            from: body
        ) {
            return map(
                AccountLifecycleBackendError(
                    code: payload.code,
                    message: payload.message ?? payload.error ?? "edge function error"
                )
            )
        }
        if statusCode == 404 || statusCode == 501 || statusCode == 503 {
            return .appleRevocationNotConfigured
        }
        if (500...599).contains(statusCode) {
            return .appleLinkedDeletionRejected
        }
        return .appleLinkedDeletionRejected
    }
}

struct AppleLinkedDeletionErrorBody: Decodable, Equatable, Sendable {
    let code: String?
    let message: String?
    let error: String?
}

private struct SupabaseAccountDeletionRemote: AccountDeletionRemote {
    let client: SupabaseClient

    func invokeDeletionRPC(confirmation: String, expectedUserID: UUID) async throws {
        struct Parameters: Encodable {
            let confirmation: String
            let expectedUserID: UUID

            enum CodingKeys: String, CodingKey {
                case confirmation
                case expectedUserID = "expected_user_id"
            }
        }
        do {
            try await client
                .rpc(
                    "delete_own_account",
                    params: Parameters(
                        confirmation: confirmation,
                        expectedUserID: expectedUserID
                    )
                )
                .execute()
        } catch let error as PostgrestError {
            throw AccountLifecycleBackendError(code: error.code, message: error.message)
        } catch {
            throw AccountLifecycleTransportError(message: error.localizedDescription)
        }
    }

    func clearLocalSession(expectedUserID: UUID) async -> AccountDeletionSessionCleanup {
        await AccountDeletionLocalSessionClearer.clear(
            client: client,
            expectedUserID: expectedUserID
        )
    }
}

private struct SupabaseAppleLinkedAccountDeletionRemote: AppleLinkedAccountDeletionRemote {
    let client: SupabaseClient

    func invokeAppleLinkedDeletion(
        expectedUserID: UUID,
        reauthorization: AppleSignInSupport.DeletionReauthorization
    ) async throws {
        struct Parameters: Encodable {
            let confirmation: String
            let expectedUserID: UUID
            let authorizationCode: String
            let clientId: String

            enum CodingKeys: String, CodingKey {
                case confirmation
                case expectedUserID = "expected_user_id"
                case authorizationCode = "authorization_code"
                case clientId = "client_id"
            }
        }

        let parameters = Parameters(
            confirmation: "DELETE",
            expectedUserID: expectedUserID,
            authorizationCode: reauthorization.authorizationCode,
            clientId: reauthorization.clientId
        )

        do {
            try await client.functions.invoke(
                AccountDeletionPolicy.appleLinkedDeletionFunctionName,
                options: FunctionInvokeOptions(body: parameters)
            )
        } catch let error as FunctionsError {
            switch error {
            case .httpError(let code, let data):
                throw AppleLinkedDeletionErrorMapper.mapHTTP(statusCode: code, body: data)
            case .relayError:
                throw AccountDeletionError.appleLinkedDeletionRejected
            }
        } catch let error as AccountDeletionError {
            throw error
        } catch {
            throw AccountLifecycleTransportError(message: error.localizedDescription)
        }
    }

    func clearLocalSession(expectedUserID: UUID) async -> AccountDeletionSessionCleanup {
        await AccountDeletionLocalSessionClearer.clear(
            client: client,
            expectedUserID: expectedUserID
        )
    }
}

enum AccountDeletionLocalSessionClearer {
    static func clear(
        client: SupabaseClient,
        expectedUserID: UUID
    ) async -> AccountDeletionSessionCleanup {
        // `signOut(scope: .local)` removes whichever session is current. Compare
        // identities before invoking it so a replacement account is preserved.
        // The live workflow holds SupabaseAuthService's AuthMutationLock for
        // this whole compare-and-clear sequence.
        switch AccountDeletionSessionGuard.action(
            expectedUserID: expectedUserID,
            currentUserID: client.auth.currentSession?.user.id
        ) {
        case .alreadyCleared:
            return .cleared
        case .preserveDifferentAccount:
            return .differentAccountPreserved
        case .clearExpectedAccount:
            break
        }
        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            // supabase-swift removes the local session before making the logout
            // request. Confirm session state rather than treating a later network
            // error as proof that credentials remain on this device.
        }
        guard let remainingSession = client.auth.currentSession else { return .cleared }
        return remainingSession.user.id == expectedUserID
            ? .unconfirmed
            : .differentAccountPreserved
    }
}

enum SupabaseAuthServiceError: LocalizedError {
    case invalidCallback

    var errorDescription: String? {
        "Phrasa could not recognize that sign-in link. Please request a new one."
    }
}

@MainActor
@Observable
final class CloudSessionStore {
    private(set) var state: CloudAuthState = .loading
    private(set) var errorMessage: String?

    @ObservationIgnored private let auth: SupabaseAuthService
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(auth: SupabaseAuthService) {
        self.auth = auth
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, auth] in
            for await state in auth.stateChanges {
                guard !Task.isCancelled else { return }
                self?.state = state
            }
        }
    }

    func signIn(email: String, password: String) async {
        await perform { _ = try await auth.signIn(email: email, password: password) }
    }

    func signUp(email: String, password: String) async -> CloudSignUpResult? {
        var result: CloudSignUpResult?
        await perform { result = try await auth.signUp(email: email, password: password) }
        return result
    }

    func sendPasswordReset(email: String) async {
        await perform { try await auth.sendPasswordReset(email: email) }
    }

    func signOut() async {
        await perform { try await auth.signOut() }
    }

    func handleOpenURL(_ url: URL) async {
        await perform { _ = try await auth.handleOpenURL(url) }
    }

    func clearError() { errorMessage = nil }

    private func perform(_ operation: () async throws -> Void) async {
        do {
            errorMessage = nil
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
