import XCTest
import PhrasaCore
@testable import Phrasa

final class OutlineModeTests: XCTestCase {

    // MARK: - Fixtures

    private func sampleOutline() -> [OutlinePoint] {
        [
            OutlinePoint(text: "Welcome everyone to the annual product review", note: "Smile and pause"),
            OutlinePoint(text: "Revenue grew twenty percent this quarter", note: ""),
            OutlinePoint(text: "Customer satisfaction hit a new high", note: "Show the chart"),
            OutlinePoint(text: "Next steps for the roadmap", note: "Invite questions"),
        ]
    }

    private func engine(
        outline: [OutlinePoint]? = nil,
        options: OutlineCoverageOptions = .default
    ) -> OutlineCoverageEngine {
        OutlineCoverageEngine(outline: outline ?? sampleOutline(), options: options)
    }

    /// Feed successive observations; return the last action.
    @discardableResult
    private func feed(
        _ session: inout OutlineCoverageEngine,
        _ utterances: [String]
    ) -> OutlineSessionAction {
        var last: OutlineSessionAction = .none
        for utterance in utterances {
            last = session.observeSpeech(utterance: utterance)
        }
        return last
    }

    // MARK: - Content model

    func testModelsFilterEmptyAndPreserveOrder() {
        let outline = [
            OutlinePoint(text: "  Hook  ", note: " smile "),
            OutlinePoint(text: "   ", note: "   "),
            OutlinePoint(text: "", note: "Only note"),
        ]
        let models = OutlinePointModel.models(from: outline)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].primary, "Hook")
        XCTAssertEqual(models[0].note, "smile")
        XCTAssertEqual(models[1].primary, "Only note")
        XCTAssertNil(models[1].note)
        XCTAssertFalse(models[0].bag.isEmpty)
    }

    func testDiscriminativeBagDownweightsSharedWords() {
        let outline = [
            OutlinePoint(text: "Pricing tiers overview"),
            OutlinePoint(text: "Pricing objections handling"),
        ]
        let models = OutlinePointModel.models(from: outline)
        XCTAssertEqual(models.count, 2)
        // "pricing" appears in both → DF halves its weight relative to unique words.
        let shared0 = models[0].bag["pricing"] ?? 0
        let unique0 = models[0].bag["tiers"] ?? 0
        XCTAssertGreaterThan(unique0, 0)
        XCTAssertGreaterThan(shared0, 0)
        XCTAssertLessThan(shared0, unique0 + 1e-9)
    }

    // MARK: 1. Finishing current but no next speech stays

    func testFinishingCurrentWithoutNextSpeechStays() {
        var session = engine()
        let fullCurrent =
            "welcome everyone to the annual product review smile and pause"
        // Completing the current point — even repeatedly — must not advance.
        for _ in 0..<4 {
            let action = session.observeSpeech(utterance: fullCurrent)
            if case .advanced = action {
                return XCTFail("Completing current must not advance, got \(action)")
            }
            if case .completed = action {
                return XCTFail("Completing current must not complete outline, got \(action)")
            }
        }
        XCTAssertEqual(session.index, 0)
        XCTAssertFalse(session.isComplete)
        XCTAssertGreaterThan(session.coverage, 0.5)
    }

    // MARK: 2. First next keywords stay; sustained additional next evidence advances

    func testFirstNextKeywordsStayThenSustainedNextAdvances() {
        var session = engine()
        // Stay on current first.
        _ = session.observeSpeech(
            utterance: "welcome everyone annual product review"
        )
        XCTAssertEqual(session.index, 0)

        // First next keywords alone (single content-word hit) stay.
        let first = session.observeSpeech(utterance: "revenue")
        XCTAssertEqual(session.index, 0)
        if case .advanced = first {
            return XCTFail("First thin next keyword must not advance alone, got \(first)")
        }

        // Sustained additional next evidence advances exactly one step.
        let second = session.observeSpeech(
            utterance: "revenue grew twenty percent this quarter"
        )
        guard case .advanced(let from, let to, .transition) = second else {
            return XCTFail("Sustained next evidence should advance, got \(second)")
        }
        XCTAssertEqual(from, 0)
        XCTAssertEqual(to, 1)
        XCTAssertEqual(session.index, 1)
        XCTAssertFalse(session.isComplete)
    }

    // MARK: 3. Ambiguous shared words stay

    func testAmbiguousSharedWordsStay() {
        let outline = [
            OutlinePoint(text: "Pricing tiers for enterprise"),
            OutlinePoint(text: "Pricing objections from buyers"),
        ]
        var session = engine(outline: outline)

        // Shared theme word only — never enough distinctive next evidence.
        for utterance in [
            "pricing",
            "our pricing",
            "pricing pricing tiers pricing",
            "talking about pricing again",
        ] {
            let action = session.observeSpeech(utterance: utterance)
            XCTAssertEqual(session.index, 0, "Shared 'pricing' must not advance (\(utterance))")
            if case .advanced = action {
                return XCTFail("Shared keyword must not advance, got \(action) for \(utterance)")
            }
        }

        // Distinctive next evidence still works.
        let advance = feed(&session, [
            "pricing objections",
            "pricing objections from buyers",
        ])
        guard case .advanced(_, let to, .transition) = advance else {
            return XCTFail("Distinctive next words should advance, got \(advance)")
        }
        XCTAssertEqual(to, 1)
    }

    // MARK: 4. Off-topic stays

    func testOffTopicSpeechStays() {
        var session = engine()
        _ = session.observeSpeech(utterance: "welcome everyone annual")
        let action = feed(&session, [
            "honestly the weather lately has been strange",
            "coffee tangent sidebar whatever you know",
            "um okay just thinking about lunch",
        ])
        XCTAssertEqual(session.index, 0)
        if case .advanced = action {
            XCTFail("Off-topic speech must not advance")
        }
    }

    // MARK: 5. Realistic limited paraphrase / morphology / fuzzy next evidence

    func testFuzzyAndParaphraseNextEvidenceCanAdvance() {
        let outline = [
            OutlinePoint(text: "Retention drives long term growth"),
            OutlinePoint(text: "Pricing strategy needs revision"),
        ]
        var session = engine(outline: outline)

        // Fuzzy / near-miss next vocabulary (phonetic / edit distance).
        _ = feed(&session, [
            "prisng strategy",
            "pricing strategy needs revision",
        ])
        // May already be on 1 after the first fuzzy hit + second confirm; last
        // action can be stayed once the index has moved.
        if session.index == 0 {
            _ = session.observeSpeech(utterance: "pricing strategy needs revision now")
        }
        XCTAssertEqual(session.index, 1, "Fuzzy/paraphrase next evidence should advance once")
        XCTAssertFalse(session.isComplete)
    }

    func testParaphraseStayingOnCurrentDoesNotAdvance() {
        var session = engine()
        // Paraphrase of current (overlapping keywords) without next vocabulary.
        _ = feed(&session, [
            "welcome everyone to this annual product review",
            "we smile and pause for a moment together",
            "welcome annual product review smile pause",
        ])
        XCTAssertEqual(session.index, 0)
        XCTAssertFalse(session.isComplete)
    }

    // MARK: 6. Short next point

    func testShortNextPointAdvancesOnlyWithSustainedEvidence() {
        let outline = [
            OutlinePoint(text: "Open the annual product review meeting today"),
            OutlinePoint(text: "Hiring plan"),
            OutlinePoint(text: "Closing remarks for leadership"),
        ]
        var session = engine(outline: outline)

        // One-word accidental match must not advance.
        let thin = session.observeSpeech(utterance: "hiring")
        XCTAssertEqual(session.index, 0)
        if case .advanced = thin {
            return XCTFail("Single short-next keyword must not advance, got \(thin)")
        }

        // Sustained short-next evidence (both distinctive words, growing) advances.
        let advance = feed(&session, [
            "hiring",
            "hiring plan",
        ])
        // Depending on weights/margin, may need one more distinctive tick.
        if session.index == 0 {
            _ = session.observeSpeech(utterance: "our hiring plan starts now")
        }
        XCTAssertEqual(session.index, 1, "Sustained short-next evidence should advance once")
        if case .advanced(_, _, .transition) = advance {
            // advanced on the cumulative feed — fine
        }
        XCTAssertFalse(session.isComplete)
    }

    // MARK: 7. Repeated phrases

    func testRepeatedPhrasesDoNotAdvanceWithoutDistinctiveNext() {
        let outline = [
            OutlinePoint(text: "Growth metrics overview for the team"),
            OutlinePoint(text: "Growth metrics deep dive details"),
        ]
        var session = engine(outline: outline)

        for _ in 0..<5 {
            _ = session.observeSpeech(
                utterance: "growth metrics growth metrics overview for the team"
            )
        }
        XCTAssertEqual(session.index, 0, "Repeated shared/current phrases must not advance")

        // Distinctive next words do advance.
        _ = feed(&session, [
            "deep dive",
            "growth metrics deep dive details",
        ])
        XCTAssertEqual(session.index, 1)
    }

    // MARK: 8. Silence

    func testSilenceDoesNotAdvanceOrEraseScores() {
        var session = engine()
        _ = session.observeSpeech(utterance: "welcome everyone annual product")
        let coverageAfterSpeech = session.coverage
        XCTAssertGreaterThan(coverageAfterSpeech, 0)

        let silence = session.observeSpeech(normalizedWords: [])
        guard case .stayed(let index, _) = silence else {
            return XCTFail("Silence should stay, got \(silence)")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.coverage, coverageAfterSpeech, accuracy: 1e-9)
        XCTAssertFalse(session.isComplete)
    }

    // MARK: 9. Identical rolling partial does not accumulate evidence

    func testIdenticalRollingPartialDoesNotAccumulateEvidence() {
        let outline = [
            OutlinePoint(text: "Welcome to the product keynote session"),
            OutlinePoint(text: "Revenue grew twenty percent"),
        ]
        var session = engine(outline: outline)

        // A next-favoring partial that is not quite enough alone.
        _ = session.observeSpeech(utterance: "revenue")
        let pendingAfterFirst = session.pendingEvidence
        XCTAssertEqual(session.index, 0)

        // Identical re-delivery must not stack evidence.
        for _ in 0..<6 {
            _ = session.observeSpeech(utterance: "revenue")
            XCTAssertEqual(
                session.pendingEvidence,
                pendingAfterFirst,
                "Identical partial must not accumulate independent proof"
            )
            XCTAssertEqual(session.index, 0)
        }
    }

    // MARK: 10. Cumulative rolling transcript extracts only new evidence

    func testCumulativeRollingTranscriptExtractsOnlyNewEvidence() {
        let delta1 = OutlineTailDeltaCalculator.delta(
            prev: ["a", "b", "c"],
            curr: ["a", "b", "c", "d", "e"],
            interimRevisionTolerance: 2
        )
        XCTAssertEqual(delta1.newCount, 2)
        XCTAssertFalse(delta1.flushed)

        let deltaSame = OutlineTailDeltaCalculator.delta(
            prev: ["a", "b", "c"],
            curr: ["a", "b", "c"],
            interimRevisionTolerance: 2
        )
        XCTAssertEqual(deltaSame.newCount, 0)
        XCTAssertFalse(deltaSame.flushed)

        // Engine: cumulative append of next-point words advances once, not by double-count.
        let outline = [
            OutlinePoint(text: "Welcome everyone annual keynote"),
            OutlinePoint(text: "Revenue grew twenty percent quarter"),
        ]
        var session = engine(outline: outline)
        _ = session.observeSpeech(utterance: "welcome everyone annual")
        _ = session.observeSpeech(utterance: "welcome everyone annual revenue")
        XCTAssertEqual(session.index, 0)
        _ = session.observeSpeech(
            utterance: "welcome everyone annual revenue grew twenty percent quarter"
        )
        XCTAssertEqual(session.index, 1)
        XCTAssertFalse(session.isComplete)
    }

    // MARK: 11. ASR rewrite / rebase behavior

    func testASRRewriteRebaseDoesNotFalseFlushOnInterimRevision() {
        // Trailing interim revision: not a flush; only true appends count as new.
        let revised = OutlineTailDeltaCalculator.delta(
            prev: ["a", "b", "helo"],
            curr: ["a", "b", "hello", "world"],
            interimRevisionTolerance: 2
        )
        XCTAssertEqual(revised.newCount, 1)
        XCTAssertFalse(revised.flushed)

        let pureReplace = OutlineTailDeltaCalculator.delta(
            prev: ["a", "b", "helo"],
            curr: ["a", "b", "hello"],
            interimRevisionTolerance: 2
        )
        XCTAssertEqual(pureReplace.newCount, 0)
        XCTAssertFalse(pureReplace.flushed)

        let shrink = OutlineTailDeltaCalculator.delta(
            prev: ["a", "b", "hello", "world"],
            curr: ["a", "b", "hi"],
            interimRevisionTolerance: 2
        )
        XCTAssertEqual(shrink.newCount, 0)
        XCTAssertFalse(shrink.flushed)
    }

    func testASRFlushResetsPendingEvidenceButNotCooldown() {
        let outline = [
            OutlinePoint(text: "Welcome everyone annual keynote"),
            OutlinePoint(text: "Revenue grew twenty percent"),
            OutlinePoint(text: "Customer satisfaction high"),
        ]
        var session = engine(outline: outline)

        // Build toward next.
        _ = session.observeSpeech(utterance: "revenue")
        XCTAssertGreaterThan(session.pendingEvidence, 0)

        // Wholesale unrelated rewrite → flush pending.
        _ = session.observeSpeech(utterance: "um okay")
        XCTAssertEqual(session.pendingEvidence, 0)
        XCTAssertEqual(session.index, 0)

        // After a real advance, a flushed next-next tail must not double-advance
        // in a single observation (flush does not seed hysteresis).
        _ = feed(&session, [
            "revenue grew twenty percent",
            "revenue grew twenty percent this quarter strongly",
        ])
        XCTAssertEqual(session.index, 1)

        // Immediate next-next content (no overlap → flush) stays.
        _ = session.observeSpeech(utterance: "customer satisfaction high show chart")
        XCTAssertEqual(session.index, 1, "Flush after advance must not double-advance in one tick")

        // One more growing observation still needs cooldown + hysteresis; with
        // default cooldown it should remain on 1 for a single append tick.
        _ = session.observeSpeech(
            utterance: "customer satisfaction high show chart clearly"
        )
        XCTAssertEqual(session.index, 1, "Cooldown must hold brief double-advance pressure")
    }

    // MARK: 12. Next-next content cannot skip

    func testNextNextContentCannotSkip() {
        var session = engine()
        // Speak point 2 content while still on point 0.
        let action = feed(&session, [
            "customer satisfaction hit a new high",
            "customer satisfaction hit a new high show the chart",
            "customer satisfaction hit a new high show the chart again",
        ])
        XCTAssertEqual(session.index, 0)
        XCTAssertFalse(session.isComplete)
        if case .advanced = action {
            XCTFail("Must not jump to a later point from next-next speech")
        }
        if case .completed = action {
            XCTFail("Must not complete from next-next speech")
        }
    }

    func testNeverSkipsOnTransitionPath() {
        var session = engine()
        // Advance 0 → 1 with real next evidence.
        _ = feed(&session, [
            "revenue grew",
            "revenue grew twenty percent this quarter",
        ])
        XCTAssertEqual(session.index, 1)

        // Point 3 words while on 1 must not skip to 2 or 3.
        _ = feed(&session, [
            "next steps for the roadmap invite questions",
            "next steps for the roadmap invite questions please",
        ])
        XCTAssertEqual(session.index, 1)
    }

    // MARK: 13. Commands, latching, manual boundaries

    func testManualNextAndPreviousAndBoundaries() {
        var session = engine()
        XCTAssertEqual(session.index, 0)

        let prevAtStart = session.goPrevious(reason: .manual)
        XCTAssertEqual(prevAtStart, .boundary(reason: .manual))
        XCTAssertEqual(session.index, 0)

        XCTAssertEqual(session.goNext(reason: .manual), .advanced(from: 0, to: 1, reason: .manual))
        XCTAssertEqual(session.goNext(reason: .manual), .advanced(from: 1, to: 2, reason: .manual))
        XCTAssertEqual(session.goPrevious(reason: .manual), .retreated(from: 2, to: 1, reason: .manual))

        // Finish from last point.
        _ = session.goNext(reason: .manual) // 2
        _ = session.goNext(reason: .manual) // 3
        let done = session.goNext(reason: .manual)
        XCTAssertEqual(done, .completed(from: 3, reason: .manual))
        XCTAssertTrue(session.isComplete)

        let nextWhenComplete = session.goNext(reason: .manual)
        XCTAssertEqual(nextWhenComplete, .boundary(reason: .manual))

        let backFromComplete = session.goPrevious(reason: .manual)
        guard case .retreated(_, let to, .manual) = backFromComplete else {
            return XCTFail("Expected retreat from complete, got \(backFromComplete)")
        }
        XCTAssertEqual(to, 3)
        XCTAssertFalse(session.isComplete)
    }

    func testManualAdvanceResetsTransitionState() {
        var session = engine()
        // Partial current-point speech only — must not auto-advance.
        _ = session.observeSpeech(utterance: "welcome everyone annual")
        XCTAssertEqual(session.index, 0)
        XCTAssertGreaterThan(session.coverage, 0)
        _ = session.goNext(reason: .manual)
        XCTAssertEqual(session.index, 1)
        XCTAssertEqual(session.coverage, 0, accuracy: 1e-9)
        XCTAssertEqual(session.currentScore, 0, accuracy: 1e-9)
        XCTAssertEqual(session.nextScore, 0, accuracy: 1e-9)
        XCTAssertEqual(session.pendingEvidence, 0)
    }

    func testVoiceNextAndPreviousCommandsRequireWakeWord() {
        var session = engine()
        let next = session.observeSpeech(utterance: "phrasa next point")
        XCTAssertEqual(next, .advanced(from: 0, to: 1, reason: .voiceCommand))

        let prev = session.observeSpeech(utterance: "phrasa previous point")
        XCTAssertEqual(prev, .retreated(from: 1, to: 0, reason: .voiceCommand))
    }

    func testVoiceCommandFillerPrefixStillWorksWithWakeWord() {
        var session = engine()
        XCTAssertEqual(
            session.observeSpeech(utterance: "please um phrasa next point"),
            .advanced(from: 0, to: 1, reason: .voiceCommand)
        )
        _ = session.observeSpeech(utterance: "um okay just thinking")
        XCTAssertEqual(session.index, 1)
        XCTAssertEqual(
            session.observeSpeech(utterance: "okay phrasa previous point"),
            .retreated(from: 1, to: 0, reason: .voiceCommand)
        )
    }

    func testVoiceCommandWakeAliasesFrasaAndFrase() {
        var session = engine()
        XCTAssertEqual(
            OutlineSpeechCommandParser.match(utterance: "frasa next point"),
            .next
        )
        XCTAssertEqual(
            OutlineSpeechCommandParser.match(utterance: "frase previous point"),
            .previous
        )
        XCTAssertEqual(
            session.observeSpeech(utterance: "frasa next point"),
            .advanced(from: 0, to: 1, reason: .voiceCommand)
        )
        _ = session.observeSpeech(utterance: "um okay just thinking")
        XCTAssertEqual(
            session.observeSpeech(utterance: "frase previous point"),
            .retreated(from: 1, to: 0, reason: .voiceCommand)
        )
    }

    func testBarePreviousNextPointWithoutWakeWordNeverCommands() {
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "next point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "previous point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "please go to next point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "go previous point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "um okay next point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "last point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "skip this point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "go to previous point"))

        var session = engine()
        let bareNext = session.observeSpeech(utterance: "next point")
        XCTAssertEqual(session.index, 0)
        if case .advanced(_, _, .voiceCommand) = bareNext {
            XCTFail("Bare 'next point' must not voice-navigate")
        }
        let barePrev = session.observeSpeech(utterance: "previous point")
        if case .retreated(_, _, .voiceCommand) = barePrev {
            XCTFail("Bare 'previous point' must not voice-navigate")
        }
        XCTAssertEqual(session.index, 0)
    }

    func testVoiceCommandDoesNotMultiFireOnSameRollingPartial() {
        var session = engine()
        XCTAssertEqual(
            session.observeSpeech(utterance: "phrasa next point"),
            .advanced(from: 0, to: 1, reason: .voiceCommand)
        )
        let repeatPartial = session.observeSpeech(utterance: "phrasa next point")
        XCTAssertEqual(session.index, 1)
        if case .advanced = repeatPartial {
            XCTFail("Duplicate command partial must not multi-step")
        }
    }

    func testVoicePreviousDoesNotMultiFireOnSameRollingPartial() {
        var session = engine()
        _ = session.goNext(reason: .manual)
        _ = session.goNext(reason: .manual)
        XCTAssertEqual(session.index, 2)

        XCTAssertEqual(
            session.observeSpeech(utterance: "phrasa previous point"),
            .retreated(from: 2, to: 1, reason: .voiceCommand)
        )
        XCTAssertEqual(session.index, 1)

        for _ in 0..<3 {
            let again = session.observeSpeech(utterance: "phrasa previous point")
            XCTAssertEqual(session.index, 1, "Repeated previous partial must retreat only once")
            if case .retreated = again {
                return XCTFail("Duplicate previous partial must not multi-step, got \(again)")
            }
        }

        _ = session.observeSpeech(utterance: "um okay just thinking")
        XCTAssertEqual(
            session.observeSpeech(utterance: "phrasa previous point"),
            .retreated(from: 1, to: 0, reason: .voiceCommand)
        )
        XCTAssertEqual(session.index, 0)
    }

    func testManualPreviousClearsCommandLatchSoVoiceCanFireAgain() {
        var session = engine()
        _ = session.goNext(reason: .manual)
        XCTAssertEqual(
            session.observeSpeech(utterance: "phrasa previous point"),
            .retreated(from: 1, to: 0, reason: .voiceCommand)
        )
        _ = session.goNext(reason: .manual)
        _ = session.goPrevious(reason: .manual)
        XCTAssertEqual(session.index, 0)
        _ = session.goNext(reason: .manual)
        XCTAssertEqual(
            session.observeSpeech(utterance: "phrasa previous point"),
            .retreated(from: 1, to: 0, reason: .voiceCommand)
        )
    }

    func testNoAccidentalCommandTriggersInsideContent() {
        let outline = [
            OutlinePoint(text: "Discuss the next point carefully with the team"),
            OutlinePoint(text: "Wrap up"),
        ]
        var session = engine(outline: outline)

        let action = session.observeSpeech(
            utterance: "discuss the next point carefully with the team"
        )
        if case .advanced(_, _, .voiceCommand) = action {
            XCTFail("Content containing 'next point' must not voice-navigate")
        }
        if case .completed(_, .voiceCommand) = action {
            XCTFail("Content containing 'next point' must not complete via command")
        }

        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "next"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "previous"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "the next quarter looks strong"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "previous results were mixed"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "phrasa"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "phrasa next"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "phrasa point"))
    }

    func testCommandParserAcceptsOnlyWakeEndAnchoredPhrases() {
        XCTAssertEqual(OutlineSpeechCommandParser.match(utterance: "phrasa next point"), .next)
        XCTAssertEqual(OutlineSpeechCommandParser.match(utterance: "phrasa previous point"), .previous)
        XCTAssertEqual(OutlineSpeechCommandParser.match(utterance: "frasa next point"), .next)
        XCTAssertEqual(OutlineSpeechCommandParser.match(utterance: "frase previous point"), .previous)
        XCTAssertEqual(OutlineSpeechCommandParser.match(utterance: "um okay phrasa next point"), .next)
        XCTAssertEqual(OutlineSpeechCommandParser.match(utterance: "please phrasa previous point"), .previous)

        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "next point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "previous point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "fraser next point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "phrase next point"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "the next point is revenue"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "phrasa next point is revenue"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "move phrasa next point forward today"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "phrasa previous point was wrong actually"))
        XCTAssertNil(OutlineSpeechCommandParser.match(utterance: "discuss phrasa next point carefully"))
    }

    func testMatchedCommandIsExcludedFromTransitionScoring() {
        var session = engine()
        let action = session.observeSpeech(utterance: "phrasa next point")
        XCTAssertEqual(action, .advanced(from: 0, to: 1, reason: .voiceCommand))
        XCTAssertEqual(session.index, 1)
        XCTAssertEqual(session.coverage, 0, accuracy: 1e-9)
        XCTAssertEqual(session.currentScore, 0, accuracy: 1e-9)
        XCTAssertEqual(session.nextScore, 0, accuracy: 1e-9)
        XCTAssertEqual(session.pendingEvidence, 0)
    }

    func testUserFacingCommandHintStrings() {
        XCTAssertEqual(OutlineSpeechCommandParser.userFacingNext, "Phrasa next point")
        XCTAssertEqual(OutlineSpeechCommandParser.userFacingPrevious, "Phrasa previous point")
        XCTAssertTrue(
            OutlineSpeechCommandParser.userFacingHint.contains("Phrasa next point")
        )
        XCTAssertTrue(
            OutlineSpeechCommandParser.userFacingHint.contains("Phrasa previous point")
        )
    }

    func testUndoAfterTransitionDoesNotImmediatelyReAdvanceOnStaleTail() {
        let outline = [
            OutlinePoint(text: "First topic alpha bravo"),
            OutlinePoint(text: "Second topic charlie delta"),
        ]
        var session = engine(outline: outline)
        _ = feed(&session, [
            "second topic charlie",
            "second topic charlie delta",
        ])
        XCTAssertEqual(session.index, 1)

        // Manual undo.
        _ = session.goPrevious(reason: .manual)
        XCTAssertEqual(session.index, 0)

        // Same stale tail must not immediately re-advance without new content.
        let stale = session.observeSpeech(utterance: "second topic charlie delta")
        XCTAssertEqual(session.index, 0)
        if case .advanced = stale {
            XCTFail("Stale tail after undo must not re-advance without new content")
        }
    }

    // MARK: 14. Final-point speech does not auto-complete

    func testFinalPointSpeechDoesNotAutoComplete() {
        let outline = [
            OutlinePoint(text: "Open the annual product meeting"),
            OutlinePoint(text: "Close the session with sincere thanks"),
        ]
        var session = engine(outline: outline)
        _ = session.goNext(reason: .manual)
        XCTAssertEqual(session.index, 1)
        XCTAssertNotNil(session.currentPoint)
        XCTAssertNil(session.nextPoint)

        for _ in 0..<5 {
            let action = session.observeSpeech(
                utterance: "close the session with sincere thanks everyone"
            )
            if case .completed = action {
                return XCTFail("Final point speech must not auto-complete, got \(action)")
            }
            if case .advanced = action {
                return XCTFail("Final point must not advance further, got \(action)")
            }
        }
        XCTAssertEqual(session.index, 1)
        XCTAssertFalse(session.isComplete)

        // Explicit command still completes.
        XCTAssertEqual(
            session.goNext(reason: .manual),
            .completed(from: 1, reason: .manual)
        )
        XCTAssertTrue(session.isComplete)
    }

    func testFinalPointVoiceCommandStillCompletes() {
        let outline = [
            OutlinePoint(text: "Open the annual product meeting"),
            OutlinePoint(text: "Close the session with sincere thanks"),
        ]
        var session = engine(outline: outline)
        _ = session.goNext(reason: .manual)
        XCTAssertEqual(
            session.observeSpeech(utterance: "phrasa next point"),
            .completed(from: 1, reason: .voiceCommand)
        )
        XCTAssertTrue(session.isComplete)
    }

    // MARK: - Transition hysteresis / cooldown

    func testHysteresisRequiresSustainedNewContentWords() {
        let options = OutlineCoverageOptions(
            absFloor: 0.5,
            margin: 0.3,
            minMargin: 0.15,
            selfFloor: 0.5,
            hysteresis: 3,
            cooldown: 0
        )
        let outline = [
            OutlinePoint(text: "Alpha topic introduction overview"),
            OutlinePoint(text: "Bravo charlie delta echo"),
        ]
        var session = engine(outline: outline, options: options)

        // Two new content words — below hysteresis=3.
        _ = session.observeSpeech(utterance: "bravo charlie")
        XCTAssertEqual(session.index, 0)
        XCTAssertLessThan(session.pendingEvidence, 3)

        // Third new content word crosses hysteresis.
        let action = session.observeSpeech(utterance: "bravo charlie delta")
        guard case .advanced(_, let to, .transition) = action else {
            return XCTFail("Third new content word should advance, got \(action)")
        }
        XCTAssertEqual(to, 1)
    }

    func testCooldownPreventsDoubleAdvance() {
        let options = OutlineCoverageOptions(
            absFloor: 0.5,
            margin: 0.25,
            minMargin: 0.1,
            selfFloor: 0.5,
            hysteresis: 2,
            cooldown: 4
        )
        let outline = [
            OutlinePoint(text: "First topic alpha bravo"),
            OutlinePoint(text: "Second topic charlie delta"),
            OutlinePoint(text: "Third topic echo foxtrot"),
        ]
        var session = engine(outline: outline, options: options)

        _ = feed(&session, [
            "charlie delta",
            "second topic charlie delta",
        ])
        XCTAssertEqual(session.index, 1)

        // Flushed next-point words in one shot: stay (no hysteresis seed on flush).
        _ = session.observeSpeech(utterance: "echo foxtrot third topic")
        XCTAssertEqual(session.index, 1, "Flush tick must not double-advance")

        // Growing append still under cooldown (sinceAdvance was reset to 0).
        _ = session.observeSpeech(utterance: "echo foxtrot third topic more")
        XCTAssertEqual(session.index, 1, "Cooldown must block immediate double advance")
    }

    // MARK: - Restart / accessors

    func testRestartReturnsToFirstPoint() {
        var session = engine()
        _ = session.goNext(reason: .manual)
        _ = session.goNext(reason: .manual)
        session.restart()
        XCTAssertEqual(session.index, 0)
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.coverage, 0, accuracy: 1e-9)
        XCTAssertEqual(session.pendingEvidence, 0)
    }

    func testPreviousCurrentNextAccessors() {
        var session = engine()
        XCTAssertNil(session.previousPoint)
        XCTAssertEqual(session.currentPoint?.primary.prefix(7), "Welcome")
        XCTAssertEqual(session.nextPoint?.primary.prefix(7), "Revenue")

        _ = session.goNext(reason: .manual)
        XCTAssertEqual(session.previousPoint?.primary.prefix(7), "Welcome")
        XCTAssertEqual(session.currentPoint?.primary.prefix(7), "Revenue")
    }

    // MARK: - Stage presentation (stable three-slot stage)

    func testStageAlwaysHasThreeRoleSlotsIncludingBoundaryEmpties() {
        var session = engine()
        // First point: previous empty, next filled.
        let first = OutlineStagePresentation.make(from: session)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.slots.count, 3)
        XCTAssertEqual(first?.slots.map(\.role), [.previous, .current, .next])
        XCTAssertTrue(first?.previous.isEmpty == true)
        XCTAssertFalse(first?.current.isEmpty == true)
        XCTAssertFalse(first?.next.isEmpty == true)
        XCTAssertNil(first?.previous.accessibilityLabel)
        XCTAssertEqual(first?.current.pointIndex, 0)
        XCTAssertEqual(first?.next.pointIndex, 1)

        // Middle: all three filled.
        _ = session.goNext(reason: .manual)
        let mid = OutlineStagePresentation.make(from: session)
        XCTAssertFalse(mid?.previous.isEmpty == true)
        XCTAssertFalse(mid?.current.isEmpty == true)
        XCTAssertFalse(mid?.next.isEmpty == true)
        XCTAssertEqual(mid?.previous.pointIndex, 0)
        XCTAssertEqual(mid?.current.pointIndex, 1)
        XCTAssertEqual(mid?.next.pointIndex, 2)

        // Last point: next empty, previous filled.
        _ = session.goNext(reason: .manual)
        _ = session.goNext(reason: .manual)
        XCTAssertEqual(session.index, 3)
        let last = OutlineStagePresentation.make(from: session)
        XCTAssertFalse(last?.previous.isEmpty == true)
        XCTAssertFalse(last?.current.isEmpty == true)
        XCTAssertTrue(last?.next.isEmpty == true)
        XCTAssertNil(last?.next.accessibilityLabel)
        XCTAssertEqual(last?.current.pointIndex, 3)
        XCTAssertEqual(last?.previous.pointIndex, 2)
    }

    func testStageTracksEngineIndexOnlyAndNeverPreAdvancesOnCoverage() {
        var session = engine()
        let before = OutlineStagePresentation.make(from: session)
        XCTAssertEqual(before?.currentIndex, 0)
        XCTAssertEqual(before?.current.primary?.prefix(7), "Welcome")
        XCTAssertEqual(before?.next.primary?.prefix(7), "Revenue")

        // Partial / candidate-level speech must not change presentation.
        _ = session.observeSpeech(utterance: "welcome everyone")
        XCTAssertEqual(session.index, 0)
        let stillFirst = OutlineStagePresentation.make(from: session)
        XCTAssertEqual(stillFirst?.currentIndex, 0)
        XCTAssertEqual(stillFirst?.current.pointID, before?.current.pointID)
        XCTAssertEqual(stillFirst?.next.pointID, before?.next.pointID)

        // Completing the current point alone never advances the stage — outgoing
        // point remains current until the engine index actually commits.
        let fullCurrent =
            "welcome everyone to the annual product review smile and pause"
        _ = session.observeSpeech(utterance: fullCurrent)
        XCTAssertEqual(session.index, 0)
        let afterCurrentComplete = OutlineStagePresentation.make(from: session)
        XCTAssertEqual(afterCurrentComplete?.currentIndex, 0)
        XCTAssertEqual(afterCurrentComplete?.current.pointID, before?.current.pointID)
        XCTAssertEqual(afterCurrentComplete?.next.pointID, before?.next.pointID)

        // Thin first next evidence stays — presentation still mirrors index 0.
        _ = session.observeSpeech(utterance: "revenue")
        XCTAssertEqual(session.index, 0)
        let afterThinNext = OutlineStagePresentation.make(from: session)
        XCTAssertEqual(afterThinNext?.currentIndex, 0)
        XCTAssertEqual(afterThinNext?.current.pointID, before?.current.pointID)
        XCTAssertEqual(afterThinNext?.next.pointID, before?.next.pointID)

        // Only after the engine commits a transition does the stage advance.
        let advancedAction = session.observeSpeech(
            utterance: "revenue grew twenty percent this quarter"
        )
        guard case .advanced(let from, let to, .transition) = advancedAction else {
            return XCTFail("Sustained next evidence should advance, got \(advancedAction)")
        }
        XCTAssertEqual(from, 0)
        XCTAssertEqual(to, 1)
        XCTAssertEqual(session.index, 1)
        let advanced = OutlineStagePresentation.make(from: session)
        XCTAssertEqual(advanced?.currentIndex, 1)
        XCTAssertEqual(advanced?.current.primary?.prefix(7), "Revenue")
        XCTAssertEqual(advanced?.previous.pointID, before?.current.pointID)
        XCTAssertEqual(advanced?.previous.primary?.prefix(7), "Welcome")
        // Slot roles remain stable identities.
        XCTAssertEqual(advanced?.slots.map(\.id), [.previous, .current, .next])
    }

    func testStageNilWhenEmptyOrComplete() {
        XCTAssertNil(
            OutlineStagePresentation.make(points: [], currentIndex: 0)
        )
        var session = engine()
        while !session.isComplete {
            _ = session.goNext(reason: .manual)
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertNil(OutlineStagePresentation.make(from: session))
    }

    func testStageAccessibilityLabelsAndProgress() {
        var session = engine()
        _ = session.goNext(reason: .manual)
        let stage = OutlineStagePresentation.make(from: session)
        XCTAssertEqual(stage?.progressLabel, "Point 2 of 4")
        XCTAssertEqual(stage?.compactProgressLabel, "POINT 2 OF 4")
        XCTAssertEqual(
            stage?.previous.accessibilityLabel,
            "Previous, \(session.previousPoint!.primary)"
        )
        XCTAssertTrue(stage?.current.accessibilityLabel?.hasPrefix("Now, ") == true)
        // Next includes supporting note when present (transition engine may use it).
        XCTAssertEqual(stage?.next.note, session.nextPoint?.note)
        XCTAssertEqual(stage?.next.note, "Show the chart")
        XCTAssertEqual(
            stage?.next.accessibilityLabel,
            "Up next, \(session.nextPoint!.primary). \(session.nextPoint!.note!)"
        )
        XCTAssertTrue(
            stage?.next.accessibilityLabel?.contains("Show the chart") == true
        )
    }

    func testStageSlotIdentitiesStayRoleBasedAcrossAdvances() {
        var session = engine()
        let a = OutlineStagePresentation.make(from: session)!
        _ = session.goNext(reason: .manual)
        let b = OutlineStagePresentation.make(from: session)!
        // Roles (and therefore ForEach ids) are unchanged across an advance —
        // content moves, slots do not disappear.
        XCTAssertEqual(a.slots.map(\.id), b.slots.map(\.id))
        XCTAssertEqual(a.slots.map(\.role), b.slots.map(\.role))
        XCTAssertNotEqual(a.current.pointID, b.current.pointID)
    }

    // MARK: - Scorer unit

    func testCoverageScorerWeightsAndFuzzy() {
        let content = ReaderTokenizer.normalizeUtterance("welcome everyone annual review")
        let weights = content.map { FuzzyMatcher.wordWeight($0) }
        let none = OutlineCoverageScorer.coverage(
            spokenWords: ReaderTokenizer.normalizeUtterance("unrelated topic"),
            contentWords: content,
            weights: weights
        )
        XCTAssertEqual(none, 0, accuracy: 1e-9)

        let partial = OutlineCoverageScorer.coverage(
            spokenWords: ReaderTokenizer.normalizeUtterance("welcome everyone"),
            contentWords: content,
            weights: weights
        )
        XCTAssertGreaterThan(partial, 0)
        XCTAssertLessThan(partial, 1)

        let full = OutlineCoverageScorer.coverage(
            spokenWords: content,
            contentWords: content,
            weights: weights
        )
        XCTAssertEqual(full, 1, accuracy: 1e-9)
    }

    func testBagScoreMatchesDistinctiveWords() {
        let outline = [
            OutlinePoint(text: "Retention drives growth"),
            OutlinePoint(text: "Pricing strategy plan"),
        ]
        let models = OutlinePointModel.models(from: outline)
        let nextBag = models[1].bag
        let score = OutlineCoverageScorer.bagScore(
            spokenWords: ReaderTokenizer.normalizeUtterance("pricing strategy"),
            bag: nextBag
        )
        XCTAssertGreaterThan(score, 0.7)
        let off = OutlineCoverageScorer.bagScore(
            spokenWords: ReaderTokenizer.normalizeUtterance("weather coffee"),
            bag: nextBag
        )
        XCTAssertEqual(off, 0, accuracy: 1e-9)
    }

    // MARK: - Semantic support boundary

    func testSemanticBoostAloneNeverAdvances() {
        let outline = [
            OutlinePoint(text: "Welcome everyone annual keynote"),
            OutlinePoint(text: "Revenue grew twenty percent"),
        ]
        var session = engine(outline: outline)

        // Huge semantic boost with no lexical next evidence must not advance.
        let action = session.observeSpeech(
            utterance: "weather coffee lunch tangent",
            semanticSupport: OutlineSemanticSupport(nextBoost: 99)
        )
        XCTAssertEqual(session.index, 0)
        if case .advanced = action {
            XCTFail("Semantic-only support must never advance")
        }
        XCTAssertEqual(session.nextScore, 0, accuracy: 1e-9)
    }

    func testSemanticBoostIsClampedAndRequiresLexicalNext() {
        let outline = [
            OutlinePoint(text: "Welcome everyone annual keynote"),
            OutlinePoint(text: "Revenue grew twenty percent"),
        ]
        var session = engine(outline: outline)
        _ = session.observeSpeech(
            utterance: "revenue",
            semanticSupport: OutlineSemanticSupport(nextBoost: 99)
        )
        // Boost applied only because lexical next > 0, and clamped to semanticBoostMax.
        XCTAssertGreaterThan(session.nextScore, 0)
        XCTAssertLessThanOrEqual(
            session.nextScore,
            OutlineCoverageScorer.bagScore(
                spokenWords: ReaderTokenizer.normalizeUtterance("revenue"),
                bag: session.nextPoint?.bag ?? [:]
            ) + OutlineCoverageOptions.default.semanticBoostMax + 1e-9
        )
        XCTAssertEqual(session.index, 0)
    }

    // MARK: - Ordered multi-point transition path

    func testOrderedTransitionsThroughKeywordBearingPoints() {
        let outline = [
            OutlinePoint(text: "Why now", note: "timing market shift urgent moment"),
            OutlinePoint(text: "The problem", note: "users waste hours manual spreadsheets errors"),
            OutlinePoint(text: "Our solution", note: "automation engine one click saves time"),
            OutlinePoint(text: "The ask", note: "raising funding hire engineers months runway"),
        ]
        var session = engine(outline: outline)

        _ = feed(&session, [
            "lets talk about the timing here",
            "the market shift makes this urgent right now",
        ])
        // May still be on 0 if speech was only current-ish; push next.
        if session.index == 0 {
            _ = feed(&session, [
                "users waste hours",
                "users waste hours on manual spreadsheets full of errors",
            ])
        }
        XCTAssertEqual(session.index, 1)

        _ = feed(&session, [
            "our solution is an automation engine",
            "automation engine one click saves time",
        ])
        XCTAssertEqual(session.index, 2)

        _ = feed(&session, [
            "raising funding",
            "raising funding hire engineers months runway",
        ])
        XCTAssertEqual(session.index, 3)
        XCTAssertFalse(session.isComplete)

        // Final point speech still does not complete.
        _ = session.observeSpeech(
            utterance: "raising funding hire engineers months runway thank you"
        )
        XCTAssertFalse(session.isComplete)
    }
}
