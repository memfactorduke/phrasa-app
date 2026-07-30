import Foundation

/// Minimal Supabase surface the shared client may assume.
///
/// Allowed:
/// - `auth.users` (via Supabase Auth only; never queried as a table)
/// - `folders`, `scripts` (outline columns live on `scripts`), `user_settings`
/// - RPC `delete_own_account`
///
/// Explicitly out of contract: `profiles`, Storage buckets (including
/// `script-uploads`), billing/subscriptions, analytics, and any other service.
public enum CloudBackendContract {
    /// PostgREST tables the shared repository may select/insert/update/delete.
    public static let allowedTables: Set<String> = [
        "folders",
        "scripts",
        "user_settings",
    ]

    /// Public RPCs the shared client may invoke.
    public static let allowedRPCs: Set<String> = [
        "delete_own_account",
    ]

    /// Identifiers that must not appear as remote resource assumptions in the
    /// shared Supabase transport (or its tests' production source surface).
    public static let forbiddenRemoteAssumptions: Set<String> = [
        "profiles",
        "script-uploads",
        "subscriptions",
        "subscription_events",
        "analytics_events",
        "billing",
        "storage.objects",
        "storage.buckets",
    ]

    /// Returns forbidden tokens found in source text (case-sensitive for SQL-ish
    /// identifiers that appear as string literals or table paths).
    public static func forbiddenMatches(in source: String) -> [String] {
        forbiddenRemoteAssumptions
            .filter { source.contains($0) }
            .sorted()
    }
}
