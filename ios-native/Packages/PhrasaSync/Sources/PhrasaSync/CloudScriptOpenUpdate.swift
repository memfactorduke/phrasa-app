import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// Policy for **metadata-only** last-opened advancement after content identity
/// is already proven (`CloudScriptFingerprint` equal).
///
/// ## Production history
/// Exact `last_opened_at` equality OCC failed closed (`scriptConflict`) when the
/// server stored millisecond opens and Date/`timestamp()` round-trips drifted.
/// Dropping the open predicate entirely fixed precision but allowed a
/// cross-device race: two devices with the same content `updated_at` could both
/// pass OCC, and a **stale** open write could regress a newer open.
///
/// ## Safe conditional write
/// 1. Caller proves content match before calling.
/// 2. The write is scoped by **id + user_id** and changes only
///    `last_opened_at`. It deliberately does not predicate on `updated_at`:
///    an independent content edit must not make harmless recency metadata
///    impossible to advance.
/// 3. **Monotonic open filter** (not equality):
///    `last_opened_at IS NULL OR last_opened_at < canonicalDesired`
///    so a lagging writer cannot move the stamp backward. Uses wire-stable
///    `timestamp()` strings, not brittle equality on the open column.
/// 4. Returned row verified with `currentMatchesDesired` (wire-ms open cover).
///    If content changed concurrently, that verification still fails closed.
public enum CloudScriptOpenUpdate: Sendable {
    /// Identity/scope columns for the open UPDATE (monotonic open is separate).
    public static let scopeFilterColumns: [String] = ["id", "user_id"]

    /// `true` when remote must receive a newer wire-ms open stamp.
    public static func needsAdvancement(desired: Date?, current: Date?) -> Bool {
        guard let desired else { return false }
        guard let current else { return true }
        return !CloudTimestampPrecision.wireIsAtLeast(current, desired)
    }

    /// Canonical value written to `last_opened_at` (stable wire millisecond).
    public static func valueToWrite(desired: Date) -> Date {
        CloudTimestampPrecision.wireNormalized(desired)
    }

    /// PostgREST `or=(…)` body for a monotonic open advance against the value
    /// about to be written. Timestamps are double-quoted so `:` / `.` are not
    /// parsed as filter separators.
    ///
    /// Example: `last_opened_at.is.null,last_opened_at.lt."2026-07-20T…Z"`
    public static func monotonicOpenOrFilter(
        openToWrite: Date,
        timestamp: (Date) -> String
    ) -> String {
        let stamp = timestamp(openToWrite)
        return "last_opened_at.is.null,last_opened_at.lt.\"\(stamp)\""
    }

    /// Query items the shipping open UPDATE must emit (before SDK percent-encoding).
    public static func postgrestFilterQueryItems(
        scriptID: UUID,
        accountID: UUID,
        openToWrite: Date,
        timestamp: (Date) -> String
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "id", value: "eq.\(scriptID.uuidString)"),
            URLQueryItem(name: "user_id", value: "eq.\(accountID.uuidString)"),
            URLQueryItem(
                name: "or",
                value: "(\(monotonicOpenOrFilter(openToWrite: openToWrite, timestamp: timestamp)))"
            ),
        ]
    }

    /// Whether a fetched row already satisfies the desired open for this write.
    public static func isSatisfied(
        desired: ScriptDocument,
        current: ScriptDocument
    ) -> Bool {
        CloudScriptWrite(desired: desired, expectedRemote: nil)
            .currentMatchesDesired(current)
    }
}
