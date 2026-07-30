import Foundation
import PhrasaCore

// MARK: - Options / reasons

/// Deterministic current→next transition thresholds for Outline mode.
///
/// Product semantic: the current point stays active until sustained **new**
/// speech favors the **next** point more strongly than the current one.
/// Completing (or paraphrasing) the current point alone never advances.
struct OutlineCoverageOptions: Equatable, Sendable {
    /// Minimum absolute next-point bag score required before an advance may fire.
    var absFloor: Double
    /// Next must beat current by at least this margin when current is still active.
    var margin: Double
    /// Floor on the required margin when the current point has clearly decayed.
    var minMargin: Double
    /// When current score falls below this, required margin relaxes toward `minMargin`.
    /// Decay is only a margin modifier — it never advances on its own.
    var selfFloor: Double
    /// Qualifying evidence measured in **new content words** (not raw observations)
    /// that must accumulate while the next-over-current condition holds.
    var hysteresis: Int
    /// New content words required after an advance before another may fire.
    var cooldown: Int
    /// Cap on pending evidence so a long stuck condition cannot unbounded-grow.
    var maxEvidence: Int
    /// Recent-word window used when scoring current vs next (rolling tail).
    var scoreWindow: Int
    /// How many trailing words of the previous observation may be ASR-revised
    /// without treating the stream as a silence flush.
    var interimRevisionTolerance: Int
    /// Absolute score units semantic support may add to next (never alone enough).
    var semanticBoostMax: Double

    init(
        absFloor: Double = 0.70,
        margin: Double = 0.45,
        minMargin: Double = 0.18,
        selfFloor: Double = 0.50,
        hysteresis: Int = 2,
        cooldown: Int = 3,
        maxEvidence: Int = 12,
        scoreWindow: Int = 16,
        interimRevisionTolerance: Int = 2,
        semanticBoostMax: Double = 0.12
    ) {
        self.absFloor = max(0, absFloor)
        self.margin = max(0, margin)
        self.minMargin = max(0, min(minMargin, margin))
        self.selfFloor = max(0, selfFloor)
        self.hysteresis = max(1, hysteresis)
        self.cooldown = max(0, cooldown)
        self.maxEvidence = max(hysteresis, maxEvidence)
        self.scoreWindow = max(4, scoreWindow)
        self.interimRevisionTolerance = max(0, interimRevisionTolerance)
        self.semanticBoostMax = max(0, semanticBoostMax)
    }

    static let `default` = OutlineCoverageOptions()
}

enum OutlineAdvanceReason: Equatable, Sendable {
    /// Sustained next-over-current speech evidence (never current-point completion).
    case transition
    case voiceCommand
    case manual
}

enum OutlineSessionAction: Equatable, Sendable {
    case none
    case stayed(index: Int, coverage: Double)
    case advanced(from: Int, to: Int, reason: OutlineAdvanceReason)
    case completed(from: Int, reason: OutlineAdvanceReason)
    case retreated(from: Int, to: Int, reason: OutlineAdvanceReason)
    /// Manual/voice step at a hard boundary (first/last/complete) with no index change.
    case boundary(reason: OutlineAdvanceReason)
}

// MARK: - Optional semantic support (lexical remains authoritative)

/// Pluggable on-device semantic signal for modest next-over-current support.
///
/// Contract:
/// - Similarity alone MUST NEVER advance.
/// - Implementations may use Apple NaturalLanguage embeddings only when available,
///   synchronously, and off the recognition hot path if work is non-trivial.
/// - Return `nil` / `0` when unavailable; the engine falls back to pure lexical matching.
/// - Production ships lexical-only unless a provider is explicitly injected.
protocol OutlineSemanticSignalProviding: Sendable {
    /// Optional 0…1 similarity of recent speech to a point's content words.
    func similarity(spokenWords: [String], pointWords: [String]) -> Double?
}

/// Absolute next-score support derived from an optional semantic provider.
/// Kept as a plain value so the engine stays `Equatable` / `Sendable` without
/// storing a provider reference.
struct OutlineSemanticSupport: Equatable, Sendable {
    /// Absolute contribution to next score, pre-clamp. Engine clamps to options.
    var nextBoost: Double

