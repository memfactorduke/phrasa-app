import UIKit
import XCTest
import PhrasaCore
@testable import Phrasa

final class NativeExperiencePresentationTests: XCTestCase {
    func testMonochromeDesignTokensMatchSpec() {
        XCTAssertEqual(PhrasaDesign.cardRadius, 8)
        XCTAssertEqual(PhrasaDesign.controlRadius, 8)
        XCTAssertEqual(PhrasaDesign.minTouchTarget, 44)
        XCTAssertGreaterThanOrEqual(PhrasaDesign.motionDuration, 0.12)
        XCTAssertLessThanOrEqual(PhrasaDesign.motionDuration, 0.20)
        // Compatibility aliases keep Settings/Cloud compiling during the rebuild.
        XCTAssertEqual(PhrasaDesign.ember, PhrasaDesign.ink)
        XCTAssertEqual(PhrasaDesign.success, PhrasaDesign.ink)
    }

    func testLibrarySelectionPolicyRetainsOnlyExistingIDs() {
        let kept = UUID()
        let gone = UUID()
        XCTAssertEqual(
            LibrarySelectionPolicy.retainedSelection(kept, availableIDs: [kept, UUID()]),
            kept
        )
        XCTAssertNil(LibrarySelectionPolicy.retainedSelection(gone, availableIDs: [kept]))
        XCTAssertNil(LibrarySelectionPolicy.retainedSelection(nil, availableIDs: [kept]))
    }

    func testLibraryRestorePromptIsRestrainedAndConcrete() {
        let scripts = [
            ScriptDocument(title: "A", body: "one"),
            ScriptDocument(title: "B", body: "two")
        ]
        let folders = [ScriptFolder(name: "Talks")]
        let snapshot = LibrarySnapshot(scripts: scripts, folders: folders, settings: .init(), seeded: false)
        let message = LibraryRestorePrompt.message(for: snapshot)
        XCTAssertTrue(message.contains("2 scripts"))
        XCTAssertTrue(message.contains("1 folder"))
        XCTAssertTrue(message.contains("Merge"))
        XCTAssertTrue(message.contains("Replace"))
        XCTAssertEqual(LibraryRestorePrompt.title, "Restore backup?")
    }

    func testVoiceTrustStaysQuietWhileTrackingAndPulsesWhileSearching() {
        let tracking = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .hearingSpeech,
            isPlaying: true,
            recentlyAccepted: true,
            secondsSinceAcceptance: 0.4,
            missStreak: 0,
            hasProvisional: false
        )
        XCTAssertEqual(tracking, .tracking)
        XCTAssertFalse(tracking.showsSearchingPulse)
        XCTAssertNil(tracking.actionableDetail)

