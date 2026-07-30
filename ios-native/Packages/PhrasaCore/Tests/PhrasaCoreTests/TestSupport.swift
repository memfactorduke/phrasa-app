import Foundation
@testable import PhrasaCore

struct SimulationResult {
    let engine: AlignmentEngine
    let cursors: [Int]
}

func simulate(
    spoken: [String],
    tailSize: Int = 12,
    script: String
) -> SimulationResult {
    let engine = AlignmentEngine(script: script)
    var cursors: [Int] = []
    var buffer: [String] = []
    for word in spoken {
        buffer.append(word)
        if buffer.count > tailSize { buffer.removeFirst() }
        cursors.append(engine.observe(buffer).cursor)
    }
    return SimulationResult(engine: engine, cursors: cursors)
}

func isNondecreasing(_ values: [Int]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy(<=)
}

private struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x6D2B79F5
        var value = (state ^ (state >> 15)) &* (1 | state)
        value = (value &+ ((value ^ (value >> 7)) &* (61 | value))) ^ value
        value ^= value >> 14
        return Double(value) / 4_294_967_296
    }
}

private let fillers = ["um", "uh", "like", "you", "know"]
private let offscript = ["honestly", "anyway", "tangent", "sidebar", "whatever"]

private func perturbed(_ word: String, random: inout Mulberry32) -> String {
    guard word.count >= 4 else { return word }
    let offset = Int(random.next() * Double(word.count))
    let index = word.index(word.startIndex, offsetBy: offset)
    var copy = word
    copy.remove(at: index)
    return copy
}

func generateSpokenSequence(
    words: [String],
    errorRate: Double = 0,
    fillerRate: Double = 0,
    seed: UInt32 = 1
) -> [String] {
    var random = Mulberry32(seed: seed)
    var result: [String] = []
    for word in words {
        result.append(random.next() < errorRate ? perturbed(word, random: &random) : word)
        if fillerRate > 0, random.next() < fillerRate {
            result.append(fillers[Int(random.next() * Double(fillers.count))])
        }
    }
    return result
}

func generateReadingWithTruth(
    words: [String],
    errorRate: Double = 0,
    fillerRate: Double = 0,
    insertionRate: Double = 0,
    seed: UInt32 = 1
) -> (spoken: [String], truth: [Int]) {
    var random = Mulberry32(seed: seed)
    var spoken: [String] = []
    var truth: [Int] = []

    for (index, word) in words.enumerated() {
        spoken.append(random.next() < errorRate ? perturbed(word, random: &random) : word)
        truth.append(index)
        if fillerRate > 0, random.next() < fillerRate {
            spoken.append(fillers[Int(random.next() * Double(fillers.count))])
            truth.append(index)
        }
        if insertionRate > 0, random.next() < insertionRate {
            spoken.append(offscript[Int(random.next() * Double(offscript.count))])
            truth.append(index)
        }
    }
    return (spoken, truth)
}
