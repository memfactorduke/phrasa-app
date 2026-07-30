import Foundation

public struct AlignmentOptions: Equatable, Sendable {
    public var windowBack: Int
    public var windowForward: Int
    public var maxJump: Int
    public var probeLength: Int
    public var acceptanceConfidence: Double
    public var lead: Int
    public var reanchorAfter: Int
    public var reanchorConfidence: Double
    public var minimumReanchorProbe: Int
    public var reanchorScanBudget: Int

    public init(
        windowBack: Int = 10,
        windowForward: Int = 45,
        maxJump: Int = 20,
        probeLength: Int = 4,
        acceptanceConfidence: Double = 0.5,
        lead: Int = 1,
        reanchorAfter: Int = 4,
        reanchorConfidence: Double = 0.8,
        minimumReanchorProbe: Int = 2,
        reanchorScanBudget: Int = 1_500
    ) {
        self.windowBack = windowBack
        self.windowForward = windowForward
        self.maxJump = maxJump
        self.probeLength = probeLength
        self.acceptanceConfidence = acceptanceConfidence
        self.lead = lead
        self.reanchorAfter = reanchorAfter
        self.reanchorConfidence = reanchorConfidence
        self.minimumReanchorProbe = minimumReanchorProbe
        self.reanchorScanBudget = max(1, reanchorScanBudget)
    }

    public static let `default` = AlignmentOptions()
}

public struct AlignmentResult: Equatable, Sendable {
    public let tokenIndex: Int
    public let cursor: Int
    public let moved: Bool
    public let accepted: Bool
    public let missStreak: Int
    public let confidence: Double
    public let reanchored: Bool
}

/// Internal counters for deterministic hot-path bounds in package tests.
struct AlignmentSearchStats: Equatable, Sendable {
    var positionsScored: Int = 0
    var reanchorCandidates: Int = 0
    var usedGlobalReanchor: Bool = false
}

/// Stateful, deterministic streaming alignment against a known script.
public final class AlignmentEngine {
    private let normalizedWords: [String]
    private let tokenIndices: [Int]
    private let options: AlignmentOptions
    /// Exact inverted index: word → matchable positions (bounded candidate gen).
    private let positionIndex: [String: [Int]]
    /// Occurrence counts for uniqueness ranking.
    private let wordFrequency: [String: Int]

    private var cursor = -1
    private var misses = 0
    private var observationCount = 0
    private var lastGlobalScanObservation = Int.min / 2

    /// Last observe() search diagnostics (package tests only).
    private(set) var lastSearchStats = AlignmentSearchStats()

    public init(tokens: [ReaderToken], options: AlignmentOptions = .default) {
        var normalizedWords: [String] = []
        var tokenIndices: [Int] = []
        var positionIndex: [String: [Int]] = [:]
        var wordFrequency: [String: Int] = [:]

        for token in tokens where !token.normalized.isEmpty {
            let word = token.normalized
            let matchableIndex = normalizedWords.count
            normalizedWords.append(word)
            tokenIndices.append(token.index)
            positionIndex[word, default: []].append(matchableIndex)
            wordFrequency[word, default: 0] += 1
        }

        self.normalizedWords = normalizedWords
        self.tokenIndices = tokenIndices
        self.options = options
        self.positionIndex = positionIndex
        self.wordFrequency = wordFrequency
    }

    public convenience init(script: String, options: AlignmentOptions = .default) {
        self.init(tokens: ReaderTokenizer.tokenize(script), options: options)
    }

    public var matchableCount: Int { normalizedWords.count }
    public var cursorIndex: Int { cursor }

    /// Reset to the matchable word at or before a display token index.
    public func reset(tokenIndex: Int = 0) {
        misses = 0
        guard tokenIndex > 0 else {
            cursor = -1
            return
        }
        cursor = -1
        for (matchableIndex, displayIndex) in tokenIndices.enumerated() {
            guard displayIndex <= tokenIndex else { break }
            cursor = matchableIndex
        }
    }