    static let none = OutlineSemanticSupport(nextBoost: 0)

    init(nextBoost: Double = 0) {
        self.nextBoost = max(0, nextBoost)
    }

    /// Build support from a provider. Semantic boost is only meaningful when
    /// there is already some lexical next attraction (caller still enforces).
    static func from(
        provider: (any OutlineSemanticSignalProviding)?,
        spokenWords: [String],
        nextPoint: OutlinePointModel?,
        maxBoost: Double
    ) -> OutlineSemanticSupport {
        guard let provider, let nextPoint, maxBoost > 0 else { return .none }
        let sim = provider.similarity(
            spokenWords: spokenWords,
            pointWords: nextPoint.matchableWords
        ) ?? 0
        guard sim > 0 else { return .none }
        return OutlineSemanticSupport(nextBoost: min(maxBoost, sim * maxBoost))
    }
}

// MARK: - Point model

/// Pre-tokenized talking point for matching (pure, no UI).
struct OutlinePointModel: Equatable, Sendable, Identifiable {
    let id: UUID
    let primary: String
    let note: String?
    /// Normalized content words used for matching.
    let matchableWords: [String]
    let weights: [Double]
    /// Discriminative bag: word → weight after outline-level DF down-weighting.
    let bag: [String: Double]
    let bagTotalWeight: Double

    var spokenText: String {
        if let note, !note.isEmpty {
            return "\(primary). \(note)"
        }
        return primary
    }

    var totalWeight: Double {
        weights.reduce(0, +)
    }

    static func make(from point: OutlinePoint, bag: [String: Double]) -> OutlinePointModel? {
        let primary = OutlineReaderContent.primaryText(for: point)
        guard !primary.isEmpty else { return nil }
        let note = OutlineReaderContent.supportingNote(for: point)
        let corpus = note.map { "\(primary) \($0)" } ?? primary
        let words = ReaderTokenizer.normalizeUtterance(corpus)
        guard !words.isEmpty else { return nil }
        let weights = words.map { FuzzyMatcher.wordWeight($0) }
        let bagTotal = bag.values.reduce(0, +)
        return OutlinePointModel(
            id: point.id,
            primary: primary,
            note: note,
            matchableWords: words,
            weights: weights,
            bag: bag,
            bagTotalWeight: bagTotal
        )
    }

    static func models(from outline: [OutlinePoint]) -> [OutlinePointModel] {
        let meaningful = OutlineReaderContent.meaningfulPoints(from: outline)
        let rawBags: [[String: Double]] = meaningful.map { point in
            let primary = OutlineReaderContent.primaryText(for: point)
            let note = OutlineReaderContent.supportingNote(for: point)
            let corpus = note.map { "\(primary) \($0)" } ?? primary
            let words = ReaderTokenizer.normalizeUtterance(corpus)
            var bag: [String: Double] = [:]
            for word in words {
                let weight = FuzzyMatcher.wordWeight(word)
                bag[word] = max(bag[word] ?? 0, weight)
            }
            return bag
        }

        // Document frequency across the outline — shared theme words are weak
        // evidence for *which* point the speaker is on.
        var df: [String: Int] = [:]
        for bag in rawBags {
            for word in bag.keys {
                df[word, default: 0] += 1
            }
        }

        var models: [OutlinePointModel] = []
        models.reserveCapacity(meaningful.count)
        for (point, raw) in zip(meaningful, rawBags) {
            var discriminative: [String: Double] = [:]
            for (word, weight) in raw {
                let count = Double(df[word] ?? 1)
                discriminative[word] = weight / max(1, count)
            }
            if let model = make(from: point, bag: discriminative) {
                models.append(model)
            }
        }
        return models
    }
}

// MARK: - Coverage / bag scoring (pure)

