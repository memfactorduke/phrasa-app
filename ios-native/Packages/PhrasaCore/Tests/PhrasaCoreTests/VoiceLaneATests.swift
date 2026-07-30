import XCTest
@testable import PhrasaCore

/// Voice Lane A: digit identity, partial transcripts, choruses, long skips,
/// large repetitive scripts, reseat, and hot-path bounds.
final class VoiceLaneATests: XCTestCase {

    // MARK: - Digits

    func testDigitBearingTokensDoNotFuzzyMatch() {
        let pairs = [
            ("chapter2", "chapter3"),
            ("covid19", "covid20"),
            ("room2", "room3"),
            ("2024", "2025"),
            ("v1", "v2"),
        ]
        for (lhs, rhs) in pairs {
            XCTAssertFalse(
                FuzzyMatcher.wordsSimilar(lhs, rhs),
                "Expected \(lhs) and \(rhs) not to fuzzy-match"
            )
            XCTAssertTrue(FuzzyMatcher.wordsSimilar(lhs, lhs))
        }
    }

    func testNormalizationPreservesDigitsInCompositeTokens() {
        XCTAssertEqual(ReaderTokenizer.normalizeWord("Chapter-2,"), "chapter2")
        XCTAssertEqual(ReaderTokenizer.normalizeWord("COVID-19!"), "covid19")
        XCTAssertEqual(ReaderTokenizer.normalizeUtterance("see chapter2 then chapter3"), [
            "see", "chapter2", "then", "chapter3",
        ])
    }

    func testAlignmentDoesNotConfuseDigitNeighbors() {
        let script = "please open chapter2 of the handbook then skip to chapter3 carefully"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let chapter2Index = words.firstIndex(of: "chapter2")!
        let chapter3Index = words.firstIndex(of: "chapter3")!
        let engine = AlignmentEngine(script: script)

        // Read through the chapter2 phrase exactly.
        var buffer: [String] = []
        var last = -1
        for word in words.prefix(chapter2Index + 1) {
            buffer.append(word)
            last = engine.observe(buffer).cursor
        }
        XCTAssertEqual(last, chapter2Index)

        // A misheard "chapter3" while still near chapter2 must not leap to chapter3.
        buffer = ["open", "chapter3", "of", "the"]
        let confused = engine.observe(buffer)
        if confused.accepted {
            XCTAssertNotEqual(confused.cursor, chapter3Index)
            XCTAssertLessThan(confused.cursor, chapter3Index)
        } else {
            XCTAssertLessThan(engine.cursorIndex, chapter3Index)
        }
    }

    // MARK: - Cumulative partial transcripts & prefix rewrites

    func testCumulativePartialTranscriptSnapshotsAdvanceMonotonically() {
        let script =
            "welcome friends today we practice steady reading with partial results " +
            "arriving one word at a time until the sentence is complete"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let engine = AlignmentEngine(script: script)

        // Simulate speech partials: growing cumulative transcript (full history each step).
        var cumulative: [String] = []
        var cursors: [Int] = []
        for word in words {
            cumulative.append(word)
            // Feed the full cumulative snapshot (not only a rolling tail).
            cursors.append(engine.observe(cumulative).cursor)
        }

        XCTAssertEqual(cursors.last, words.count - 1)
        XCTAssertTrue(isNondecreasing(cursors.filter { $0 >= 0 }))
        let accurate = zip(cursors.indices, cursors).filter { abs($0 - $1) <= 2 }.count
        XCTAssertGreaterThan(Double(accurate) / Double(cursors.count), 0.90)
    }