    public func observe(_ recentWords: [String]) -> AlignmentResult {
        observationCount += 1
        lastSearchStats = AlignmentSearchStats()

        let words = recentWords.filter { !$0.isEmpty }
        guard !words.isEmpty, !normalizedWords.isEmpty else {
            return result(moved: false, accepted: false, confidence: 0, reanchored: false)
        }

        let length = min(options.probeLength, words.count)
        let probe = Array(words.suffix(length))
        let totalWeight = probe.reduce(0.0) { $0 + FuzzyMatcher.wordWeight($1) }
        guard totalWeight > 0 else {
            return result(moved: false, accepted: false, confidence: 0, reanchored: false)
        }

        let start = max(0, cursor - options.windowBack)
        let end = min(normalizedWords.count - 1, cursor + options.windowForward + length)
        // Continuity bias: once locked, prefer the next word, not a full probe-length
        // lookahead (which pulls duplicate tails / choruses forward). Unlocked
        // streams may still aim the probe near its natural ending length.
        let expected = cursor < 0 ? (length - 1) : (cursor + 1)

        var best: RankedCandidate?
        var nearBest: [RankedCandidate] = []

        if start <= end {
            for position in start...end {
                let candidate = score(probe: probe, endingAt: position)
                lastSearchStats.positionsScored += 1
                guard candidate.matchScore > 0 else { continue }
                let ranked = rank(
                    position: position,
                    candidate: candidate,
                    expected: expected,
                    totalWeight: totalWeight
                )
                if shouldReplace(best, with: ranked) {
                    if let previous = best, previous.matchScore >= ranked.matchScore * 0.92 {
                        nearBest.append(previous)
                    } else {
                        nearBest.removeAll(keepingCapacity: true)
                    }
                    best = ranked
                } else if let best, ranked.matchScore >= best.matchScore * 0.92 {
                    nearBest.append(ranked)
                }
            }
        }

        if let best {
            let confidence = best.matchScore / totalWeight
            let jump = best.position - cursor
            let clusterOK = isSafeCluster(best: best, peers: nearBest, probeCount: probe.count)
            let longLeap = jump > options.maxJump
            // Protect every forward multi-word jump (≥2), not only leaps past maxJump:
            // an identical chorus 8–15 words ahead must not win solely by sitting in-window.
            let multiWordForward = jump >= 2
            let accepted = confidence >= options.acceptanceConfidence &&
                (best.hasContent || confidence >= 0.7) &&
                !(longLeap && confidence < 0.78) &&
                !(multiWordForward && !clusterOK)

            if accepted {
                let moved = best.position != cursor
                cursor = best.position
                misses = 0
                return result(moved: moved, accepted: true, confidence: confidence, reanchored: false)
            }
        }

        let confidence = (best?.matchScore ?? 0) / totalWeight
        let probeHasContent = probe.contains { FuzzyMatcher.wordWeight($0) >= 1 }
        if probeHasContent { misses += 1 }

        let scanStride = max(
            1,
            Int(ceil(Double(normalizedWords.count) / Double(options.reanchorScanBudget)))
        )
        if probeHasContent,
           length >= options.minimumReanchorProbe,
           misses >= options.reanchorAfter,
           observationCount - lastGlobalScanObservation >= scanStride {
            lastGlobalScanObservation = observationCount
            if let reanchorConfidence = globallyReanchor(
                probe: probe,
                totalWeight: totalWeight
            ) {
                misses = 0
                return result(
                    moved: true,
                    accepted: true,
                    confidence: reanchorConfidence,
                    reanchored: true
                )
            }
        }

        return result(moved: false, accepted: false, confidence: confidence, reanchored: false)
    }

    // MARK: - Scoring

    private struct MatchScore {
        var matchScore: Double
        var uniqueness: Double
        var hasContent: Bool
        var contentMatches: Int
    }

    private struct RankedCandidate {
        var position: Int
        var matchScore: Double
        var uniqueness: Double
        var rankScore: Double
        var hasContent: Bool
        var contentMatches: Int
        var distanceToExpected: Int
    }