enum OutlineCoverageScorer: Sendable {
    /// Weighted fraction of content words covered by the spoken tail (0…1).
    /// Kept for diagnostics and unit tests; transition logic uses bag scores.
    static func coverage(
        spokenWords: [String],
        contentWords: [String],
        weights: [Double]
    ) -> Double {
        guard !contentWords.isEmpty else { return 1 }
        precondition(contentWords.count == weights.count)

        var matched = Set<Int>()
        for (index, content) in contentWords.enumerated() {
            for spoken in spokenWords where Self.matches(content: content, spoken: spoken) {
                matched.insert(index)
                break
            }
        }

        let total = weights.reduce(0, +)
        if total <= 0 {
            return Double(matched.count) / Double(contentWords.count)
        }
        let hit = matched.reduce(0.0) { $0 + weights[$1] }
        return min(1, hit / total)
    }

    /// Absolute discriminative bag score of `spokenWords` against a point bag.
    static func bagScore(spokenWords: [String], bag: [String: Double]) -> Double {
        guard !bag.isEmpty, !spokenWords.isEmpty else { return 0 }
        var score = 0.0
        for (word, weight) in bag {
            for spoken in spokenWords where matches(content: word, spoken: spoken) {
                score += weight
                break
            }
        }
        return score
    }

    /// Whether a single content word is considered spoken (exact or fuzzy).
    static func matches(content: String, spoken: String) -> Bool {
        if content == spoken { return true }
        return FuzzyMatcher.wordsSimilar(content, spoken)
    }
}

// MARK: - Rolling ASR delta

/// How far a rolling / cumulative recognition observation advanced.
struct OutlineTailDelta: Equatable, Sendable {
    /// Genuinely new words at the end of `curr` (revisions not counted).
    var newCount: Int
    /// True when no reliable overlap exists (silence flush / wholesale rewrite).
    var flushed: Bool
}

enum OutlineTailDeltaCalculator: Sendable {
    /// Compare previous and current observation word arrays.
    ///
    /// Handles: pure appends, identical repeats, cumulative rewrites, interim
    /// trailing-word revisions, and silence flushes. Identical tails report
    /// `newCount == 0` so unchanged transcripts never accumulate as proof.
    static func delta(
        prev: [String],
        curr: [String],
        interimRevisionTolerance: Int
    ) -> OutlineTailDelta {
        if prev.isEmpty {
            return OutlineTailDelta(newCount: curr.count, flushed: false)
        }
        if prev == curr {
            return OutlineTailDelta(newCount: 0, flushed: false)
        }

        let tolerance = max(0, interimRevisionTolerance)
        for revised in 0...tolerance {
            let core = prev.count - revised
            if core <= 0 { break }
            for shift in 0..<core {
                let overlap = core - shift
                if overlap > curr.count { continue }
                if equalSlice(prev, start: shift, curr, start: 0, length: overlap) {
                    // Words past the overlap include revision replacements + true
                    // appends; subtract revised so rewrites aren't fresh evidence.
                    let newCount = max(0, curr.count - overlap - revised)
                    return OutlineTailDelta(newCount: newCount, flushed: false)
                }
            }
        }
        return OutlineTailDelta(newCount: curr.count, flushed: true)
    }

    private static func equalSlice(
        _ a: [String],
        start aStart: Int,
        _ b: [String],
        start bStart: Int,
        length: Int
    ) -> Bool {
        for i in 0..<length {
            if a[aStart + i] != b[bStart + i] { return false }
        }
        return true
    }

    /// Count content-bearing words (weight ≥ 1) among the last `count` of `tail`.
    static func contentWordCount(in tail: [String], last count: Int) -> Int {
        guard count > 0, !tail.isEmpty else { return 0 }
        let start = max(0, tail.count - count)
        var total = 0
        for i in start..<tail.count {
            if FuzzyMatcher.wordWeight(tail[i]) >= 1.0 {
                total += 1
            }
        }
        return total
    }
}

// MARK: - Session engine