    func testCumulativeSnapshotsDoNotLeapOnDuplicateTailBias() {
        // Script with a repeated tail phrase. Full cumulative observations must
        // stay on the first occurrence via continuity (cursor+1), not probe-length lookahead.
        let head = "once upon a quiet morning the narrator begins "
        let refrain = "and so the story goes on "
        let script = head + refrain + "middle bridge material here " + refrain + "closing line"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let engine = AlignmentEngine(script: script)

        var cumulative: [String] = []
        var maxCursor = -1
        // Speak only through the first refrain (no bridge yet).
        let firstRefrainEnd = ReaderTokenizer.normalizeUtterance(head + refrain).count - 1
        for word in words.prefix(firstRefrainEnd + 1) {
            cumulative.append(word)
            let result = engine.observe(cumulative)
            maxCursor = max(maxCursor, result.cursor)
        }

        // Still on / near the first refrain; must not jump to the second copy.
        let secondRefrainStart = words.count - ReaderTokenizer.normalizeUtterance(refrain + "closing line").count
        XCTAssertLessThan(
            engine.cursorIndex,
            secondRefrainStart - 2,
            "cumulative probe must not bias into the later identical refrain"
        )
        XCTAssertGreaterThanOrEqual(engine.cursorIndex, firstRefrainEnd - 3)
        XCTAssertEqual(maxCursor, engine.cursorIndex)
    }

    func testPrefixRewriteCorrectionDoesNotBreakTracking() {
        let script = "the quick brown fox jumps over the lazy dog near the river bank"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let engine = AlignmentEngine(script: script)

        // Partial says "quiet" then rewrites to "quick" (ASR correction).
        let snapshots: [[String]] = [
            ["the"],
            ["the", "quiet"],
            ["the", "quick"],
            ["the", "quick", "brown"],
            ["the", "quick", "brown", "fox"],
            ["the", "quick", "brown", "fox", "jumps"],
            Array(words.prefix(8)),
            Array(words.prefix(10)),
            words,
        ]

        var last = -1
        var acceptedCursors: [Int] = []
        for snap in snapshots {
            let result = engine.observe(snap)
            if result.accepted {
                last = result.cursor
                acceptedCursors.append(result.cursor)
            }
        }
        XCTAssertGreaterThanOrEqual(last, words.count - 3)
        // After the rewrite, tracking should keep making forward progress.
        XCTAssertTrue(isNondecreasing(acceptedCursors.filter { $0 >= 0 }))
    }

    func testPrefixRewriteMidStreamRecoversWithoutBackwardFreeFall() {
        let script =
            "alpha bravo charlie delta echo foxtrot golf hotel india juliet " +
            "kilo lima mike november oscar papa"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let engine = AlignmentEngine(script: script)

        // Establish solid lock through "echo".
        let cumulative = Array(words.prefix(5))
        _ = engine.observe(cumulative)
        let established = engine.cursorIndex
        XCTAssertGreaterThanOrEqual(established, 3)

        // ASR rewrites the last content word, then grows correctly again.
        let rewrites: [[String]] = [
            Array(words.prefix(4)) + ["ecko"],           // mis-hear
            Array(words.prefix(5)),                      // corrected to echo
            Array(words.prefix(7)),
            Array(words.prefix(10)),
            Array(words.prefix(14)),
        ]
        var cursors: [Int] = [established]
        for snap in rewrites {
            cursors.append(engine.observe(snap).cursor)
        }
        XCTAssertGreaterThanOrEqual(cursors.last!, words.count - 4)
        // Cursor may stall on a bad partial but must not collapse toward zero.
        XCTAssertTrue(cursors.allSatisfy { $0 >= established - 2 || $0 < 0 })
    }

    // MARK: - Repeated choruses / local competitive ambiguity

    func testRepeatedChorusDoesNotRunAwayAcrossCopies() {
        let verse = "shine bright tonight we sing together "
        let chorus = "la la la we love this song "
        let script = verse + chorus + verse + chorus + "final bow and goodnight everyone"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let engine = AlignmentEngine(script: script)

        // Speak first verse + first chorus + second verse start (unique "final" not yet).
        let spoken = Array(words.prefix(14))
        var buffer: [String] = []
        var cursors: [Int] = []
        for word in spoken {
            buffer.append(word)
            if buffer.count > 8 { buffer.removeFirst() }
            cursors.append(engine.observe(buffer).cursor)
        }

        // Should remain in the first half, not leap to the second chorus copy.
        let final = cursors.last!
        XCTAssertLessThan(final, words.count / 2 + 4)
        XCTAssertTrue(isNondecreasing(cursors.filter { $0 >= 0 }))
    }