    private func score(probe: [String], endingAt position: Int) -> MatchScore {
        var matchScore = 0.0
        var uniqueness = 0.0
        var hasContent = false
        var contentMatches = 0

        for probeIndex in probe.indices {
            let scriptIndex = position - (probe.count - 1) + probeIndex
            guard normalizedWords.indices.contains(scriptIndex) else { continue }
            let scriptWord = normalizedWords[scriptIndex]
            if FuzzyMatcher.wordsSimilar(probe[probeIndex], scriptWord) {
                let weight = FuzzyMatcher.wordWeight(probe[probeIndex])
                matchScore += weight
                // Prefer script-side frequency so uniqueness reflects the text, not ASR noise.
                let frequency = Double(wordFrequency[scriptWord] ?? 1)
                uniqueness += weight / frequency
                if weight >= 1 {
                    hasContent = true
                    contentMatches += 1
                }
            }
        }
        return MatchScore(
            matchScore: matchScore,
            uniqueness: uniqueness,
            hasContent: hasContent,
            contentMatches: contentMatches
        )
    }

    private func rank(
        position: Int,
        candidate: MatchScore,
        expected: Int,
        totalWeight: Double
    ) -> RankedCandidate {
        let distance = abs(position - expected)
        // Small continuity bonus keeps repeated choruses from leaping when scores tie.
        let proximity = 1.0 / Double(1 + distance)
        let rankScore = candidate.matchScore + (candidate.uniqueness * 0.35) + (proximity * 0.05)
        return RankedCandidate(
            position: position,
            matchScore: candidate.matchScore,
            uniqueness: candidate.uniqueness,
            rankScore: rankScore,
            hasContent: candidate.hasContent,
            contentMatches: candidate.contentMatches,
            distanceToExpected: distance
        )
    }

    private func shouldReplace(_ current: RankedCandidate?, with next: RankedCandidate) -> Bool {
        guard let current else { return true }
        if next.rankScore != current.rankScore {
            return next.rankScore > current.rankScore
        }
        // Deterministic tie-break: closer to expected, then earlier position.
        if next.distanceToExpected != current.distanceToExpected {
            return next.distanceToExpected < current.distanceToExpected
        }
        return next.position < current.position
    }

    /// Reject multi-word forward jumps when equally good hits are widely scattered
    /// (ambiguous repeated phrase / chorus) without a uniqueness advantage.
    /// Applies to every jump ≥ 2 in the local window, not only leaps past maxJump.
    private func isSafeCluster(
        best: RankedCandidate,
        peers: [RankedCandidate],
        probeCount: Int
    ) -> Bool {
        let competitive = peers.filter { $0.matchScore >= best.matchScore * 0.92 }
        guard !competitive.isEmpty else { return true }

        var low = best.position
        var high = best.position
        for peer in competitive {
            low = min(low, peer.position)
            high = max(high, peer.position)
        }
        let span = high - low
        if span <= max(probeCount, 2) { return true }

        // Scattered competitive hits: only jump if best is clearly more unique.
        let peerMaxUniqueness = competitive.map(\.uniqueness).max() ?? 0
        return best.uniqueness >= peerMaxUniqueness + 0.25 && best.contentMatches >= 2
    }

    // MARK: - Far reanchor (bounded)

