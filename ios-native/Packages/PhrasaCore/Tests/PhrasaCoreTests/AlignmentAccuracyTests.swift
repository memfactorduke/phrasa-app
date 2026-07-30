import XCTest
@testable import PhrasaCore

final class AlignmentAccuracyTests: XCTestCase {
    private static let script = """
    Good evening, and thank you for being here. Tonight I want to share a story
    about persistence, about the quiet work that happens long before anyone is
    watching. Every overnight success is built on years of unglamorous practice.
    The musician runs scales. The writer fills notebooks nobody will ever read.
    The athlete trains in an empty gym while the world is still asleep. What looks
    like talent from a distance is usually just patience worn smooth by repetition.
    So when you feel stuck, remember that progress is rarely loud. It is the sum of
    small, deliberate choices, made again and again, until one day the work speaks
    for itself and the room finally leans in to listen.
    """

    private static let seeds: [UInt32] = [1, 7, 42, 99, 2_024]

    func testCleanRecognitionExceedsNinetySevenPercent() {
        XCTAssertGreaterThan(averageAccuracy(errorRate: 0), 0.97)
    }

    func testFivePercentErrorsExceedNinetyTwoPercent() {
        XCTAssertGreaterThan(averageAccuracy(errorRate: 0.05), 0.92)
    }

    func testFifteenPercentErrorsExceedEightyFivePercent() {
        XCTAssertGreaterThan(averageAccuracy(errorRate: 0.15), 0.85)
    }

    func testThirtyPercentErrorsDegradeGracefully() {
        XCTAssertGreaterThan(averageAccuracy(errorRate: 0.30), 0.70)
    }

    func testFillersAdlibsAndErrorsExceedEightyFivePercent() {
        let words = ReaderTokenizer.normalizeUtterance(Self.script)
        let scores = [3, 17, 64, 128, 777].map { seed in
            let reading = generateReadingWithTruth(
                words: words,
                errorRate: 0.10,
                fillerRate: 0.18,
                insertionRate: 0.08,
                seed: UInt32(seed)
            )
            let engine = AlignmentEngine(script: Self.script)
            var buffer: [String] = []
            var accurate = 0
            for index in reading.spoken.indices {
                buffer.append(reading.spoken[index])
                if buffer.count > 12 { buffer.removeFirst() }
                if abs(engine.observe(buffer).cursor - reading.truth[index]) <= 3 { accurate += 1 }
            }
            return Double(accurate) / Double(reading.spoken.count)
        }
        XCTAssertGreaterThan(scores.reduce(0, +) / Double(scores.count), 0.85)
    }

    func testHomophoneDenseReadingNeverMisleadsCursor() {
        let script = """
        The writer made a whole new piece, and her plain prose could break through any
        wall. She would pair each tale with steel resolve, never bored. A great course
        of practice, flour still on her hands at dawn, and by the meet she would sail
        past every doubt. The whole piece was made plain again, and the right words rose
        to meet her.
        """
        let homophones = [
            "made": "maid", "whole": "hole", "piece": "peace", "plain": "plane",
            "break": "brake", "through": "threw", "pair": "pear", "tale": "tail",
            "steel": "steal", "great": "grate", "course": "coarse", "flour": "flower",
            "meet": "meat", "sail": "sale", "right": "write",
        ]
        let base = ReaderTokenizer.normalizeUtterance(script)
        XCTAssertGreaterThanOrEqual(base.filter { homophones[$0] != nil }.count, 12)
        let spoken = base.map { homophones[$0] ?? $0 }
        let engine = AlignmentEngine(script: script)
        var buffer: [String] = []
        var accurate = 0
        for (index, word) in spoken.enumerated() {
            buffer.append(word)
            if buffer.count > 12 { buffer.removeFirst() }
            if abs(engine.observe(buffer).cursor - index) <= 3 { accurate += 1 }
        }
        XCTAssertGreaterThan(Double(accurate) / Double(spoken.count), 0.95)
    }

    private func averageAccuracy(errorRate: Double) -> Double {
        let words = ReaderTokenizer.normalizeUtterance(Self.script)
        let scores = Self.seeds.map { seed in
            let spoken = generateSpokenSequence(words: words, errorRate: errorRate, seed: seed)
            let engine = AlignmentEngine(script: Self.script)
            var buffer: [String] = []
            var accurate = 0
            for (index, word) in spoken.enumerated() {
                buffer.append(word)
                if buffer.count > 12 { buffer.removeFirst() }
                if abs(engine.observe(buffer).cursor - index) <= 3 { accurate += 1 }
            }
            return Double(accurate) / Double(spoken.count)
        }
        return scores.reduce(0, +) / Double(scores.count)
    }
}
