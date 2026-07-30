import XCTest
@testable import PhrasaCore

final class VisiblePositionControllerTests: XCTestCase {
    func testPlusOneCommitsImmediately() {
        var policy = VisiblePositionController(committedIndex: 10)
        let snap = policy.observe(candidateIndex: 11, confidence: 0.4)
        XCTAssertTrue(snap.didCommit)
        XCTAssertEqual(snap.committedIndex, 11)
        XCTAssertNil(snap.provisionalIndex)
        XCTAssertEqual(snap.visibleIndex, 11)
        XCTAssertEqual(snap.visibleIndex, snap.committedIndex)
        XCTAssertEqual(snap.strongStreak, 0)
    }

    func testAutomaticNeverMovesBackward() {
        var policy = VisiblePositionController(committedIndex: 20)
        let snap = policy.observe(candidateIndex: 12, confidence: 0.99)
        XCTAssertFalse(snap.didCommit)
        XCTAssertEqual(snap.committedIndex, 20)
        XCTAssertEqual(snap.visibleIndex, 20)
        XCTAssertEqual(snap.visibleIndex, snap.committedIndex)
        XCTAssertNil(snap.provisionalIndex)
    }

    func testForwardJumpRequiresTwoStrongObservations() {
        var policy = VisiblePositionController(committedIndex: 5)

        let first = policy.observe(candidateIndex: 40, confidence: 0.78)
        XCTAssertFalse(first.didCommit)
        XCTAssertEqual(first.committedIndex, 5)
        XCTAssertEqual(first.provisionalIndex, 40)
        // Visible stays committed until the two-strong gate commits.
        XCTAssertEqual(first.visibleIndex, 5)
        XCTAssertEqual(first.visibleIndex, first.committedIndex)
        XCTAssertNotEqual(first.visibleIndex, first.provisionalIndex)
        XCTAssertEqual(first.strongStreak, 1)

        let second = policy.observe(candidateIndex: 41, confidence: 0.80)
        XCTAssertTrue(second.didCommit)
        XCTAssertEqual(second.committedIndex, 41)
        XCTAssertNil(second.provisionalIndex)
        XCTAssertEqual(second.visibleIndex, 41)
        XCTAssertEqual(second.visibleIndex, second.committedIndex)
        XCTAssertEqual(second.strongStreak, 0)
    }

    func testSingleFarCallbackNeverLeapsVisibleIndex() {
        var policy = VisiblePositionController(committedIndex: 0)
        let snap = policy.observe(candidateIndex: 99, confidence: 0.99)
        XCTAssertFalse(snap.didCommit)
        XCTAssertEqual(snap.committedIndex, 0)
        XCTAssertEqual(snap.provisionalIndex, 99)
        XCTAssertEqual(snap.visibleIndex, 0)
        XCTAssertEqual(policy.visibleIndex, policy.committedIndex)
    }

    func testVisibleIndexAlwaysEqualsCommittedUntilDidCommit() {
        var policy = VisiblePositionController(committedIndex: 3)
        let steps: [(Int, Double)] = [
            (4, 0.5),   // +1 commit
            (20, 0.9),  // provisional only
            (21, 0.9),  // second strong → commit
            (15, 0.99), // backward ignored
            (40, 0.5),  // weak far — no provisional
            (50, 0.95), // provisional
            (50, 0.95), // commit
        ]
        for (candidate, confidence) in steps {
            let snap = policy.observe(candidateIndex: candidate, confidence: confidence)
            XCTAssertEqual(
                snap.visibleIndex,
                snap.committedIndex,
                "visibleIndex must equal committedIndex (candidate=\(candidate))"
            )
            if !snap.didCommit, let provisional = snap.provisionalIndex {
                XCTAssertNotEqual(
                    snap.visibleIndex,
                    provisional,
                    "visible must not follow provisional before commit"
                )
            }
        }
    }

    func testWeakFarObservationDoesNotCommitOrAccumulate() {
        var policy = VisiblePositionController(committedIndex: 5)
        _ = policy.observe(candidateIndex: 40, confidence: 0.77)
        XCTAssertEqual(policy.committedIndex, 5)
        XCTAssertNil(policy.provisionalIndex)
        XCTAssertEqual(policy.visibleIndex, 5)

        let again = policy.observe(candidateIndex: 40, confidence: 0.50)
        XCTAssertFalse(again.didCommit)
        XCTAssertEqual(again.committedIndex, 5)
        XCTAssertNil(again.provisionalIndex)
        XCTAssertEqual(again.visibleIndex, 5)
        XCTAssertEqual(again.strongStreak, 0)
    }

