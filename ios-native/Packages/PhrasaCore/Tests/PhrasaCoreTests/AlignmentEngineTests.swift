import XCTest
@testable import PhrasaCore

final class AlignmentEngineTests: XCTestCase {
    private let script =
        "welcome to phrasa the teleprompter that reads along with you " +
        "when you speak the words rise to meet you one line at a time " +
        "always centered and always in focus there is no clicker to press " +
        "and no pace to fight you simply talk and the script keeps up " +
        "whether recording a podcast filming a video or rehearsing a speech " +
        "your delivery stays natural because your eyes never leave the lens"

    private var words: [String] { ReaderTokenizer.normalizeUtterance(script) }

    func testPerfectReadingTracksToEndWithoutMovingBackward() {
        let cursors = simulate(spoken: words, script: script).cursors
        XCTAssertEqual(cursors.last, words.count - 1)
        XCTAssertTrue(isNondecreasing(cursors))

        let accurate = cursors.enumerated().filter { abs($0.offset - $0.element) <= 2 }.count
        XCTAssertGreaterThan(Double(accurate) / Double(cursors.count), 0.95)
    }

    func testMisrecognitionsStillReachTheEnd() {
        let spoken = words.enumerated().map { index, word in
            if word == "to" { return "too" }
            if word == "reads" { return "reeds" }
            if word == "teleprompter" { return "telepromter" }
            if index == 10 { return String(word.dropLast()) }
            return word
        }
        XCTAssertGreaterThanOrEqual(simulate(spoken: spoken, script: script).cursors.last!, words.count - 2)
    }

    func testSkippedSectionJumpsForward() {
        let spoken = Array(words.prefix(6)) + Array(words[30..<40])
        let final = simulate(spoken: spoken, script: script).cursors.last!
        XCTAssertTrue((36...40).contains(final))
    }

    func testRepeatedLineDoesNotRunAway() {
        let spoken = Array(words[0..<12]) + Array(words[6..<12]) + Array(words[12..<20])
        let final = simulate(spoken: spoken, script: script).cursors.last!
        XCTAssertTrue((18...20).contains(final))
    }

    func testOffScriptFillersHoldThenRealWordsAdvance() {
        var spoken: [String] = []
        for (index, word) in words.prefix(20).enumerated() {
            spoken.append(word)
            if index.isMultiple(of: 4) { spoken.append(contentsOf: ["um", "uh", "basically"]) }
        }
        let final = simulate(spoken: spoken, script: script).cursors.last!
        XCTAssertTrue((18...20).contains(final))
    }

    func testSilenceThenResumeRecovers() {
        let spoken = Array(words[0..<10]) + Array(words[18..<28])
        let final = simulate(spoken: spoken, script: script).cursors.last!
        XCTAssertTrue((24...28).contains(final))
    }

    func testGlobalReanchorRecoversFarForwardAndBackward() {
        let longWords = ReaderTokenizer.normalizeUtterance(Self.longScript)
        XCTAssertGreaterThan(longWords.count, 80)

        let forward = Array(longWords.prefix(5)) + Array(longWords.dropFirst(70))
        XCTAssertGreaterThanOrEqual(
            simulate(spoken: forward, script: Self.longScript).cursors.last!,
            longWords.count - 5
        )

        let backward = Array(longWords.prefix(40)) + Array(longWords[5..<25])
        XCTAssertTrue(
            (18...28).contains(simulate(spoken: backward, script: Self.longScript).cursors.last!)
        )
    }

    func testThrottledGlobalScanKeepsRetrying() {
        let longWords = ReaderTokenizer.normalizeUtterance(Self.longScript)
        let options = AlignmentOptions(reanchorScanBudget: 20)
        let engine = AlignmentEngine(script: Self.longScript, options: options)
        let garbage = ["frobnicate", "wibblewobble", "gribbleflux", "quuxbaz"]
        let spoken = Array(longWords.prefix(5)) + garbage + garbage + garbage + Array(longWords.dropFirst(70))
        var buffer: [String] = []
        var final = -1
        for word in spoken {
            buffer.append(word)
            if buffer.count > 12 { buffer.removeFirst() }
            final = engine.observe(buffer).cursor
        }
        XCTAssertGreaterThanOrEqual(final, longWords.count - 5)
    }

    func testGarbageDoesNotMoveCursorAndMissStreakClimbs() {
        let engine = AlignmentEngine(script: script)
        let initial = engine.observe(["xqzzy", "frobnicate", "wibble"])
        XCTAssertFalse(initial.moved)
        XCTAssertEqual(initial.cursor, -1)

        _ = engine.observe(Array(words.prefix(4)))
        let firstMiss = engine.observe(["xqzzy"]).missStreak
        var last = engine.observe(["frobnicate", "wibblezorp"])
        for _ in 0..<4 { last = engine.observe(["frobnicate", "wibblezorp"]) }
        XCTAssertFalse(last.accepted)
        XCTAssertGreaterThan(last.missStreak, firstMiss)
    }

    func testResetReseatsWindowForManualCorrection() {
        let result = simulate(spoken: Array(words.prefix(14)), script: script)
        XCTAssertGreaterThan(result.engine.cursorIndex, 8)
        result.engine.reset(tokenIndex: 3)
        XCTAssertEqual(result.engine.cursorIndex, 3)
        let corrected = result.engine.observe(Array(words[4..<8]))
        XCTAssertTrue(corrected.accepted)
        XCTAssertEqual(corrected.cursor, 7)
        XCTAssertEqual(corrected.missStreak, 0)

        result.engine.reset()
        XCTAssertEqual(result.engine.cursorIndex, -1)
    }

    func testEmptyAndPunctuationOnlyScriptsAreSafe() {
        let engine = AlignmentEngine(script: "... 😀 —")
        XCTAssertEqual(engine.matchableCount, 0)
        XCTAssertEqual(engine.observe(["hello"]).cursor, -1)
        XCTAssertEqual(engine.observe([]).tokenIndex, 0)
    }

    private static let longScript =
        "the morning fog still clung to the harbor when the old fisherman untied " +
        "his weathered boat and rowed quietly past the sleeping yachts toward the " +
        "open water where the gulls were already circling above a silver flash of " +
        "herring he had learned patience from his father who learned it from his " +
        "own father and the sea rewarded those who waited without complaint by noon " +
        "the nets were heavy and the sun had burned the mist away leaving the " +
        "coastline sharp and bright against a blue that seemed to stretch forever " +
        "into the distant restless horizon"
}