    func testIdenticalChorusWithinMaxJumpIsNotAcceptedWithoutCluster() {
        // Chorus sits ~10 words ahead — inside default maxJump (20) — so only
        // multi-word competitive-hit protection (not the long-leap gate) can stop it.
        let lead = (0..<8).map { "lead\($0)" }.joined(separator: " ")
        let chorus = "we love this chorus line forever"
        let mid = (0..<6).map { "mid\($0)" }.joined(separator: " ")
        let script = "\(lead) \(chorus) \(mid) \(chorus) unique_tail_word"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let chorusWords = ReaderTokenizer.normalizeUtterance(chorus)
        let engine = AlignmentEngine(script: script)

        // Lock onto the first lead tokens.
        var buffer: [String] = []
        for word in words.prefix(4) {
            buffer.append(word)
            _ = engine.observe(buffer)
        }
        let locked = engine.cursorIndex
        XCTAssertGreaterThanOrEqual(locked, 2)
        XCTAssertLessThan(locked, 8)

        let firstChorusEnd = 8 + chorusWords.count - 1
        let secondChorusEnd = words.count - 2 // before unique_tail_word

        // Fire the same chorus probe many times (identical repeated callbacks).
        var leapedToSecond = false
        for _ in 0..<12 {
            let result = engine.observe(chorusWords)
            if result.accepted, result.cursor >= secondChorusEnd - 2 {
                leapedToSecond = true
                break
            }
        }

        XCTAssertFalse(
            leapedToSecond,
            "identical in-window chorus must not leap to the second copy; cursor=\(engine.cursorIndex)"
        )
        // May lock the *first* chorus (clustered / nearer) or stay put — never the far twin.
        XCTAssertLessThanOrEqual(engine.cursorIndex, firstChorusEnd + 1)
    }

    func testRepeatedIdenticalCallbacksDoNotAccumulateUnsafeLeap() {
        let script =
            "intro one two three " +
            "repeat me now please friends " +
            "bridge material unique here " +
            "repeat me now please friends " +
            "outro done"
        let words = ReaderTokenizer.normalizeUtterance(script)
        let engine = AlignmentEngine(script: script)
        let phrase = ReaderTokenizer.normalizeUtterance("repeat me now please friends")

        // Establish at intro.
        _ = engine.observe(Array(words.prefix(4)))
        let startCursor = engine.cursorIndex

        // Same recognition callback 20 times in a row.
        var cursors: [Int] = []
        for _ in 0..<20 {
            cursors.append(engine.observe(phrase).cursor)
        }

        let secondCopyStart = words.firstIndex(of: "bridge")! + 3 // after bridge material...
        // Find second "repeat"
        let secondRepeat = words.enumerated().filter { $0.element == "repeat" }.map(\.offset)
        XCTAssertEqual(secondRepeat.count, 2)
        let farCopy = secondRepeat[1]

        XCTAssertTrue(
            cursors.allSatisfy { $0 < farCopy },
            "repeated identical callbacks must not walk the cursor to the far chorus copy"
        )
        // If we advanced, it should only be toward the *first* phrase.
        if let last = cursors.last, last > startCursor {
            XCTAssertLessThanOrEqual(last, secondRepeat[0] + phrase.count)
        }
        _ = secondCopyStart
    }

    // MARK: - Unique long skip