    func testStrongStreakResetsWhenCandidateJumpsElsewhere() {
        var policy = VisiblePositionController(committedIndex: 0)
        _ = policy.observe(candidateIndex: 30, confidence: 0.9)
        XCTAssertEqual(policy.provisionalIndex, 30)
        XCTAssertEqual(policy.visibleIndex, 0)

        let elsewhere = policy.observe(candidateIndex: 80, confidence: 0.9)
        XCTAssertFalse(elsewhere.didCommit)
        XCTAssertEqual(elsewhere.provisionalIndex, 80)
        XCTAssertEqual(elsewhere.strongStreak, 1)
        XCTAssertEqual(elsewhere.committedIndex, 0)
        XCTAssertEqual(elsewhere.visibleIndex, 0)
    }

    func testManualReseatIsAuthoritativeAndClearsProvisional() {
        var policy = VisiblePositionController(committedIndex: 10)
        _ = policy.observe(candidateIndex: 50, confidence: 0.95)
        XCTAssertEqual(policy.provisionalIndex, 50)
        XCTAssertEqual(policy.visibleIndex, 10)

        let reseat = policy.manualReseat(to: 3)
        XCTAssertTrue(reseat.didCommit)
        XCTAssertEqual(reseat.committedIndex, 3)
        XCTAssertNil(reseat.provisionalIndex)
        XCTAssertEqual(reseat.visibleIndex, 3)
        XCTAssertEqual(reseat.visibleIndex, reseat.committedIndex)
        XCTAssertEqual(reseat.strongStreak, 0)

        // After reseat, +1 from new commit still works; old provisional does not linger.
        let next = policy.observe(candidateIndex: 4, confidence: 0.2)
        XCTAssertTrue(next.didCommit)
        XCTAssertEqual(next.committedIndex, 4)
        XCTAssertEqual(next.visibleIndex, 4)
    }

    func testManualReseatMayMoveAnywhereIncludingBackwardAndFarForward() {
        var policy = VisiblePositionController(committedIndex: 100)
        XCTAssertEqual(policy.manualReseat(to: 2).committedIndex, 2)
        XCTAssertEqual(policy.visibleIndex, 2)
        XCTAssertEqual(policy.manualReseat(to: 500).committedIndex, 500)
        XCTAssertEqual(policy.visibleIndex, 500)
        XCTAssertNil(policy.provisionalIndex)
    }

    func testStayAtCommittedClearsProvisional() {
        var policy = VisiblePositionController(committedIndex: 10)
        _ = policy.observe(candidateIndex: 25, confidence: 0.9)
        XCTAssertNotNil(policy.provisionalIndex)
        XCTAssertEqual(policy.visibleIndex, 10)

        let stay = policy.observe(candidateIndex: 10, confidence: 0.6)
        XCTAssertFalse(stay.didCommit)
        XCTAssertNil(stay.provisionalIndex)
        XCTAssertEqual(stay.visibleIndex, 10)
    }

    func testReturnedSnapshotVisibleIndexEqualsCommitted() {
        var policy = VisiblePositionController(committedIndex: 7)
        // Single strong far jump: provisional set, committed (and visible) stay put.
        let snap = policy.observe(candidateIndex: 99, confidence: 0.99)
        XCTAssertFalse(snap.didCommit)
        XCTAssertEqual(snap.committedIndex, 7)
        XCTAssertEqual(snap.provisionalIndex, 99)
        XCTAssertEqual(snap.visibleIndex, 7)
        XCTAssertEqual(snap.visibleIndex, snap.committedIndex)
        XCTAssertEqual(snap.strongStreak, 1)
        XCTAssertTrue(snap.didUpdateProvisional)
    }

    func testDeterministicSequenceIsStable() {
        var policy = VisiblePositionController(committedIndex: 0)
        var committed: [Int] = []
        var visibles: [Int] = []
        let steps: [(Int, Double)] = [
            (1, 0.5), (2, 0.5), (10, 0.9), (11, 0.9), (12, 0.4), (13, 0.4),
        ]
        for (candidate, confidence) in steps {
            let snap = policy.observe(candidateIndex: candidate, confidence: confidence)
            committed.append(snap.committedIndex)
            visibles.append(snap.visibleIndex)
            XCTAssertEqual(snap.visibleIndex, snap.committedIndex)
        }
        XCTAssertEqual(committed, [1, 2, 2, 11, 12, 13])
        XCTAssertEqual(visibles, committed)
    }
}