        let searching = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .hearingSpeech,
            isPlaying: true,
            recentlyAccepted: false,
            secondsSinceAcceptance: 3.0,
            missStreak: 3,
            hasProvisional: false
        )
        XCTAssertEqual(searching, .searching)
        XCTAssertTrue(searching.showsSearchingPulse)

        let denied = VoiceTrustPresentation.resolve(
            status: .denied,
            isPlaying: false,
            recentlyAccepted: false,
            secondsSinceAcceptance: 10
        )
        XCTAssertEqual(
            denied,
            .denied(
                message: VoiceTrustPresentation.defaultDeniedMessage,
                offersOpenSettings: true
            )
        )
        XCTAssertTrue(denied.offersOpenSettings)
        XCTAssertTrue(denied.offersUseSpeed)
        XCTAssertNotNil(denied.actionableDetail)

        let micDenied = VoiceTrustPresentation.resolve(
            status: .denied,
            health: .terminalFailure(VoicePermissionFailure.microphoneDenied.userMessage),
            isPlaying: false,
            recentlyAccepted: false,
            secondsSinceAcceptance: 10,
            missStreak: 0,
            hasProvisional: false,
            permissionFailure: .microphoneDenied
        )
        XCTAssertTrue(micDenied.offersOpenSettings)
        XCTAssertEqual(micDenied.actionableDetail, VoicePermissionFailure.microphoneDenied.userMessage)

        let speechRestricted = VoiceTrustPresentation.resolve(
            status: .denied,
            health: .terminalFailure(VoicePermissionFailure.speechRestricted.userMessage),
            isPlaying: false,
            recentlyAccepted: false,
            secondsSinceAcceptance: 10,
            missStreak: 0,
            hasProvisional: false,
            permissionFailure: .speechRestricted
        )
        XCTAssertFalse(speechRestricted.offersOpenSettings)
        XCTAssertTrue(
            speechRestricted.actionableDetail?
                .localizedCaseInsensitiveContains("restricted") == true
        )

        let unavailable = VoiceTrustPresentation.resolve(
            status: .unavailable("No recognizer"),
            isPlaying: true,
            recentlyAccepted: false,
            secondsSinceAcceptance: 1
        )
        XCTAssertEqual(unavailable, .unavailable("No recognizer"))
        XCTAssertTrue(unavailable.offersUseSpeed)
        XCTAssertFalse(unavailable.offersOpenSettings)
    }

    // MARK: - Voice trust phases (Lane C)

    func testVoiceTrustSilenceAndListeningNeverFalselySearch() {
        let silent = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .silent,
            isPlaying: true,
            recentlyAccepted: false,
            secondsSinceAcceptance: 10,
            missStreak: 5,
            hasProvisional: true
        )
        XCTAssertEqual(silent, .listening, "Quiet pause must not show Finding place")

        let inactive = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .inactive,
            isPlaying: true,
            recentlyAccepted: false,
            secondsSinceAcceptance: 8,
            missStreak: 4,
            hasProvisional: false
        )
        XCTAssertEqual(inactive, .listening)

        let paused = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .hearingSpeech,
            isPlaying: false,
            recentlyAccepted: false,
            secondsSinceAcceptance: 3,
            missStreak: 3,
            hasProvisional: true
        )
        XCTAssertEqual(paused, .listening)
    }

    func testVoiceTrustTrackingFollowingAndFindingPhases() {
        let following = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .hearingSpeech,
            isPlaying: true,
            recentlyAccepted: true,
            secondsSinceAcceptance: 0.5,
            missStreak: 0,
            hasProvisional: false
        )
        XCTAssertEqual(following, .tracking)

        let listeningWhileHearing = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .hearingSpeech,
            isPlaying: true,
            recentlyAccepted: false,
            secondsSinceAcceptance: 0.5,
            missStreak: 0,
            hasProvisional: false
        )
        XCTAssertEqual(listeningWhileHearing, .listening)

        let finding = VoiceTrustPresentation.resolve(
            status: .listening,
            health: .hearingSpeech,
            isPlaying: true,
            recentlyAccepted: false,
            secondsSinceAcceptance: 3.0,
            missStreak: 2,
            hasProvisional: true
        )
        XCTAssertEqual(finding, .searching)

        let recovering = VoiceTrustPresentation.resolve(
            status: .starting,
            health: .recovering,
            isPlaying: true,
            recentlyAccepted: false,
            secondsSinceAcceptance: 1,
            missStreak: 0,
            hasProvisional: false
        )
        XCTAssertEqual(recovering, .starting)
    }

    // MARK: - Commit gating / no provisional visible leap

    func testVoiceFollowCommitGatingNeverPublishesProvisionalLeap() {
        var controller = VisiblePositionController(committedIndex: 5)

        let far = VoiceFollowBinding.observeCandidate(
            candidateIndex: 40,
            confidence: 0.95,
            controller: &controller
        )
        XCTAssertFalse(far.didCommit)
        XCTAssertEqual(far.provisionalIndex, 40)
        XCTAssertEqual(far.visibleIndex, 5)
        XCTAssertEqual(far.visibleIndex, far.committedIndex)
        XCTAssertNotEqual(far.visibleIndex, far.provisionalIndex)

        // UI may only publish visibleIndex — still at 5 after one far provisional.
        XCTAssertEqual(controller.visibleIndex, 5)

        let second = VoiceFollowBinding.observeCandidate(
            candidateIndex: 41,
            confidence: 0.90,
            controller: &controller
        )
        XCTAssertTrue(second.didCommit)
        XCTAssertEqual(second.visibleIndex, 41)
        XCTAssertNil(second.provisionalIndex)
    }

    func testVoiceFollowNoBackwardRewriteJump() {
        var controller = VisiblePositionController(committedIndex: 20)
        let back = VoiceFollowBinding.observeCandidate(
            candidateIndex: 8,
            confidence: 0.99,
            controller: &controller
        )
        XCTAssertFalse(back.didCommit)
        XCTAssertEqual(back.visibleIndex, 20)
        XCTAssertEqual(controller.committedIndex, 20)
        XCTAssertNil(back.provisionalIndex)
    }

    func testRejectedAlignmentPlusOneNeverAdvancesVisiblePosition() {
        var controller = VisiblePositionController(committedIndex: 10)
        // Seed a stale provisional that rejection must clear.
        _ = VoiceFollowBinding.observeCandidate(
            candidateIndex: 40,
            confidence: 0.95,
            controller: &controller
        )
        XCTAssertEqual(controller.provisionalIndex, 40)
        XCTAssertEqual(controller.visibleIndex, 10)

        // Rejected +1 would have committed under raw observe(); must not under accepted gate.
        let rejected = VoiceFollowBinding.applyAlignmentObservation(
            accepted: false,
            candidateIndex: 11,
            confidence: 0.99,
            controller: &controller
        )
        XCTAssertFalse(rejected.didCommit)
        XCTAssertEqual(rejected.visibleIndex, 10)
        XCTAssertEqual(rejected.committedIndex, 10)
        XCTAssertNil(rejected.provisionalIndex)
        XCTAssertEqual(controller.committedIndex, 10)
        XCTAssertEqual(controller.visibleIndex, 10)
        XCTAssertNil(controller.provisionalIndex)

        // Accepted +1 still commits immediately.
        let accepted = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 11,
            confidence: 0.4,
            controller: &controller
        )
        XCTAssertTrue(accepted.didCommit)
        XCTAssertEqual(accepted.visibleIndex, 11)

        // Accepted confirmed far (two strong) still works.
        let far1 = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 30,
            confidence: 0.95,
            controller: &controller
        )
        XCTAssertFalse(far1.didCommit)
        XCTAssertEqual(far1.provisionalIndex, 30)
        XCTAssertEqual(far1.visibleIndex, 11)

        let far2 = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 31,
            confidence: 0.90,
            controller: &controller
        )
        XCTAssertTrue(far2.didCommit)
        XCTAssertEqual(far2.visibleIndex, 31)
        XCTAssertNil(far2.provisionalIndex)
    }

    func testVoiceFollowInitialAcquisitionCommitsAcceptedOpeningMatch() {
        let engine = AlignmentEngine(
            script: "Welcome to Phrasa. This is a sample script, so you can try the prompter."
        )
        let result = engine.observe(
            ReaderTokenizer.normalizeUtterance(
                "Welcome to Phrasa. This is a sample script."
            )
        )
        XCTAssertTrue(result.accepted)
        XCTAssertTrue((1...16).contains(result.tokenIndex))

        var controller = VisiblePositionController(committedIndex: 0)
        let acquired = VoiceFollowBinding.applyAlignmentObservation(
            accepted: result.accepted,
            candidateIndex: result.tokenIndex,
            confidence: result.confidence,
            allowInitialAcquisition: true,
            controller: &controller
        )

        XCTAssertTrue(acquired.didCommit)
        XCTAssertGreaterThan(acquired.visibleIndex, 0)
        XCTAssertEqual(acquired.visibleIndex, result.tokenIndex)
    }

    func testVoiceFollowInitialAcquisitionRemainsStrictlyBounded() {
        var rejectedController = VisiblePositionController(committedIndex: 0)
        let rejected = VoiceFollowBinding.applyAlignmentObservation(
            accepted: false,
            candidateIndex: 8,
            confidence: 1,
            allowInitialAcquisition: true,
            controller: &rejectedController
        )
        XCTAssertFalse(rejected.didCommit)
        XCTAssertEqual(rejected.visibleIndex, 0)

        var outOfRangeController = VisiblePositionController(committedIndex: 0)
        let outOfRange = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 17,
            confidence: 0.99,
            allowInitialAcquisition: true,
            controller: &outOfRangeController
        )
        XCTAssertFalse(outOfRange.didCommit)
        XCTAssertEqual(outOfRange.visibleIndex, 0)
        XCTAssertEqual(outOfRange.provisionalIndex, 17)

        var disabledController = VisiblePositionController(committedIndex: 0)
        let disabled = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 8,
            confidence: 0.99,
            allowInitialAcquisition: false,
            controller: &disabledController
        )
        XCTAssertFalse(disabled.didCommit)
        XCTAssertEqual(disabled.visibleIndex, 0)
        XCTAssertEqual(disabled.provisionalIndex, 8)
    }

    func testVoiceFollowAfterInitialAcquisitionKeepsOrdinaryJumpProtections() {
        var controller = VisiblePositionController(committedIndex: 0)
        let initial = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 8,
            confidence: 0.7,
            allowInitialAcquisition: true,
            controller: &controller
        )
        XCTAssertEqual(initial.visibleIndex, 8)

        let backward = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 4,
            confidence: 0.99,
            allowInitialAcquisition: true,
            controller: &controller
        )
        XCTAssertFalse(backward.didCommit)
        XCTAssertEqual(backward.visibleIndex, 8)

        let far1 = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 40,
            confidence: 0.95,
            allowInitialAcquisition: true,
            controller: &controller
        )
        XCTAssertFalse(far1.didCommit)
        XCTAssertEqual(far1.visibleIndex, 8)

        let far2 = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 41,
            confidence: 0.95,
            allowInitialAcquisition: true,
            controller: &controller
        )
        XCTAssertTrue(far2.didCommit)
        XCTAssertEqual(far2.visibleIndex, 41)
    }

    func testManualReseatPreventsASRSnapBack() {
        var controller = VisiblePositionController(committedIndex: 10)
        _ = VoiceFollowBinding.observeCandidate(
            candidateIndex: 50,
            confidence: 0.95,
            controller: &controller
        )
        XCTAssertEqual(controller.provisionalIndex, 50)
        XCTAssertEqual(controller.visibleIndex, 10)

        let reseated = VoiceFollowBinding.manualReseat(
            to: 3,
            tokenCount: 100,
            controller: &controller
        )
        XCTAssertEqual(reseated, 3)
        XCTAssertEqual(controller.visibleIndex, 3)
        XCTAssertNil(controller.provisionalIndex)

        // Stale far ASR after reseat: single strong observation stays provisional.
        let stale = VoiceFollowBinding.observeCandidate(
            candidateIndex: 50,
            confidence: 0.99,
            controller: &controller
        )
        XCTAssertFalse(stale.didCommit)
        XCTAssertEqual(stale.visibleIndex, 3)
        XCTAssertEqual(stale.provisionalIndex, 50)

        // Plus-one from reseated cursor still commits immediately.
        let next = VoiceFollowBinding.observeCandidate(
            candidateIndex: 4,
            confidence: 0.4,
            controller: &controller
        )
        XCTAssertTrue(next.didCommit)
        XCTAssertEqual(next.visibleIndex, 4)
    }

    func testLanguageRestartPreservesCommittedCursor() {
        var controller = VisiblePositionController(committedIndex: 17)
        _ = VoiceFollowBinding.observeCandidate(
            candidateIndex: 40,
            confidence: 0.9,
            controller: &controller
        )
        XCTAssertEqual(controller.provisionalIndex, 40)
        let committedBefore = controller.committedIndex
        XCTAssertEqual(committedBefore, 17)
        XCTAssertEqual(controller.visibleIndex, 17)

        // Explicit language-restart path: clear provisional, reseat at committed.
        let reseated = VoiceFollowBinding.prepareLanguageRestart(
            committedIndex: committedBefore,
            controller: &controller
        )
        XCTAssertEqual(reseated, 17)
        XCTAssertTrue(
            VoiceFollowBinding.cursorPreservedAfterLanguageRestart(
                committedBefore: committedBefore,
                controller: controller
            )
        )
        XCTAssertEqual(controller.committedIndex, 17)
        XCTAssertEqual(controller.visibleIndex, 17)
        XCTAssertNil(controller.provisionalIndex)

        // Far ASR after language restart still cannot single-shot leap the cursor.
        let leap = VoiceFollowBinding.applyAlignmentObservation(
            accepted: true,
            candidateIndex: 80,
            confidence: 0.99,
            controller: &controller
        )
        XCTAssertEqual(leap.visibleIndex, 17)
        XCTAssertFalse(leap.didCommit)
        XCTAssertEqual(leap.provisionalIndex, 80)
    }

    func testAlignmentTailDedupSkipsEmptyAndDuplicate() {
        // Empty / whitespace: never process.
        XCTAssertFalse(
            VoiceFollowBinding.shouldProcessAlignmentTail(
                tail: "",
                lastAlignedNonemptyTail: nil
            )
        )
        XCTAssertFalse(
            VoiceFollowBinding.shouldProcessAlignmentTail(
                tail: "   \n\t  ",
                lastAlignedNonemptyTail: nil
            )
        )
        XCTAssertNil(VoiceFollowBinding.alignmentTailKey(""))
        XCTAssertNil(VoiceFollowBinding.alignmentTailKey("  "))

        // First nonempty tail processes and yields a stable key.
        let first = "Hello world"
        XCTAssertTrue(
            VoiceFollowBinding.shouldProcessAlignmentTail(
                tail: first,
                lastAlignedNonemptyTail: nil
            )
        )
        let key = VoiceFollowBinding.alignmentTailKey(first)
        XCTAssertEqual(key, "hello world")

        // Exact duplicate of last aligned key: skip (health-only / same tail).
        XCTAssertFalse(
            VoiceFollowBinding.shouldProcessAlignmentTail(
                tail: "hello world",
                lastAlignedNonemptyTail: key
            )
        )
        XCTAssertFalse(
            VoiceFollowBinding.shouldProcessAlignmentTail(
                tail: "Hello, WORLD!",
                lastAlignedNonemptyTail: key
            )
        )

        // Genuinely changed bounded tail processes.
        XCTAssertTrue(
            VoiceFollowBinding.shouldProcessAlignmentTail(
                tail: "hello world next",
                lastAlignedNonemptyTail: key
            )
        )
        XCTAssertEqual(
            VoiceFollowBinding.alignmentTailKey("hello world next"),
            "hello world next"
        )

        // Rejected + empty cannot advance via the observation gate either.
        var controller = VisiblePositionController(committedIndex: 5)
        _ = VoiceFollowBinding.applyAlignmentObservation(
            accepted: false,
            candidateIndex: 6,
            confidence: 1,
            controller: &controller
        )
        XCTAssertEqual(controller.visibleIndex, 5)
        XCTAssertFalse(
            VoiceFollowBinding.shouldProcessAlignmentTail(
                tail: "",
                lastAlignedNonemptyTail: "hello"
            )
        )
    }

    func testVoiceFollowProgressAndTokenRoundTrip() {
        XCTAssertEqual(VoiceFollowBinding.progress(tokenIndex: 0, tokenCount: 1), 0)
        XCTAssertEqual(VoiceFollowBinding.progress(tokenIndex: 5, tokenCount: 11), 0.5, accuracy: 1e-9)
        XCTAssertEqual(VoiceFollowBinding.tokenIndex(progress: 0.5, tokenCount: 11), 5)
        XCTAssertEqual(VoiceFollowBinding.tokenDelta(forProgressDelta: -0.012), -1)
        XCTAssertEqual(VoiceFollowBinding.tokenDelta(forProgressDelta: 0.04), 4)
    }

    func testCompletionDwellArmingAndTiming() {
        let tokens = ReaderTokenizer.tokenize("one two three four")
        let final = VoiceFollowBinding.finalMatchableTokenIndex(in: tokens)
        XCTAssertEqual(final, tokens.count - 1)
        XCTAssertTrue(VoiceFollowBinding.shouldArmCompletionDwell(visibleIndex: final!, finalMatchableTokenIndex: final))
        XCTAssertFalse(VoiceFollowBinding.shouldArmCompletionDwell(visibleIndex: 0, finalMatchableTokenIndex: final))

        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(
            VoiceFollowBinding.shouldCompleteAfterDwell(dwellStartedAt: nil, now: start)
        )
        XCTAssertFalse(
            VoiceFollowBinding.shouldCompleteAfterDwell(
                dwellStartedAt: start,
                now: start.addingTimeInterval(0.5)
            )
        )
        XCTAssertTrue(
            VoiceFollowBinding.shouldCompleteAfterDwell(
                dwellStartedAt: start,
                now: start.addingTimeInterval(1.2)
            )
        )

        // Must not complete while paused or blacked out.
        XCTAssertFalse(
            VoiceFollowBinding.shouldAllowCompletionDwell(isPlaying: false, isBlackout: false)
        )
        XCTAssertFalse(
            VoiceFollowBinding.shouldAllowCompletionDwell(isPlaying: true, isBlackout: true)
        )
        XCTAssertTrue(
            VoiceFollowBinding.shouldAllowCompletionDwell(isPlaying: true, isBlackout: false)
        )
    }

    // MARK: - Scrub reachability / blackout freeze policies

    func testPrompterHitTestingMatchesStagePolicy() {
        // Matches ReaderView's .allowsHitTesting(ReaderStageInteractionPolicy...)
        XCTAssertTrue(
            ReaderStageInteractionPolicy.prompterAllowsHitTesting(isBlackout: false),
            "Normal stage must allow UITextView scrubbing"
        )
        XCTAssertFalse(
            ReaderStageInteractionPolicy.prompterAllowsHitTesting(isBlackout: true),
            "Blackout must not hit-test the prompter under the cover"
        )
    }

    func testBlackoutExcludesDurationAndFreezesPrompterMotion() {
        let t0 = Date(timeIntervalSince1970: 2_000)
        let tPlay = t0
        let tBlackout = t0.addingTimeInterval(10)
        let tReveal = t0.addingTimeInterval(25)
        let tEnd = t0.addingTimeInterval(30)

        // Playing for 10s, blackout 15s, play 5s → active elapsed 15s (not 30).
        var elapsedBefore: TimeInterval = 0
        var startedAt: Date? = tPlay

        XCTAssertEqual(
            ReaderBlackoutPlaybackPolicy.activeElapsed(
                elapsedBeforeStart: elapsedBefore,
                startedAt: startedAt,
                now: tBlackout
            ),
            10,
            accuracy: 1e-9
        )

        let frozen = ReaderBlackoutPlaybackPolicy.freezeElapsed(
            elapsedBeforeStart: elapsedBefore,
            startedAt: startedAt,
            at: tBlackout
        )
        elapsedBefore = frozen.elapsedBeforeStart
        startedAt = frozen.startedAt
        XCTAssertNil(startedAt)
        XCTAssertEqual(elapsedBefore, 10, accuracy: 1e-9)

        // During blackout, wall clock advances but active elapsed holds.
        XCTAssertEqual(
            ReaderBlackoutPlaybackPolicy.activeElapsed(
                elapsedBeforeStart: elapsedBefore,
                startedAt: startedAt,
                now: tReveal
            ),
            10,
            accuracy: 1e-9
        )

        // Prompter motion off for both modes while blacked out / pre-roll.
        XCTAssertFalse(
            ReaderBlackoutPlaybackPolicy.prompterIsEffectivelyPlaying(
                isPlaying: true,
                preRollActive: false,
                isBlackout: true
            )
        )
        XCTAssertFalse(
            ReaderBlackoutPlaybackPolicy.prompterIsEffectivelyPlaying(
                isPlaying: true,
                preRollActive: true,
                isBlackout: false
            )
        )
        XCTAssertTrue(
            ReaderBlackoutPlaybackPolicy.prompterIsEffectivelyPlaying(
                isPlaying: true,
                preRollActive: false,
                isBlackout: false
            )
        )

        // Reveal resumes only when previously playing (flag + logically playing).
        XCTAssertTrue(
            ReaderBlackoutPlaybackPolicy.shouldRememberResumeOnBlackoutEntry(isPlaying: true)
        )
        XCTAssertFalse(
            ReaderBlackoutPlaybackPolicy.shouldRememberResumeOnBlackoutEntry(isPlaying: false)
        )
        XCTAssertTrue(
            ReaderBlackoutPlaybackPolicy.shouldResumeOnReveal(
                resumeRemembered: true,
                isLogicallyPlaying: true
            )
        )
        XCTAssertFalse(
            ReaderBlackoutPlaybackPolicy.shouldResumeOnReveal(
                resumeRemembered: true,
                isLogicallyPlaying: false
            )
        )
        XCTAssertFalse(
            ReaderBlackoutPlaybackPolicy.shouldResumeOnReveal(
                resumeRemembered: false,
                isLogicallyPlaying: true
            )
        )

        let resumed = ReaderBlackoutPlaybackPolicy.resumeElapsed(
            elapsedBeforeStart: elapsedBefore,
            at: tReveal
        )
        elapsedBefore = resumed.elapsedBeforeStart
        startedAt = resumed.startedAt
        XCTAssertEqual(startedAt, tReveal)
        XCTAssertEqual(
            ReaderBlackoutPlaybackPolicy.activeElapsed(
                elapsedBeforeStart: elapsedBefore,
                startedAt: startedAt,
                now: tEnd
            ),
            15,
            accuracy: 1e-9
        )
    }

    // MARK: - Prompter geometry (token pin, not document-height %)

    func testPrompterOffsetPinsLineCenterToFocusNotTokenRatio() {
        // Token 50% of script must NOT force 50% scroll when line centers differ.
        let lineCenter: CGFloat = 400
        let focusY: CGFloat = 200
        let maxOffset: CGFloat = 1_000
        let offset = PrompterGeometry.offsetPinningLineCenter(
            lineCenterY: lineCenter,
            focusYInViewport: focusY,
            maxOffset: maxOffset
        )
        XCTAssertEqual(offset, 200, accuracy: 0.001)

        let clamped = PrompterGeometry.offsetPinningLineCenter(
            lineCenterY: 5_000,
            focusYInViewport: focusY,
            maxOffset: maxOffset
        )
        XCTAssertEqual(clamped, maxOffset, accuracy: 0.001)

        // Focus inverse for scrub lookup.
        let focusContent = PrompterGeometry.focusContentY(contentOffsetY: 200, focusYInViewport: 180)
        XCTAssertEqual(focusContent, 380, accuracy: 0.001)
    }

    func testPrompterVoiceSmoothingIsResponsiveStableAndNeverOvershoots() {
        // Explicit factor: step is (target - current) / factor.
        let stepped = PrompterGeometry.smoothedOffset(
            current: 0,
            target: 90,
            factor: 9,
            reduceMotion: false
        )
        XCTAssertEqual(stepped, 10, accuracy: 0.001)

        // Default adaptive path: near target (< mid band) uses baseline factor 4.
        XCTAssertEqual(PrompterGeometry.voiceSmoothingFactor, 4, accuracy: 0.001)
        let nearTarget: CGFloat = 40
        XCTAssertLessThan(nearTarget, PrompterGeometry.voiceMidDistance)
        let adaptiveNear = PrompterGeometry.smoothedOffset(
            current: 0,
            target: nearTarget,
            reduceMotion: false
        )
        XCTAssertEqual(
            adaptiveNear,
            nearTarget / PrompterGeometry.voiceSmoothingFactor,
            accuracy: 0.001
        )

        // Mid band is snappier than baseline; far lag is snappier still.
        let midFactor = PrompterGeometry.adaptiveVoiceSmoothingFactor(distance: 120)
        XCTAssertEqual(midFactor, PrompterGeometry.voiceMidSmoothingFactor, accuracy: 0.001)
        let midStep = PrompterGeometry.smoothedOffset(
            current: 0,
            target: 120,
            reduceMotion: false
        )
        XCTAssertEqual(midStep, 120 / midFactor, accuracy: 0.001)

        let farFactor = PrompterGeometry.adaptiveVoiceSmoothingFactor(distance: 400)
        XCTAssertEqual(farFactor, PrompterGeometry.voiceFarSmoothingFactor, accuracy: 0.001)
        let farStep = PrompterGeometry.smoothedOffset(
            current: 0,
            target: 400,
            reduceMotion: false
        )
        XCTAssertEqual(farStep, 400 / farFactor, accuracy: 0.001)
        XCTAssertLessThan(farStep, 400)
        XCTAssertGreaterThan(farStep, 400 / PrompterGeometry.voiceSmoothingFactor)

        // Residual below epsilon snaps; reduced motion always snaps.
        let settled = PrompterGeometry.smoothedOffset(
            current: 10,
            target: 10.2,
            reduceMotion: false
        )
        XCTAssertEqual(settled, 10.2, accuracy: 0.001)
        let snapped = PrompterGeometry.smoothedOffset(
            current: 0,
            target: 90,
            reduceMotion: true
        )
        XCTAssertEqual(snapped, 90, accuracy: 0.001)

        // Multi-tick chase never overshoots (no oscillation from reanimation).
        var offset: CGFloat = 0
        let target: CGFloat = 500
        for _ in 0..<40 {
            let next = PrompterGeometry.smoothedOffset(
                current: offset,
                target: target,
                reduceMotion: false
            )
            XCTAssertLessThanOrEqual(next, target + 0.001)
            XCTAssertGreaterThanOrEqual(next, offset - 0.001)
            offset = next
        }
        XCTAssertEqual(offset, target, accuracy: 1.0)
    }

    func testTokenNSRangesMatchTokenizerOrderAndExactRawSpans() {
        let text = "Hello, world.\nNext line"
        let tokens = ReaderTokenizer.tokenize(text)
        let ranges = PrompterGeometry.tokenNSRanges(in: text)
        XCTAssertEqual(ranges.count, tokens.count)
        let ns = text as NSString
        for (index, range) in ranges.enumerated() {
            XCTAssertNotEqual(range.location, NSNotFound)
            XCTAssertEqual(ns.substring(with: range), tokens[index].raw)
        }
    }

    func testNearestFocusTokenLookupUsesLineCenters() {
        let centers: [CGFloat] = [10, 50, 90, 140]
        XCTAssertEqual(
            PrompterGeometry.nearestTokenIndex(focusContentY: 12, tokenLineCenters: centers),
            0
        )
        XCTAssertEqual(
            PrompterGeometry.nearestTokenIndex(focusContentY: 88, tokenLineCenters: centers),
            2
        )
        XCTAssertEqual(
            PrompterGeometry.nearestTokenIndex(focusContentY: 200, tokenLineCenters: centers),
            3
        )
        XCTAssertNil(PrompterGeometry.nearestTokenIndex(focusContentY: 0, tokenLineCenters: []))
    }

    func testLineCenterYUsesFragmentMidAndInset() {
        let fragment = CGRect(x: 0, y: 100, width: 200, height: 40)
        let y = PrompterGeometry.lineCenterY(fragmentRect: fragment, textContainerInsetTop: 80)
        XCTAssertEqual(y, 200, accuracy: 0.001)
    }

    func testVerticalMirrorMovesGuideAndTextAnchorTogether() {
        let height: CGFloat = 100
        let content = PrompterGeometry.contentFocusY(
            height: height,
            focusPosition: 0.4
        )
        XCTAssertEqual(content, 40, accuracy: 0.001)
        XCTAssertEqual(
            PrompterGeometry.visibleFocusY(
                height: height,
                focusPosition: 0.4,
                mirrorVertical: false
            ),
            40,
            accuracy: 0.001
        )
        let mirroredGuide = PrompterGeometry.visibleFocusY(
            height: height,
            focusPosition: 0.4,
            mirrorVertical: true
        )
        XCTAssertEqual(mirroredGuide, 60, accuracy: 0.001)
        XCTAssertEqual(
            PrompterGeometry.displayedY(
                forContentY: content,
                height: height,
                mirrorVertical: true
            ),
            mirroredGuide,
            accuracy: 0.001
        )
    }

    /// Bottom chrome must reserve stage height so script never sits under controls.
    /// Hidden chrome → full stage. Voice focus stays inside the readable stage.
    func testReadableStageExcludesBottomChromeAndKeepsFocusInside() {
        // iPad portrait-ish, iPad landscape-ish, iPhone portrait, large Dynamic Type chrome.
        let fixtures: [(stage: CGFloat, chrome: CGFloat, label: String)] = [
            (1_186, 168, "iPad portrait + voice panel"),
            (834, 152, "iPad landscape + voice panel"),
            (852, 196, "iPhone + Dynamic Type voice chrome"),
            (932, 140, "iPhone landscape + speed chrome"),
            (600, 0, "chrome hidden uses full stage"),
        ]

        for fixture in fixtures {
            let readable = PrompterGeometry.readableHeight(
                viewportHeight: fixture.stage,
                bottomChromeHeight: fixture.chrome
            )
            XCTAssertEqual(
                readable,
                fixture.stage - fixture.chrome,
                accuracy: 0.001,
                fixture.label
            )
            XCTAssertEqual(
                PrompterGeometry.readableHeight(
                    viewportHeight: fixture.stage,
                    bottomChromeHeight: -20
                ),
                fixture.stage,
                accuracy: 0.001,
                "negative chrome is treated as none — \(fixture.label)"
            )

            for focus in [0.15, 0.25, 0.5, 0.85] as [Double] {
                for mirrored in [false, true] {
                    XCTAssertTrue(
                        PrompterGeometry.focusLineIsReadable(
                            readableHeight: readable,
                            focusPosition: focus,
                            mirrorVertical: mirrored
                        ),
                        "focus \(focus) mirrored=\(mirrored) — \(fixture.label)"
                    )
                    let focusY = PrompterGeometry.visibleFocusY(
                        height: readable,
                        focusPosition: focus,
                        mirrorVertical: mirrored
                    )
                    // Spoken pin line must never land in the reserved chrome band.
                    XCTAssertLessThanOrEqual(
                        focusY,
                        readable + 0.001,
                        "\(fixture.label) focus under chrome"
                    )
                    if fixture.chrome > 0 {
                        XCTAssertLessThan(
                            focusY,
                            fixture.stage - fixture.chrome + 0.001,
                            "\(fixture.label) focus must be above chrome top"
                        )
                    }
                }
            }
        }
    }

    func testTextContainerInsetsPinFirstAndLastLineToFocusOnReadableStage() {
        let width: CGFloat = 768
        let height: CGFloat = 900
        let focus = 0.25
        let margin = 0.12
        let insets = PrompterGeometry.textContainerInsets(
            viewportWidth: width,
            viewportHeight: height,
            focusPosition: focus,
            horizontalMargin: margin
        )
        let expectedFocus = height * CGFloat(focus)
        XCTAssertEqual(insets.top, expectedFocus, accuracy: 0.001)
        XCTAssertEqual(insets.bottom, height - expectedFocus, accuracy: 0.001)
        XCTAssertEqual(insets.left, width * CGFloat(margin), accuracy: 0.001)
        XCTAssertEqual(insets.right, width * CGFloat(margin), accuracy: 0.001)

        // Insets live in content coordinates and therefore do not move. The
        // full-stage transform moves both text and guide at presentation time.
        let mirrored = PrompterGeometry.textContainerInsets(
            viewportWidth: width,
            viewportHeight: height,
            focusPosition: focus,
            horizontalMargin: margin
        )
        XCTAssertEqual(mirrored.top, expectedFocus, accuracy: 0.001)
        XCTAssertEqual(mirrored.bottom, height - expectedFocus, accuracy: 0.001)
        XCTAssertEqual(
            PrompterGeometry.visibleFocusY(
                height: height,
                focusPosition: focus,
                mirrorVertical: true
            ),
            height * (1 - CGFloat(focus)),
            accuracy: 0.001
        )

        // Empty viewport stays non-negative (rotation / first layout).
        let empty = PrompterGeometry.textContainerInsets(
            viewportWidth: 0,
            viewportHeight: 0,
            focusPosition: 0.25,
            horizontalMargin: 0.12
        )
        XCTAssertEqual(empty.top, 0, accuracy: 0.001)
        XCTAssertEqual(empty.bottom, 0, accuracy: 0.001)
    }

    func testVoicePinUsesReadableStageFocusNotFullScreenUnderChrome() {
        // Simulates layout-flow chrome: prompter bounds == readable height.
        let fullStage: CGFloat = 1_000
        let chrome: CGFloat = 180
        let readable = PrompterGeometry.readableHeight(
            viewportHeight: fullStage,
            bottomChromeHeight: chrome
        )
        XCTAssertEqual(readable, 820, accuracy: 0.001)

        let focusY = PrompterGeometry.contentFocusY(
            height: readable,
            focusPosition: 0.25
        )
        // Token line at content Y 500 pins relative to readable focus, not full stage.
        let offset = PrompterGeometry.offsetPinningLineCenter(
            lineCenterY: 500,
            focusYInViewport: focusY,
            maxOffset: 2_000
        )
        XCTAssertEqual(offset, 500 - focusY, accuracy: 0.001)
        XCTAssertEqual(focusY, 205, accuracy: 0.001)

        // Full-stage focus (old overlay bug) would be 250 — pin must not use that when
        // chrome is reserved, or spoken text drifts relative to the visible band.
        let fullStageFocus = PrompterGeometry.contentFocusY(
            height: fullStage,
            focusPosition: 0.25
        )
        XCTAssertNotEqual(focusY, fullStageFocus, accuracy: 0.001)
        XCTAssertLessThan(focusY, fullStage - chrome)
    }

    func testReaderKeyboardCommandsMapExpectedKeys() {
        XCTAssertEqual(ReaderCommand.resolve(key: .space, characters: " "), .playPause)
        XCTAssertEqual(ReaderCommand.resolve(key: nil, characters: "b"), .blackout)
        XCTAssertEqual(ReaderCommand.resolve(key: nil, characters: "B"), .blackout)
        XCTAssertEqual(ReaderCommand.resolve(key: .upArrow, characters: ""), .slower)
        XCTAssertEqual(ReaderCommand.resolve(key: .downArrow, characters: ""), .faster)
        XCTAssertEqual(ReaderCommand.resolve(key: .leftArrow, characters: ""), .nudgeBackward)
        XCTAssertEqual(ReaderCommand.resolve(key: .rightArrow, characters: ""), .nudgeForward)
        XCTAssertEqual(ReaderCommand.resolve(key: .pageUp, characters: ""), .stepBackward)
        XCTAssertEqual(ReaderCommand.resolve(key: .pageDown, characters: ""), .stepForward)
        XCTAssertEqual(ReaderCommand.resolve(key: .escape, characters: ""), .exit)
        XCTAssertEqual(ReaderCommand.resolve(key: nil, characters: "?"), .shortcutsHelp)
        XCTAssertNil(ReaderCommand.resolve(key: nil, characters: "x"))
    }

    /// iOS reader presentation path for Speed countdown Off / 5 / 15:
    /// display sequences drive the pre-roll overlay; start policy decides whether
    /// Play enters countdown or starts immediately. Covers the pure presentation
    /// contract used by ``ReaderView.startPreRoll`` / ``togglePlay``.
    func testSpeedCountdownPresentationPathOffFiveAndFifteen() {
        XCTAssertEqual(SpeedCountdown.allCases, [.off, .fiveSeconds, .fifteenSeconds])

        // Off: empty sequence → startPreRoll falls through to play(); policy skips pre-roll.
        XCTAssertEqual(SpeedCountdown.off.displaySequence, [])
        XCTAssertEqual(SpeedCountdown.off.label, "Off")
        XCTAssertEqual(SpeedCountdown.off.shortLabel, "Off")
        XCTAssertFalse(
            SpeedModeStartPolicy.shouldBeginWithCountdown(
                mode: .speed,
                progress: 0,
                countdown: .off
            )
        )

        // 5 seconds: [5…1] overlay labels; policy starts countdown from the top.
        XCTAssertEqual(SpeedCountdown.fiveSeconds.displaySequence, [5, 4, 3, 2, 1])
        XCTAssertEqual(SpeedCountdown.fiveSeconds.label, "5 seconds")
        XCTAssertEqual(SpeedCountdown.fiveSeconds.shortLabel, "5s")
        XCTAssertTrue(
            SpeedModeStartPolicy.shouldBeginWithCountdown(
                mode: .speed,
                progress: 0,
                countdown: .fiveSeconds
            )
        )

        // 15 seconds: 15-step sequence; same start gate at progress 0.
        XCTAssertEqual(SpeedCountdown.fifteenSeconds.displaySequence.count, 15)
        XCTAssertEqual(SpeedCountdown.fifteenSeconds.displaySequence.first, 15)
        XCTAssertEqual(SpeedCountdown.fifteenSeconds.displaySequence.last, 1)
        XCTAssertEqual(SpeedCountdown.fifteenSeconds.label, "15 seconds")
        XCTAssertEqual(SpeedCountdown.fifteenSeconds.shortLabel, "15s")
        XCTAssertTrue(
            SpeedModeStartPolicy.shouldBeginWithCountdown(
                mode: .speed,
                progress: 0,
                countdown: .fifteenSeconds
            )
        )

        // Mid-script resume never pre-rolls for any countdown (matches ReaderView.play path).
        for countdown in SpeedCountdown.allCases {
            XCTAssertFalse(
                SpeedModeStartPolicy.shouldBeginWithCountdown(
                    mode: .speed,
                    progress: 0.2,
                    countdown: countdown
                ),
                "mid-script must skip countdown for \(countdown)"
            )
            XCTAssertFalse(
                SpeedModeStartPolicy.shouldBeginWithCountdown(
                    mode: .voice,
                    progress: 0,
                    countdown: countdown
                ),
                "voice mode must skip countdown for \(countdown)"
            )
        }

        // Pre-roll freezes prompter motion for every positive countdown (overlay path).
        XCTAssertFalse(
            ReaderBlackoutPlaybackPolicy.prompterIsEffectivelyPlaying(
                isPlaying: true,
                preRollActive: true,
                isBlackout: false
            )
        )
        XCTAssertTrue(
            ReaderBlackoutPlaybackPolicy.prompterIsEffectivelyPlaying(
                isPlaying: true,
                preRollActive: false,
                isBlackout: false
            )
        )
    }

    /// Permission denial copy must stay universal iOS (iPhone + iPad), never iPadOS-only.
    func testVoicePermissionCopyIsUniversalIOSNotDeviceSpecific() {
        for failure in [
            VoicePermissionFailure.microphoneDenied,
            VoicePermissionFailure.speechDenied
        ] {
            let message = failure.userMessage
            XCTAssertFalse(
                message.contains("iPadOS"),
                "denial copy must not name iPadOS only: \(message)"
            )
            XCTAssertTrue(
                message.contains("iOS will not ask again"),
                "denial copy must use universal iOS wording: \(message)"
            )
            XCTAssertTrue(message.contains("Privacy & Security"))
        }

        if case .requestError(let mic) = VoicePermissionGate.failureAfterMicrophonePrompt(
            granted: false,
            statusAfter: .undetermined
        ) {
            XCTAssertFalse(mic.contains("iPadOS"))
            XCTAssertTrue(mic.contains("when iOS asks"))
        } else {
            XCTFail("expected incomplete mic requestError")
        }

        if case .requestError(let speech) = VoicePermissionGate.failureAfterSpeechPrompt(
            status: .notDetermined
        ) {
            XCTAssertFalse(speech.contains("iPadOS"))
            XCTAssertTrue(speech.contains("when iOS asks"))
        } else {
            XCTFail("expected incomplete speech requestError")
        }
    }

    func testReaderThemesAreStrictlyMonochrome() {
        for theme in ReaderTheme.allCases {
            let bg = rgba(theme.uiBackground)
            let fg = rgba(theme.uiForeground)
            let accent = rgba(UIColor(theme.readerAccent))
            XCTAssertTrue(isMonochrome(bg), "theme \(theme.rawValue) background must be greyscale")
            XCTAssertTrue(isMonochrome(fg), "theme \(theme.rawValue) foreground must be greyscale")
            XCTAssertTrue(isMonochrome(accent), "theme \(theme.rawValue) accent must be greyscale")
            XCTAssertGreaterThan(
                contrastRatio(fg, bg),
                4.5,
                "theme \(theme.rawValue) must keep WCAG AA body contrast"
            )
        }

        // Paper is black/white inversion; stage stays pure black stage.
        assertRGBA(ReaderTheme.paper.uiBackground, r: 1, g: 1, b: 1)
        assertRGBA(ReaderTheme.paper.uiForeground, r: 0, g: 0, b: 0)
        assertRGBA(ReaderTheme.stage.uiBackground, r: 0, g: 0, b: 0)
        assertRGBA(ReaderTheme.stage.uiForeground, r: 1, g: 1, b: 1)
        assertRGBA(ReaderTheme.contrast.uiBackground, r: 0, g: 0, b: 0)
        assertRGBA(ReaderTheme.amber.uiBackground, r: 10 / 255, g: 10 / 255, b: 10 / 255)
        assertRGBA(ReaderTheme.sepia.uiBackground, r: 18 / 255, g: 18 / 255, b: 18 / 255)
        XCTAssertEqual(ReaderTheme.amber.label, "Elevated")
        XCTAssertEqual(ReaderTheme.sepia.label, "Dim")
        XCTAssertEqual(ReaderTheme.contrast.label, "High contrast")
    }

    private struct RGBA: Equatable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat
    }

    private func rgba(_ color: UIColor) -> RGBA {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return RGBA(r: r, g: g, b: b, a: a)
        }
        // Fallback for non-RGB models (e.g. white/black catalog colors).
        var w: CGFloat = 0
        if resolved.getWhite(&w, alpha: &a) {
            return RGBA(r: w, g: w, b: w, a: a)
        }
        XCTFail("could not read color components for \(resolved)")
        return RGBA(r: -1, g: -1, b: -1, a: -1)
    }

    private func assertRGBA(
        _ color: UIColor,
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        accuracy: CGFloat = 0.002,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = rgba(color)
        XCTAssertEqual(value.r, r, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(value.g, g, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(value.b, b, accuracy: accuracy, file: file, line: line)
    }

    private func isMonochrome(_ color: RGBA) -> Bool {
        abs(color.r - color.g) < 0.001 && abs(color.g - color.b) < 0.001
    }

    private func contrastRatio(_ a: RGBA, _ b: RGBA) -> CGFloat {
        func relativeLuminance(_ color: RGBA) -> CGFloat {
            func channel(_ c: CGFloat) -> CGFloat {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.r)
                + 0.7152 * channel(color.g)
                + 0.0722 * channel(color.b)
        }
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func testReaderOverlayBlackoutHasObviousEscapeAndAutoHidesChrome() {
        var state = ReaderOverlayState()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        ReaderOverlayReducer.reduce(&state, event: .playbackStarted, now: now)
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.isBlackout)
        XCTAssertEqual(state.hideControlsAt, now.addingTimeInterval(2.5))

        ReaderOverlayReducer.reduce(&state, event: .timerFired, now: now.addingTimeInterval(2.5))
        XCTAssertFalse(state.controlsVisible)

        ReaderOverlayReducer.reduce(&state, event: .toggleBlackout, now: now)
        XCTAssertTrue(state.isBlackout)
        XCTAssertFalse(state.controlsVisible)

        // Stage tap clears blackout and restores chrome.
        ReaderOverlayReducer.reduce(&state, event: .stageTapped, now: now)
        XCTAssertFalse(state.isBlackout)
        XCTAssertTrue(state.controlsVisible)
    }

    func testReaderSettingsLeadsWithDisplayMirrorAndFlip() {
        // Device feedback: flip / mirrored display is the first setting surface.
        XCTAssertEqual(ReaderSettingsPresentation.leadingSection, .display)
        XCTAssertEqual(ReaderSettingsPresentation.sectionOrder.first, .display)
        XCTAssertEqual(
            ReaderSettingsPresentation.sectionOrder,
            [
                .display,
                .looks,
                .theme,
                .typography,
                .layout,
                .playback,
                .voice,
                .pacing,
                .reset
            ]
        )
    }

    func testFreshInstallFocusLineDefaultIs25Percent() {
        XCTAssertEqual(ReaderSettings().focusPosition, 0.25, accuracy: 0.000_1)
    }

    func testEditorChromePlacesSaveStatusBesideScriptTitle() {
        XCTAssertTrue(EditorChromePresentation.saveStatusBesideTitle)
        XCTAssertTrue(EditorChromePresentation.saveStatusUsesQuietCaption)
        XCTAssertEqual(EditorChromePresentation.titleAccessibilityLabel, "Script title")
        XCTAssertEqual(EditorSaveState.saved.label, "Saved")
        XCTAssertEqual(EditorSaveState.saving.label, "Saving…")
        XCTAssertEqual(EditorSaveState.failed.label, "Save failed — retry")
    }

    func testOutlineReaderContentFiltersAndSpeaksPoints() {
        let points = [
            OutlinePoint(text: "  Hook  ", note: " smile "),
            OutlinePoint(text: "   ", note: "   "),
            OutlinePoint(text: "", note: "Only note")
        ]
        let meaningful = OutlineReaderContent.meaningfulPoints(from: points)
        XCTAssertEqual(meaningful.count, 2)
        XCTAssertEqual(OutlineReaderContent.primaryText(for: meaningful[0]), "Hook")
        XCTAssertEqual(OutlineReaderContent.supportingNote(for: meaningful[0]), "smile")
        XCTAssertEqual(OutlineReaderContent.spokenText(for: meaningful[0]), "Hook. smile")
        XCTAssertEqual(OutlineReaderContent.primaryText(for: meaningful[1]), "Only note")
        XCTAssertNil(OutlineReaderContent.supportingNote(for: meaningful[1]))
    }

    func testDocumentInsightsRemainMonotoneFriendly() {
        let insights = DocumentInsights(
            text: "One two three.\n\nFour five.",
            wordsPerMinute: 150
        )
        XCTAssertEqual(insights.wordCount, 5)
        XCTAssertEqual(insights.paragraphCount, 2)
        XCTAssertGreaterThan(insights.estimatedDuration, 0)
    }
}