    func testUniqueSkipOfAtLeastSixtyWordsReanchors() {
        var parts: [String] = []
        for index in 0..<120 {
            // Mostly unique tokens so the destination is unambiguous.
            parts.append("token\(index)")
        }
        let script = parts.joined(separator: " ")
        let words = ReaderTokenizer.normalizeUtterance(script)
        XCTAssertGreaterThanOrEqual(words.count, 120)

        let engine = AlignmentEngine(script: script)
        var buffer: [String] = []

        // Establish near the start.
        for word in words.prefix(5) {
            buffer.append(word)
            _ = engine.observe(buffer)
        }
        XCTAssertLessThan(engine.cursorIndex, 10)

        // Skip ≥ 60 unique words; feed destination phrase until reanchor accepts.
        let destinationStart = 70
        XCTAssertGreaterThanOrEqual(destinationStart - engine.cursorIndex, 60)
        let destination = Array(words[destinationStart..<(destinationStart + 8)])

        var landed = false
        var lastCursor = engine.cursorIndex
        var reanchored = false
        // Include a few garbage observations so miss streak triggers reanchor.
        let spoken = Array(repeating: ["zzzz", "qqqq", "vvvv", "nnnn"], count: 2).flatMap { $0 } + destination
        buffer = Array(words.prefix(4))
        for word in spoken {
            buffer.append(word)
            if buffer.count > 8 { buffer.removeFirst() }
            let result = engine.observe(buffer)
            lastCursor = result.cursor
            if result.reanchored { reanchored = true }
            if result.accepted, lastCursor >= destinationStart - 2 {
                landed = true
                break
            }
        }

        XCTAssertTrue(landed, "expected reanchor near unique skip destination, cursor=\(lastCursor)")
        XCTAssertGreaterThanOrEqual(lastCursor, destinationStart - 2)
        XCTAssertTrue(reanchored || lastCursor >= destinationStart - 2)
        print("SKIP60 landed cursor=\(lastCursor) reanchored=\(reanchored) dest=\(destinationStart)")
    }

    func testUniqueSkipBeyondWindowUsesBoundedGlobalSearch() {
        let words = (0..<200).map { "uniq\($0)" }
        let script = words.joined(separator: " ")
        let engine = AlignmentEngine(script: script)

        for word in words.prefix(3) {
            _ = engine.observe([word])
        }

        let dest = 90
        XCTAssertGreaterThanOrEqual(dest - max(engine.cursorIndex, 0), 60)
        let destination = Array(words[dest..<(dest + 6)])
        let garbage = ["nope", "miss", "wrong", "away", "nope", "miss", "wrong", "away"]
        var buffer: [String] = Array(words.prefix(3))
        var maxScored = 0
        var landed = false

        for word in garbage + destination {
            buffer.append(word)
            if buffer.count > 6 { buffer.removeFirst() }
            let result = engine.observe(buffer)
            maxScored = max(maxScored, engine.lastSearchStats.positionsScored)
            if result.accepted, result.cursor >= dest - 2 {
                landed = true
                break
            }
        }

        XCTAssertTrue(landed, "60+ unique skip should reanchor, cursor=\(engine.cursorIndex)")
        // Global reanchor is budget-capped (default 1500); local window is tiny.
        XCTAssertLessThanOrEqual(maxScored, 1_600)
        print("SKIP60_BOUNDED max_scored=\(maxScored) cursor=\(engine.cursorIndex)")
    }

    // MARK: - Manual reseat

    func testManualReseatRecentersAlignmentWindow() {
        let script = (0..<80).map { "word\($0)" }.joined(separator: " ")
        let words = ReaderTokenizer.normalizeUtterance(script)
        let engine = AlignmentEngine(script: script)
        var buffer: [String] = []
        for word in words.prefix(20) {
            buffer.append(word)
            if buffer.count > 8 { buffer.removeFirst() }
            _ = engine.observe(buffer)
        }
        XCTAssertGreaterThan(engine.cursorIndex, 10)

        engine.reset(tokenIndex: 5)
        XCTAssertEqual(engine.cursorIndex, 5)

        let resumed = engine.observe(Array(words[6..<10]))
        XCTAssertTrue(resumed.accepted)
        XCTAssertEqual(resumed.cursor, 9)
        XCTAssertEqual(resumed.missStreak, 0)
    }

    // MARK: - Large repetitive scripts (3k–10k) + search bounds

    func testRepetitiveScriptThreeThousandWordsHotPathBounded() {
        measureRepetitiveScript(wordCount: 3_000, spokenPrefix: 150)
    }

    func testRepetitiveScriptTenThousandWordsHotPathBounded() {
        measureRepetitiveScript(wordCount: 10_000, spokenPrefix: 120)
    }

