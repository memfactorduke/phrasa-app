import Foundation

// MARK: - Outline stage presentation (pure, UI-free)

/// Snapshot of the three-part Outline stage derived solely from
/// ``OutlineCoverageEngine/index`` (never coverage, streak, or candidate match).
///
/// Slots are always present so the stage geometry stays stable. Boundary empties
/// reserve space and stay hidden from accessibility.
struct OutlineStagePresentation: Equatable, Sendable {
    /// Role of a fixed stage slot. Slot identity is the role — not the point id —
    /// so advancing never inserts/removes stage rows.
    enum Role: String, Equatable, Sendable, CaseIterable, Identifiable {
        case previous
        case current
        case next

        var id: String { rawValue }

        var eyebrow: String {
            switch self {
            case .previous: return "Previous"
            case .current: return "Now"
            case .next: return "Up next"
            }
        }
    }

    /// Content of one stable stage slot.
    struct Slot: Equatable, Sendable, Identifiable {
        let role: Role
        /// Engine point index when filled; `nil` for empty boundary placeholders.
        let pointIndex: Int?
        let pointID: UUID?
        let primary: String?
        let note: String?

        var id: Role { role }
        var isEmpty: Bool { pointID == nil }

        /// Combined accessibility label, or `nil` when the slot is empty.
        var accessibilityLabel: String? {
            guard let primary, !primary.isEmpty else { return nil }
            switch role {
            case .previous:
                return "Previous, \(primary)"
            case .current:
                if let note, !note.isEmpty {
                    return "Now, \(primary). \(note)"
                }
                return "Now, \(primary)"
            case .next:
                if let note, !note.isEmpty {
                    return "Up next, \(primary). \(note)"
                }
                return "Up next, \(primary)"
            }
        }
    }

    /// Engine current index mirrored into presentation (0-based).
    let currentIndex: Int
    let pointCount: Int
    let previous: Slot
    let current: Slot
    let next: Slot

    /// Stable ordered stage rows — always three slots.
    var slots: [Slot] { [previous, current, next] }

    var progressLabel: String {
        guard pointCount > 0 else { return "No points" }
        return "Point \(currentIndex + 1) of \(pointCount)"
    }

    var compactProgressLabel: String {
        guard pointCount > 0 else { return "—" }
        return "POINT \(currentIndex + 1) OF \(pointCount)"
    }

    // MARK: Factory

    /// Builds a stage from engine-owned points and the confirmed current index.
    ///
    /// - Important: Callers must pass ``OutlineCoverageEngine/index`` only.
    ///   Do not derive a display index from coverage or candidate matches.
    static func make(
        points: [OutlinePointModel],
        currentIndex: Int,
        isComplete: Bool = false
    ) -> OutlineStagePresentation? {
        guard !points.isEmpty, !isComplete else { return nil }
        let clamped = max(0, min(currentIndex, points.count - 1))

        let previous: Slot = {
            guard clamped > 0 else {
                return Slot(role: .previous, pointIndex: nil, pointID: nil, primary: nil, note: nil)
            }
            let point = points[clamped - 1]
            return Slot(
                role: .previous,
                pointIndex: clamped - 1,
                pointID: point.id,
                primary: point.primary,
                note: point.note
            )
        }()

        let currentPoint = points[clamped]
        let current = Slot(
            role: .current,
            pointIndex: clamped,
            pointID: currentPoint.id,
            primary: currentPoint.primary,
            note: currentPoint.note
        )

        let next: Slot = {
            guard clamped + 1 < points.count else {
                return Slot(role: .next, pointIndex: nil, pointID: nil, primary: nil, note: nil)
            }
            let point = points[clamped + 1]
            return Slot(
                role: .next,
                pointIndex: clamped + 1,
                pointID: point.id,
                primary: point.primary,
                // Include note so preview matches transition vocabulary (engine
                // can match note words); UI renders it as a subdued secondary cue.
                note: point.note
            )
        }()

        return OutlineStagePresentation(
            currentIndex: clamped,
            pointCount: points.count,
            previous: previous,
            current: current,
            next: next
        )
    }

    /// Convenience from a live engine. Uses `engine.index` exclusively.
    static func make(from engine: OutlineCoverageEngine) -> OutlineStagePresentation? {
        make(points: engine.points, currentIndex: engine.index, isComplete: engine.isComplete)
    }
}