/// Stateful outline advancement: one point at a time, current→next only.
///
/// Rules:
/// - The current point stays active while speech matches current, is ambiguous,
///   silent, off-topic, or merely finishes the current point.
/// - Advance exactly one point only after sustained **new** speech indicates the
///   presenter has begun the **next** point more strongly than the current one.
/// - Never skip; next-next content cannot jump over next.
/// - Final point never auto-completes from speech — only manual / voice command.
/// - Voice commands are handled first and excluded from transition scoring.
///   Only end-anchored wake-word phrases match (see ``OutlineSpeechCommandParser``).
/// - Manual previous/next are authoritative and reset transition state.
struct OutlineCoverageEngine: Equatable, Sendable {
    private(set) var points: [OutlinePointModel]
    private(set) var options: OutlineCoverageOptions
    private(set) var index: Int
    private(set) var isComplete: Bool
    /// Instantaneous current-point match fraction (0…1) for diagnostics / UI.
    private(set) var coverage: Double
    /// Absolute discriminative score of the score window against the current point.
    private(set) var currentScore: Double
    /// Absolute discriminative score of the score window against the next point.
    private(set) var nextScore: Double
    /// Accumulated new content-word evidence while next-over-current holds.
    private(set) var pendingEvidence: Int
    /// New content words since last advance (cooldown gate).
    private(set) var sinceAdvance: Int
    /// Last command identity that already fired, so rolling partials do not multi-step.
    private(set) var lastConsumedCommandKey: String?

    /// Previous observation words (for rolling ASR delta).
    private var prevObservation: [String]
    /// True while evidence is building toward next.
    private var hasPendingTarget: Bool

    init(
        points: [OutlinePointModel],
        options: OutlineCoverageOptions = .default,
        index: Int = 0
    ) {
        self.points = points
        self.options = options
        self.index = points.isEmpty ? 0 : max(0, min(index, points.count - 1))
        self.isComplete = false
        self.coverage = 0
        self.currentScore = 0
        self.nextScore = 0
        self.pendingEvidence = 0
        self.sinceAdvance = Int.max / 4
        self.lastConsumedCommandKey = nil
        self.prevObservation = []
        self.hasPendingTarget = false
    }

    init(
        outline: [OutlinePoint],
        options: OutlineCoverageOptions = .default,
        index: Int = 0
    ) {
        self.init(points: OutlinePointModel.models(from: outline), options: options, index: index)
    }

    var pointCount: Int { points.count }
    var isEmpty: Bool { points.isEmpty }

    var currentPoint: OutlinePointModel? {
        guard !isComplete, points.indices.contains(index) else { return nil }
        return points[index]
    }

    var previousPoint: OutlinePointModel? {
        guard !isComplete, index > 0, points.indices.contains(index - 1) else { return nil }
        return points[index - 1]
    }

    var nextPoint: OutlinePointModel? {
        guard !isComplete, index + 1 < points.count else { return nil }
        return points[index + 1]
    }

    /// Combined script text for speech contextual strings (ordered talking points).
    var recognitionContextText: String {
        points.map(\.spokenText).joined(separator: "\n")
    }

    // MARK: Speech

    /// Feed a rolling recognition observation. Commands take priority over transition.
    @discardableResult
    mutating func observeSpeech(
        utterance: String,
        semanticSupport: OutlineSemanticSupport = .none
    ) -> OutlineSessionAction {
        observeSpeech(
            normalizedWords: ReaderTokenizer.normalizeUtterance(utterance),
            semanticSupport: semanticSupport
        )
    }

    @discardableResult
    mutating func observeSpeech(
        normalizedWords words: [String],
        semanticSupport: OutlineSemanticSupport = .none
    ) -> OutlineSessionAction {
        guard !points.isEmpty else { return .none }

        // Silence / empty: hold position; do not erase scores or pending evidence
        // from a prior non-empty observation (ASR may emit empty ticks).
        guard !words.isEmpty else {
            return isComplete ? .none : .stayed(index: index, coverage: coverage)
        }

        if isComplete {
            // Only explicit previous (manual) can leave complete; voice wake+previous too.
            if let command = OutlineSpeechCommandParser.match(normalizedWords: words) {
                return applyVoiceCommand(command, key: commandKey(words: words, command: command))
            }
            return .none
        }

        if let command = OutlineSpeechCommandParser.match(normalizedWords: words) {
            return applyVoiceCommand(command, key: commandKey(words: words, command: command))
        }

        // Non-command speech clears the consumed-command latch so the same
        // phrase can fire again after the speaker continues.
        lastConsumedCommandKey = nil

        return applyTransition(spokenWords: words, semanticSupport: semanticSupport)
    }

