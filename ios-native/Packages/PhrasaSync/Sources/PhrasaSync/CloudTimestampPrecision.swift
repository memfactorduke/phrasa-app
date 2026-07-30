import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// Timestamp precision helpers for cloud identity and optimistic concurrency.
///
/// - **Microseconds** (`microseconds` / `matches` / `normalized` / `latest`) are
///   the durable precision for `updatedAt` OCC predicates and deletes. A
///   half-millisecond stale expected must still fail closed.
/// - **Wire milliseconds** (`wireMilliseconds` / `wireMatches` / `wireIsAtLeast`
///   / `wireNormalized` / `wireLatest`) match the unavoidable JSON / PostgREST
///   boundary: fractional seconds collapse to milliseconds on the wire.
///   Derived from **rounded microseconds ÷ 1000**, not raw `Double * 1000`
///   toward-zero — an already-ms Date such as `…734000` must not slip to
///   `…733` under binary floating-point noise (production tag-edit failure).
///
/// Content conflict safety is otherwise unchanged — only this wire boundary is
/// canonicalized. Wall clocks are never used to decide content winners.
public enum CloudTimestampPrecision {
    public static func microseconds(_ date: Date) -> Int64 {
        var wholeSeconds = floor(date.timeIntervalSince1970)
        var microseconds = Int(
            ((date.timeIntervalSince1970 - wholeSeconds) * 1_000_000).rounded()
        )
        if microseconds == 1_000_000 {
            wholeSeconds += 1
            microseconds = 0
        }
        return Int64(wholeSeconds) * 1_000_000 + Int64(microseconds)
    }

    /// Stable millisecond canonicalization for wire-facing timestamps.
    ///
    /// Uses integer division on rounded microseconds so values that already
    /// represent an exact millisecond stay put. Raw `(timeInterval * 1000)
    /// .towardZero` is unsafe: Double cannot represent many ms boundaries
    /// exactly, and production saw `…734000` encode/store as `…733`.
    public static func wireMilliseconds(_ date: Date) -> Int64 {
        microseconds(date) / 1_000
    }

    public static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(microseconds(date)) / 1_000_000)
    }

    public static func wireNormalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(wireMilliseconds(date)) / 1_000)
    }

    public static func matches(_ left: Date, _ right: Date) -> Bool {
        microseconds(left) == microseconds(right)
    }

    public static func matches(_ left: Date?, _ right: Date?) -> Bool {
        switch (left, right) {
        case (.none, .none): true
        case (.some(let left), .some(let right)): matches(left, right)
        case (.none, .some), (.some, .none): false
        }
    }

    public static func wireMatches(_ left: Date, _ right: Date) -> Bool {
        wireMilliseconds(left) == wireMilliseconds(right)
    }

    public static func wireMatches(_ left: Date?, _ right: Date?) -> Bool {
        switch (left, right) {
        case (.none, .none): true
        case (.some(let left), .some(let right)): wireMatches(left, right)
        case (.none, .some), (.some, .none): false
        }
    }

    /// Whether `candidate` is at least as new as `floor` after wire truncation.
    /// Used for last-opened satisfaction: server `.746000` covers local `.746402`.
    public static func wireIsAtLeast(_ candidate: Date, _ floor: Date) -> Bool {
        wireMilliseconds(candidate) >= wireMilliseconds(floor)
    }

    public static func latest(_ left: Date, _ right: Date) -> Date {
        normalized(microseconds(left) >= microseconds(right) ? left : right)
    }

    public static func latest(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case (.none, .none): nil
        case (.some(let value), .none), (.none, .some(let value)): normalized(value)
        case (.some(let left), .some(let right)): latest(left, right)
        }
    }

    /// Monotonic open-recency merge at wire precision so sub-ms local vs server
    /// echo does not re-upload forever. True multi-ms open advances still win.
    public static func wireLatest(_ left: Date, _ right: Date) -> Date {
        wireMilliseconds(left) >= wireMilliseconds(right)
            ? wireNormalized(left)
            : wireNormalized(right)
    }

    public static func wireLatest(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case (.none, .none): nil
        case (.some(let value), .none), (.none, .some(let value)): wireNormalized(value)
        case (.some(let left), .some(let right)): wireLatest(left, right)
        }
    }
}