    private func globallyReanchor(probe: [String], totalWeight: Double) -> Double? {
        lastSearchStats.usedGlobalReanchor = true

        let candidates = reanchorCandidatePositions(probe: probe)
        lastSearchStats.reanchorCandidates = candidates.count

        var maximumMatch = 0.0
        var hits: [RankedCandidate] = []

        for position in candidates {
            let candidate = score(probe: probe, endingAt: position)
            lastSearchStats.positionsScored += 1
            guard candidate.matchScore > 0 else { continue }
            let ranked = RankedCandidate(
                position: position,
                matchScore: candidate.matchScore,
                uniqueness: candidate.uniqueness,
                rankScore: candidate.matchScore + candidate.uniqueness * 0.35,
                hasContent: candidate.hasContent,
                contentMatches: candidate.contentMatches,
                distanceToExpected: 0
            )
            if candidate.matchScore > maximumMatch {
                maximumMatch = candidate.matchScore
                hits = [ranked]
            } else if candidate.matchScore == maximumMatch {
                hits.append(ranked)
            }
        }

        guard maximumMatch > 0, !hits.isEmpty else { return nil }
        let confidence = maximumMatch / totalWeight
        guard confidence >= options.reanchorConfidence,
              hits.contains(where: \.hasContent) else {
            return nil
        }

        // Prefer the unique / clustered peak; never leap on an isolated weak hit.
        let best = hits.max { lhs, rhs in
            if lhs.uniqueness != rhs.uniqueness { return lhs.uniqueness < rhs.uniqueness }
            if lhs.contentMatches != rhs.contentMatches {
                return lhs.contentMatches < rhs.contentMatches
            }
            return lhs.position > rhs.position
        }!

        // Require multi-content support or a highly unique single content match.
        let strongEnough = best.contentMatches >= 2 ||
            (best.contentMatches >= 1 && best.uniqueness >= 0.9 && confidence >= 0.95)
        guard strongEnough else { return nil }

        var low = hits[0].position
        var high = low
        for hit in hits.dropFirst() {
            low = min(low, hit.position)
            high = max(high, hit.position)
        }

        // All top-score hits must form one tight cluster (repeated phrase elsewhere rejects).
        guard high - low <= max(probe.count, 2) else { return nil }

        // Prefer the uniqueness peak inside the tight top-score cluster.
        cursor = best.position
        return confidence
    }

    /// Build a bounded candidate set via inverted index, with a strided full-scan
    /// fallback so imperfect ASR still reanchors within `reanchorScanBudget`.
    private func reanchorCandidatePositions(probe: [String]) -> [Int] {
        let budget = options.reanchorScanBudget
        var scored: [Int: Int] = [:]

        for (probeIndex, word) in probe.enumerated() {
            let weight = FuzzyMatcher.wordWeight(word)
            guard weight >= 0.7 else { continue }
            let rarityBoost = max(1, 8 / max(1, wordFrequency[word] ?? 8))
            if let positions = positionIndex[word] {
                for scriptIndex in positions {
                    let endingAt = scriptIndex + (probe.count - 1 - probeIndex)
                    guard normalizedWords.indices.contains(endingAt) else { continue }
                    scored[endingAt, default: 0] += Int(weight * 10) + rarityBoost
                }
            }
        }

        if !scored.isEmpty {
            let sorted = scored.keys.sorted { lhs, rhs in
                let left = scored[lhs]!
                let right = scored[rhs]!
                if left != right { return left > right }
                return lhs < rhs
            }
            if sorted.count <= budget {
                return sorted
            }
            return Array(sorted.prefix(budget))
        }

        // Fallback: strided scan across the whole script (bounded by budget).
        let stride = max(1, Int(ceil(Double(normalizedWords.count) / Double(budget))))
        var positions: [Int] = []
        positions.reserveCapacity(min(budget, normalizedWords.count))
        var index = 0
        while index < normalizedWords.count && positions.count < budget {
            positions.append(index)
            index += stride
        }
        // Always include the last position so the end of script remains reachable.
        if let last = normalizedWords.indices.last, positions.last != last {
            if positions.count >= budget {
                positions[positions.count - 1] = last
            } else {
                positions.append(last)
            }
        }
        return positions
    }

    private func result(
        moved: Bool,
        accepted: Bool,
        confidence: Double,
        reanchored: Bool
    ) -> AlignmentResult {
        guard cursor >= 0 else {
            return AlignmentResult(
                tokenIndex: 0,
                cursor: -1,
                moved: moved,
                accepted: accepted,
                missStreak: misses,
                confidence: confidence,
                reanchored: reanchored
            )
        }
        let centered = min(cursor + options.lead, normalizedWords.count - 1)
        return AlignmentResult(
            tokenIndex: tokenIndices[centered],
            cursor: cursor,
            moved: moved,
            accepted: accepted,
            missStreak: misses,
            confidence: confidence,
            reanchored: reanchored
        )
    }
}
