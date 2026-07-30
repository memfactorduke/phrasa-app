import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// Shared Sign in with Apple helpers for iOS and Mac.
///
/// Nonce lifecycle: generate a raw nonce per attempt, put the SHA-256 hash on
/// `ASAuthorizationAppleIDRequest.nonce`, and pass the raw nonce to Supabase
/// `signInWithIdToken`. Never send the hashed value as the Supabase nonce.
enum AppleSignInSupport {
    enum NonceError: LocalizedError {
        case generationFailed

        var errorDescription: String? {
            "Phrasa could not start Apple sign-in. Please try again."
        }
    }

    enum CredentialError: LocalizedError, Equatable {
        case missingCredential
        case missingIdentityToken
        case missingAuthorizationCode
        case missingClientId

        var errorDescription: String? {
            switch self {
            case .missingCredential:
                "Phrasa could not read the Apple sign-in response. Please try again."
            case .missingIdentityToken:
                "Apple did not return an identity token. Please try again, or use email and password."
            case .missingAuthorizationCode:
                "Apple did not return a one-time authorization code. Account deletion was not started. Please try again."
            case .missingClientId:
                "Phrasa could not determine this app’s Sign in with Apple client id. Account deletion was not started."
            }
        }
    }

    /// Production SIWA client ids (App IDs / bundle ids). Documented for tests;
    /// the live server allowlist is configured separately as secrets.
    enum SignInClientID {
        static let iOS = "com.phrasa.app"
        static let mac = "com.phrasa.mac"
    }

    /// Fresh SIWA authorization code + platform client id for Apple-linked deletion.
    ///
    /// The server allowlists `clientId`, exchanges this one-time code with Apple
    /// over HTTPS using that same client id, derives identity from the
    /// **id_token Apple returns on that exchange**, validates iss/aud/exp/sub
    /// against the stored Supabase Apple identity, revokes, then deletes.
    /// The client must **not** send an identity_token for deletion —
    /// client-supplied tokens are untrusted and are not part of the contract.
    ///
    /// iOS and Mac use different client ids (`com.phrasa.app` vs
    /// `com.phrasa.mac`). Grouped App IDs do not make client_id interchangeable
    /// on Apple’s token endpoint.
    struct DeletionReauthorization: Equatable, Sendable {
        let authorizationCode: String
        /// SIWA client id for this binary (native: `Bundle.main.bundleIdentifier`).
        let clientId: String
    }

    /// One authorization attempt: retain `rawNonce` until completion, put
    /// `hashedNonce` on the Apple request, then pass `rawNonce` to Supabase.
    struct AuthorizationAttempt: Equatable, Sendable {
        let rawNonce: String
        let hashedNonce: String
    }

