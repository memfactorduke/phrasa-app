import Foundation

/// Pure committed-vs-provisional policy for the on-screen reader position.
///
/// Automatic path:
/// - Commits never move backward.
/// - A +1 candidate commits immediately.
/// - Forward jumps of 2+ require two consecutive strong observations
///   (confidence ≥ ``strongConfidenceThreshold``) near the same candidate.
///
/// **Visibility:** ``VisiblePositionSnapshot/visibleIndex`` is always the
/// committed on-screen index. A single far callback only sets
/// ``provisionalIndex`` (diagnostic / pre-commit); it must not leap the UI
/// before the two-strong-observation gate. ``didCommit`` is the signal that
/// the committed (and therefore visible) index advanced.
///
/// Manual reseat is authoritative: it may land anywhere and clears provisional state.
public struct VisiblePositionSnapshot: Equatable, Sendable {
    public let committedIndex: Int
    /// Candidate under evaluation for a multi-word jump; not shown on screen.
    public let provisionalIndex: Int?
    /// Always equal to ``committedIndex``. Never follows provisional until commit.
    public var visibleIndex: Int { committedIndex }
    public let didCommit: Bool
    public let didUpdateProvisional: Bool
    public let strongStreak: Int

    init(
        committedIndex: Int,
        provisionalIndex: Int?,
        didCommit: Bool,
        didUpdateProvisional: Bool,
        strongStreak: Int
    ) {
        self.committedIndex = committedIndex
        self.provisionalIndex = provisionalIndex
        self.didCommit = didCommit
        self.didUpdateProvisional = didUpdateProvisional
        self.strongStreak = strongStreak
    }
}

/// Deterministic package-level controller. No I/O; safe for unit tests and app wiring later.
public struct VisiblePositionController: Equatable, Sendable {
    public static let strongConfidenceThreshold = 0.78
    /// Candidates within this distance count as "near the same" for the two-observation rule.
    public static let nearCandidateRadius = 1

    public private(set) var committedIndex: Int
    public private(set) var provisionalIndex: Int?

    private var strongCandidate: Int?
    private var strongStreak: Int

    public init(committedIndex: Int = 0) {
        self.committedIndex = max(0, committedIndex)
        self.provisionalIndex = nil
        self.strongCandidate = nil
        self.strongStreak = 0
    }

    /// On-screen index: always the committed position (never provisional).
    public var visibleIndex: Int {
        committedIndex
    }

    /// Observe an alignment candidate (matchable or display index — caller's convention).
    @discardableResult
    public mutating func observe(candidateIndex: Int, confidence: Double) -> VisiblePositionSnapshot {
        let candidate = max(0, candidateIndex)
        let previousProvisional = provisionalIndex

        // Automatic commits never move backward.
        if candidate < committedIndex {
            clearProvisionalAndStreak()
            return snapshot(
                didCommit: false,
                didUpdateProvisional: previousProvisional != provisionalIndex
            )
        }

        let delta = candidate - committedIndex

        if delta == 0 {
            // Confirmed stay; drop any provisional at this or another spot.
            let cleared = provisionalIndex != nil
            clearProvisionalAndStreak()
            return snapshot(didCommit: false, didUpdateProvisional: cleared)
        }

        if delta == 1 {
            committedIndex = candidate
            clearProvisionalAndStreak()
            return snapshot(didCommit: true, didUpdateProvisional: previousProvisional != nil)
        }

        // Forward jump of 2 or more.
        let isStrong = confidence >= Self.strongConfidenceThreshold
        guard isStrong else {
            // Weak far observations do not accumulate; provisional stays cleared.
            let hadProvisional = provisionalIndex != nil
            clearProvisionalAndStreak()
            return snapshot(didCommit: false, didUpdateProvisional: hadProvisional)
        }

        if let prior = strongCandidate, isNear(candidate, prior) {
            strongStreak += 1
            // Keep streak anchored on the latest strong reading.
            strongCandidate = candidate
        } else {
            strongCandidate = candidate
            strongStreak = 1
        }

        if strongStreak >= 2 {
            committedIndex = candidate
            clearProvisionalAndStreak()
            return snapshot(didCommit: true, didUpdateProvisional: previousProvisional != nil)
        }

        provisionalIndex = candidate
        return snapshot(
            didCommit: false,
            didUpdateProvisional: previousProvisional != provisionalIndex
        )
    }

    /// Manual reseat: authoritative, may move anywhere, clears provisional state.
    @discardableResult
    public mutating func manualReseat(to index: Int) -> VisiblePositionSnapshot {
        let previousProvisional = provisionalIndex
        let target = max(0, index)
        committedIndex = target
        clearProvisionalAndStreak()
        return snapshot(didCommit: true, didUpdateProvisional: previousProvisional != nil)
    }

    /// Full policy reset (e.g. new script).
    public mutating func reset(committedIndex: Int = 0) {
        self.committedIndex = max(0, committedIndex)
        clearProvisionalAndStreak()
    }

    private func isNear(_ a: Int, _ b: Int) -> Bool {
        abs(a - b) <= Self.nearCandidateRadius
    }

    private mutating func clearProvisionalAndStreak() {
        provisionalIndex = nil
        strongCandidate = nil
        strongStreak = 0
    }

    private func snapshot(didCommit: Bool, didUpdateProvisional: Bool) -> VisiblePositionSnapshot {
        VisiblePositionSnapshot(
            committedIndex: committedIndex,
            provisionalIndex: provisionalIndex,
            didCommit: didCommit,
            didUpdateProvisional: didUpdateProvisional,
            strongStreak: strongStreak
        )
    }
}
