import Foundation

/// Public connection details for a Phrasa Supabase project.
///
/// A publishable key is designed to ship in an app. A secret/service-role key is
/// never safe in a client binary, so this type rejects one before a client can be
/// created. No secrets live in source; values come from Info.plist (Release) or
/// explicit Debug overrides. Legacy `EXPO_PUBLIC_*` env keys are never consulted.
public struct CloudConfiguration: Equatable, Sendable {
    public static let urlInfoKey = "PhrasaSupabaseURL"
    public static let publishableKeyInfoKey = "PhrasaSupabasePublishableKey"

    /// Exact production Supabase project host accepted by shipping Release builds.
    public static let productionProjectHost = "uqkjidvqyngrnyftdazp.supabase.co"
    /// Exact production project URL (https only).
    public static let productionProjectURLString =
        "https://uqkjidvqyngrnyftdazp.supabase.co"

    public let projectURL: URL
    public let publishableKey: String
    public let redirectURL: URL
    public let passwordRecoveryRedirectURL: URL

    public init(
        projectURL: URL,
        publishableKey: String,
        redirectURL: URL = URL(string: "phrasa://auth/callback")!,
        passwordRecoveryRedirectURL: URL = URL(string: "phrasa://auth/recovery")!,
        sourcePolicy: CloudConfigurationSourcePolicy = .current
    ) throws {
        guard Self.isAllowedProjectURL(projectURL, sourcePolicy: sourcePolicy) else {
            throw CloudConfigurationError.invalidProjectURL
        }

        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudConfigurationError.incompleteConfiguration }
        guard !Self.isPrivilegedKey(key) else { throw CloudConfigurationError.privilegedKey }
        guard Self.isAllowedAppRedirectURL(redirectURL),
              Self.isAllowedAppRedirectURL(passwordRecoveryRedirectURL),
              !Self.routesMatch(redirectURL, passwordRecoveryRedirectURL)
        else {
            throw CloudConfigurationError.invalidRedirectURL
        }

        self.projectURL = projectURL
        self.publishableKey = key
        self.redirectURL = redirectURL
        self.passwordRecoveryRedirectURL = passwordRecoveryRedirectURL
    }

    /// Returns `nil` when cloud support is intentionally absent so the app can
    /// remain fully usable offline. A half-filled or unsafe configuration throws.
    public static func load(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourcePolicy: CloudConfigurationSourcePolicy = .current
    ) throws -> CloudConfiguration? {
        try load(
            infoDictionary: bundle.infoDictionary ?? [:],
            environment: environment,
            sourcePolicy: sourcePolicy
        )
    }

    public static func load(
        infoDictionary: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourcePolicy: CloudConfigurationSourcePolicy = .current
    ) throws -> CloudConfiguration? {
        let rawURL: String?
        let rawKey: String?
        switch sourcePolicy {
        case .release:
            // Release ignores every environment override — only shipping
            // Info.plist placeholders / expanded values may configure cloud.
            rawURL = normalizedConfigValue(infoDictionary[urlInfoKey] as? String)
            rawKey = normalizedConfigValue(infoDictionary[publishableKeyInfoKey] as? String)
        case .debug:
            // Debug may use explicit SUPABASE_* overrides (never EXPO_PUBLIC_*).
            rawURL = firstNonempty([
                environment["SUPABASE_URL"],
                infoDictionary[urlInfoKey] as? String,
            ])
            rawKey = firstNonempty([
                environment["SUPABASE_PUBLISHABLE_KEY"],
                infoDictionary[publishableKeyInfoKey] as? String,
            ])
        }

        if rawURL == nil, rawKey == nil { return nil }
        guard let rawURL, let rawKey, let url = URL(string: rawURL) else {
            throw CloudConfigurationError.incompleteConfiguration
        }
        return try CloudConfiguration(
            projectURL: url,
            publishableKey: rawKey,
            sourcePolicy: sourcePolicy
        )
    }

    private static func firstNonempty(_ values: [String?]) -> String? {
        values.compactMap { value in
            normalizedConfigValue(value)
        }.first
    }

    /// Blank values and unresolved Xcode build-setting placeholders (`$(NAME)`)
    /// are treated as absent so shipping Info.plist templates resolve offline-only
    /// instead of constructing a half-configured client.
    private static func normalizedConfigValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isUnresolvedBuildSettingPlaceholder(trimmed) { return nil }
        return trimmed
    }

    private static func isUnresolvedBuildSettingPlaceholder(_ value: String) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")") && value.count > 3
    }

    private static func isAllowedProjectURL(
        _ url: URL,
        sourcePolicy: CloudConfigurationSourcePolicy
    ) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { return false }

        switch sourcePolicy {
        case .release:
            // Shipping Release accepts only the pinned production HTTPS host.
            return scheme == "https" && host == productionProjectHost
        case .debug:
            if scheme == "https" { return true }
            return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
        }
    }

    private static func isAllowedAppRedirectURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "phrasa"
            && url.host?.lowercased() == "auth"
            && !url.path.isEmpty
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
    }

    private static func routesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && lhs.path == rhs.path
    }

    private static func isPrivilegedKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        if lowercased.hasPrefix("sb_secret_") || lowercased.contains("service_role") {
            return true
        }

        let components = key.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let payload = decodeBase64URL(String(components[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return false }
        return (object["role"] as? String)?.lowercased() == "service_role"
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }
}

/// Controls which configuration sources and hosts are legal.
///
/// Release ignores environment overrides and pins the production host.
/// Debug allows explicit `SUPABASE_*` overrides and localhost HTTP for tests.
public enum CloudConfigurationSourcePolicy: Equatable, Sendable {
    case release
    case debug

    public static var current: Self {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }
}

public enum CloudConfigurationError: LocalizedError, Equatable {
    case incompleteConfiguration
    case invalidProjectURL
    case invalidRedirectURL
    case privilegedKey

    public var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            "Cloud sync needs both a Supabase URL and a publishable key."
        case .invalidProjectURL:
            "The cloud address is not a valid secure Supabase URL."
        case .invalidRedirectURL:
            "The sign-in return address is not configured for Phrasa."
        case .privilegedKey:
            "A private Supabase key was blocked. Phrasa may only use a publishable key."
        }
    }
}