    static func makeNonce(length: Int = 32) throws -> String {
        precondition(length > 0)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var random = [UInt8](repeating: 0, count: 16)
        while result.count < length {
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw NonceError.generationFailed
            }
            for byte in random where result.count < length {
                if byte < alphabet.count { result.append(alphabet[Int(byte)]) }
            }
        }
        return result
    }

    static func hashedNonce(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func beginAttempt() throws -> AuthorizationAttempt {
        let raw = try makeNonce()
        return AuthorizationAttempt(rawNonce: raw, hashedNonce: hashedNonce(raw))
    }

    /// Configure a system Apple ID request. Email and full name are requested
    /// only here; Apple may omit them on subsequent authorizations.
    static func configure(
        _ request: ASAuthorizationAppleIDRequest,
        attempt: AuthorizationAttempt
    ) {
        request.requestedScopes = [.fullName, .email]
        request.nonce = attempt.hashedNonce
    }

    /// Reauthorization for account deletion: same nonce contract, no new scopes.
    /// A fresh authorization code is required for server-side token revocation.
    static func configureDeletionReauthorization(
        _ request: ASAuthorizationAppleIDRequest,
        attempt: AuthorizationAttempt
    ) {
        request.requestedScopes = []
        request.nonce = attempt.hashedNonce
    }

    static func identityToken(from authorization: ASAuthorization) throws -> String {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw CredentialError.missingCredential
        }
        return try identityToken(from: credential)
    }

    static func identityToken(from credential: ASAuthorizationAppleIDCredential) throws -> String {
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty
        else {
            throw CredentialError.missingIdentityToken
        }
        return token
    }

    static func authorizationCode(from credential: ASAuthorizationAppleIDCredential) throws -> String {
        guard let codeData = credential.authorizationCode,
              let code = String(data: codeData, encoding: .utf8),
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CredentialError.missingAuthorizationCode
        }
        return code
    }

    static func authorizationCode(from authorization: ASAuthorization) throws -> String {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw CredentialError.missingCredential
        }
        return try authorizationCode(from: credential)
    }

    /// Current app SIWA client id for native builds (bundle identifier).
    static func currentSignInClientId(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> String {
        let id = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { throw CredentialError.missingClientId }
        return id
    }

    /// Extracts the one-time authorization code and platform client id for the
    /// server-side Apple revoke-then-delete edge function. Does not include
    /// identity_token.
    static func deletionReauthorization(
        from authorization: ASAuthorization,
        clientId: String? = nil
    ) throws -> DeletionReauthorization {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw CredentialError.missingCredential
        }
        let resolvedClientId = try clientId.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CredentialError.missingClientId }
            return trimmed
        } ?? currentSignInClientId()
        return DeletionReauthorization(
            authorizationCode: try authorizationCode(from: credential),
            clientId: resolvedClientId
        )
    }

    /// Validates client-side payload shape before any network call.
    static func validateDeletionReauthorization(
        _ material: DeletionReauthorization
    ) throws {
        let code = material.authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientId = material.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw CredentialError.missingAuthorizationCode }
        guard !clientId.isEmpty else { throw CredentialError.missingClientId }
    }

    /// User-facing failure copy. Returns `nil` for cancellation so the UI stays quiet.
    static func userFacingFailureMessage(for error: Error) -> String? {
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                return nil
            case .unknown:
                // Often surfaces when the sheet is dismissed without completing.
                return "Apple sign-in did not finish. You can try again or use email and password."
            case .failed, .invalidResponse, .notHandled, .notInteractive:
                return "Apple sign-in could not be completed. Check that Sign in with Apple is available for this install, or use email and password."
            case .matchedExcludedCredential:
                return "Apple sign-in could not be completed with the selected credential. Try again, or use email and password."
            case .credentialImport, .credentialExport:
                return "Apple sign-in could not be completed. You can try again or use email and password."
            case .preferSignInWithApple:
                return "Continue with Sign in with Apple, or use email and password."
            case .deviceNotConfiguredForPasskeyCreation:
                return "This device is not set up for that sign-in option. Use Sign in with Apple or email and password."
            @unknown default:
                return "Apple sign-in could not be completed. You can try again or use email and password."
            }
        }
        if let credentialError = error as? CredentialError {
            return credentialError.errorDescription
        }
        if let nonceError = error as? NonceError {
            return nonceError.errorDescription
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("cancel") {
            return nil
        }
        // Entitlement / provisioning / provider-not-enabled are external blockers.
        if message.contains("provider is not enabled")
            || message.contains("unsupported provider")
            || message.contains("apple provider") {
            return AppleSignInPresentation.providerNotEnabledMessage
        }
        if message.contains("entitlement")
            || message.contains("not configured for the app")
            || message.contains("com.apple.developer.applesignin") {
            return AppleSignInPresentation.capabilityMissingMessage
        }
        return error.localizedDescription
    }
}

/// Account screen presentation: Apple is primary; email/password is secondary.
enum AppleSignInPresentation {
    static let primarySectionHeader = "Sign in with Apple"
    static let secondarySectionHeader = "Email and password"
    static let signedOutFooter =
        "Sign in with Apple is the primary way to create or open a Phrasa cloud account. Email and password are a secondary fallback. An account is optional — Phrasa keeps working offline whether or not you sign in."
    static let providerNotEnabledMessage =
        "Sign in with Apple is not enabled on Phrasa’s cloud project yet. Your offline library is unchanged. Use email and password for now, or try again after the operator enables Apple as an auth provider."
    static let capabilityMissingMessage =
        "This install cannot complete Sign in with Apple until the app’s Apple Developer capability and provisioning profile include Sign in with Apple. Your offline library is unchanged. You can use email and password instead."
    static let deletionReauthorizationHeader = "Confirm with Apple"
    static let deletionReauthorizationButtonLabel = "Continue with Apple to delete"
    static let deletionReauthorizationFooter =
        "Because this account uses Sign in with Apple, Apple requires a fresh confirmation so Phrasa can revoke Apple access and then delete the cloud account. Nothing is deleted if you cancel or if confirmation fails."
    static let deletionReauthorizationAlertMessage =
        "This permanently deletes your cloud account and the cloud copies of synced scripts and folders. All content and settings already saved on this device stay unchanged. After you type DELETE, you will confirm with Apple so Phrasa can revoke Apple access and then delete the account. This cannot be undone."
}