    // MARK: Manual

    @discardableResult
    mutating func goNext(reason: OutlineAdvanceReason = .manual) -> OutlineSessionAction {
        guard !points.isEmpty else { return .none }
        if isComplete { return .boundary(reason: reason) }
        // Manual navigation clears the voice-command latch; voice keeps it so the
        // same rolling partial cannot multi-step.
        if reason != .voiceCommand {
            lastConsumedCommandKey = nil
        }
        return advanceOne(reason: reason)
    }

    @discardableResult
    mutating func goPrevious(reason: OutlineAdvanceReason = .manual) -> OutlineSessionAction {
        guard !points.isEmpty else { return .none }
        if isComplete {
            isComplete = false
            index = max(0, points.count - 1)
            resetTransitionTracking(disarmCooldown: true)
            if reason != .voiceCommand {
                lastConsumedCommandKey = nil
            }
            return .retreated(from: points.count, to: index, reason: reason)
        }
        guard index > 0 else { return .boundary(reason: reason) }
        let from = index
        index -= 1
        resetTransitionTracking(disarmCooldown: true)
        // Preserve latch for voice so repeated wake+previous partials only retreat once.
        if reason != .voiceCommand {
            lastConsumedCommandKey = nil
        }
        return .retreated(from: from, to: index, reason: reason)
    }

    mutating func restart() {
        index = 0
        isComplete = false
        resetTransitionTracking(disarmCooldown: true)
        prevObservation = []
        lastConsumedCommandKey = nil
    }

    // MARK: Private

    private mutating func applyVoiceCommand(
        _ command: OutlineSpeechCommand,
        key: String
    ) -> OutlineSessionAction {
        if lastConsumedCommandKey == key {
            return isComplete ? .none : .stayed(index: index, coverage: coverage)
        }
        lastConsumedCommandKey = key
        switch command {
        case .next:
            return goNext(reason: .voiceCommand)
        case .previous:
            return goPrevious(reason: .voiceCommand)
        }
    }

    private mutating func applyTransition(
        spokenWords: [String],
        semanticSupport: OutlineSemanticSupport
    ) -> OutlineSessionAction {
        guard let current = currentPoint else { return .none }

        // Rolling / cumulative ASR: only genuinely new content is evidence.
        let delta = OutlineTailDeltaCalculator.delta(
            prev: prevObservation,
            curr: spokenWords,
            interimRevisionTolerance: options.interimRevisionTolerance
        )
        prevObservation = spokenWords

        let newContent = OutlineTailDeltaCalculator.contentWordCount(
            in: spokenWords,
            last: delta.newCount
        )

        if !delta.flushed {
            sinceAdvance = saturatingAdd(sinceAdvance, newContent)
        }
        // Flush: cooldown is preserved (a pause must not license a double jump)
        // and sinceAdvance is not accelerated from the full rewritten tail.
        // Pending is resolved after scoring — unrelated rewrites clear it when
        // they fail to re-qualify; distinctive next speech may seed conservatively.

        // Score a bounded recent window so long cumulative transcripts don't
        // keep the current bag forever elevated after the speaker has moved on.
        let window = Array(spokenWords.suffix(options.scoreWindow))
        let rawCurrent = OutlineCoverageScorer.bagScore(spokenWords: window, bag: current.bag)
        currentScore = rawCurrent
        coverage = coverageFraction(score: rawCurrent, point: current)

        // Final point: track diagnostics but never auto-complete from speech.
        guard let next = nextPoint else {
            nextScore = 0
            hasPendingTarget = false
            pendingEvidence = 0
            return .stayed(index: index, coverage: coverage)
        }

        let lexicalNext = OutlineCoverageScorer.bagScore(spokenWords: window, bag: next.bag)
        // Semantic may modestly support next only when lexical next already > 0.
        // It can never be the sole reason to advance (absFloor still required on total).
        let boost: Double
        if lexicalNext > 0, semanticSupport.nextBoost > 0 {
            boost = min(options.semanticBoostMax, semanticSupport.nextBoost)
        } else {
            boost = 0
        }
        let rawNext = lexicalNext + boost
        nextScore = rawNext

        // Decay only relaxes the margin; never advances alone.
        let requiredMargin =
            rawCurrent < options.selfFloor ? options.minMargin : options.margin

        let qualifies =
            rawNext + 1e-9 >= options.absFloor
            && (rawNext - rawCurrent) + 1e-9 >= requiredMargin

        if !qualifies {
            // Wholesale rewrite to non-next (or weak) speech drops stale pending.
            hasPendingTarget = false
            pendingEvidence = 0
            return .stayed(index: index, coverage: coverage)
        }

        // Evidence contribution this tick.
        // Flush / new-utterance: bound so the entire rewritten tail cannot alone
        // satisfy hysteresis, but distinctive next speech still builds fresh proof
        // across separate observations (e.g. "deep dive" then full next phrase).
        let contributed: Int
        if delta.flushed {
            let flushCap = max(0, options.hysteresis - 1)
            contributed = min(newContent, flushCap)
        } else {
            contributed = newContent
        }

        // Accumulate only new content while the condition holds.
        // Identical / non-growing observations contribute 0 and never accumulate.
        if hasPendingTarget {
            pendingEvidence = min(options.maxEvidence, pendingEvidence + contributed)
        } else {
            hasPendingTarget = true
            pendingEvidence = min(options.maxEvidence, contributed)
        }

        // Advance only on a tick that brought new content, after sustained evidence
        // and cooldown. Same rolling partial never multi-advances.
        // A single flush cannot fire alone (contributed ≤ hysteresis-1 when pending
        // was 0); sustained distinctive next across ticks still can.
        if contributed > 0,
           pendingEvidence >= options.hysteresis,
           sinceAdvance >= options.cooldown {
            return advanceOne(reason: .transition)
        }

        return .stayed(index: index, coverage: coverage)
    }