    func testLocalWindowSearchBoundIsIndependentOfScriptLength() {
        let short = makeRepetitiveScript(wordCount: 500)
        let long = makeRepetitiveScript(wordCount: 8_000)
        let shortEngine = AlignmentEngine(script: short)
        let longEngine = AlignmentEngine(script: long)

        let spokenShort = ReaderTokenizer.normalizeUtterance(short).prefix(40)
        let spokenLong = ReaderTokenizer.normalizeUtterance(long).prefix(40)

        var buffer: [String] = []
        var shortMax = 0
        for word in spokenShort {
            buffer.append(word)
            if buffer.count > 4 { buffer.removeFirst(buffer.count - 4) }
            _ = shortEngine.observe(buffer)
            shortMax = max(shortMax, shortEngine.lastSearchStats.positionsScored)
        }

        buffer.removeAll()
        var longMax = 0
        for word in spokenLong {
            buffer.append(word)
            if buffer.count > 4 { buffer.removeFirst(buffer.count - 4) }
            _ = longEngine.observe(buffer)
            longMax = max(longMax, longEngine.lastSearchStats.positionsScored)
        }

        // Local window: windowBack + windowForward + probe ≈ 10+45+4 = 59, plus margins.
        XCTAssertLessThanOrEqual(shortMax, 80)
        XCTAssertLessThanOrEqual(longMax, 80)
        // Hot path positions scored must not grow with script length.
        XCTAssertEqual(shortMax, longMax)
        print("BOUNDS local_window shortMax=\(shortMax) longMax=\(longMax)")
    }

    // MARK: - Helpers

    private func makeRepetitiveScript(wordCount: Int) -> String {
        // High repetition (chorus-like) with occasional unique anchors.
        let chorus = ["we", "sing", "the", "same", "bright", "chorus", "again"]
        var parts: [String] = []
        parts.reserveCapacity(wordCount)
        for index in 0..<wordCount {
            if index % 97 == 0 {
                parts.append("anchor\(index)")
            } else {
                parts.append(chorus[index % chorus.count])
            }
        }
        return parts.joined(separator: " ")
    }

    private func measureRepetitiveScript(wordCount: Int, spokenPrefix: Int) {
        let script = makeRepetitiveScript(wordCount: wordCount)
        let words = ReaderTokenizer.normalizeUtterance(script)
        XCTAssertGreaterThanOrEqual(words.count, wordCount - 5)

        let engine = AlignmentEngine(script: script)
        let spoken = Array(words.prefix(spokenPrefix))

        var buffer: [String] = []
        var stepScores: [Int] = []
        var cursors: [Int] = []
        let started = CFAbsoluteTimeGetCurrent()

        for word in spoken {
            buffer.append(word)
            if buffer.count > 6 { buffer.removeFirst() }
            let result = engine.observe(buffer)
            stepScores.append(engine.lastSearchStats.positionsScored)
            cursors.append(result.cursor)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let sorted = stepScores.sorted()
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        let p95 = sorted[p95Index]
        let maxScored = sorted.last ?? 0

        // Correctness: should advance through repetitive material without free-fall.
        XCTAssertGreaterThan(cursors.last ?? -1, spokenPrefix / 4)
        XCTAssertTrue(isNondecreasing(cursors.filter { $0 >= 0 }))

        // Search bound: local path ≤ ~window size; reanchor path ≤ budget.
        XCTAssertLessThanOrEqual(p95, 80, "p95 positions scored too high: \(p95)")
        XCTAssertLessThanOrEqual(maxScored, 1_600)

        // Wall clock only as pathological guard (CI-stable multi-second ceiling).
        XCTAssertLessThan(elapsed, 5.0, "hot path stalled on \(wordCount) words (\(elapsed)s)")

        print(
            String(
                format: "PERF repetitive_%d words steps=%d p95_scored=%d max_scored=%d elapsed_ms=%.2f cursor=%d",
                wordCount,
                spokenPrefix,
                p95,
                maxScored,
                elapsed * 1_000,
                cursors.last ?? -1
            )
        )
    }
}