    private mutating func advanceOne(reason: OutlineAdvanceReason) -> OutlineSessionAction {
        let from = index
        // Speech transitions never complete the outline — only manual/voice may
        // finish the final point. Guard belt-and-suspenders for transition path.
        if index >= points.count - 1 {
            if reason == .transition {
                // Keep prevObservation so an identical final-point partial
                // cannot re-count the whole tail as new evidence.
                resetTransitionTracking(disarmCooldown: false)
                sinceAdvance = 0
                return .stayed(index: index, coverage: coverage)
            }
            isComplete = true
            resetTransitionTracking(disarmCooldown: true)
            return .completed(from: from, reason: reason)
        }
        index += 1
        // Keep prevObservation: the advancing utterance is already stored, so a
        // repeated identical partial contributes newContent=0 (no double jump).
        resetTransitionTracking(disarmCooldown: false)
        sinceAdvance = 0
        return .advanced(from: from, to: index, reason: reason)
    }

    private mutating func resetTransitionTracking(disarmCooldown: Bool) {
        coverage = 0
        currentScore = 0
        nextScore = 0
        pendingEvidence = 0
        hasPendingTarget = false
        // After manual reseat, allow the next *fresh* next-favoring evidence to
        // count toward hysteresis without waiting out a prior transition's cooldown.
        // After a speech advance, caller sets sinceAdvance = 0 (arm cooldown).
        if disarmCooldown {
            sinceAdvance = Int.max / 4
        }
    }

    private func coverageFraction(score: Double, point: OutlinePointModel) -> Double {
        let total = point.bagTotalWeight
        guard total > 0 else { return 0 }
        return min(1, score / total)
    }

    private func commandKey(words: [String], command: OutlineSpeechCommand) -> String {
        // Identity is command + end phrase (wake + action). Same rolling partial
        // keeps the same key so latching prevents multi-step on one utterance.
        let tail = words.suffix(6).joined(separator: " ")
        switch command {
        case .next: return "next|\(tail)"
        case .previous: return "previous|\(tail)"
        }
    }

    private func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let limit = Int.max / 4
        if a >= limit { return limit }
        return min(limit, a + b)
    }
}
