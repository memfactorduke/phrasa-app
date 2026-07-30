import AVFAudio
import Speech
import SwiftUI
import XCTest
@testable import Phrasa

final class ReaderSessionTests: XCTestCase {
    func testPacingClockAdvancesWithoutProgressOrTranscriptUpdates() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ReaderPacingClock.elapsed(
                elapsedBeforeStart: 12,
                startedAt: start,
                now: start.addingTimeInterval(8)
            ),
            20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderPacingClock.elapsed(
                elapsedBeforeStart: 12,
                startedAt: nil,
                now: start.addingTimeInterval(8)
            ),
            12,
            accuracy: 0.001
        )
    }

    func testReaderSettingsFlushWheneverTheSceneLeavesActiveUse() {
        XCTAssertFalse(ReaderSettingsPersistencePolicy.shouldFlush(for: .active))
        XCTAssertTrue(ReaderSettingsPersistencePolicy.shouldFlush(for: .inactive))
        XCTAssertTrue(ReaderSettingsPersistencePolicy.shouldFlush(for: .background))
    }

    func testReaderStaysPlayingWhileSpeechPermissionPromptIsInactive() {
        XCTAssertFalse(
            ReaderPlaybackLifecyclePolicy.shouldPause(
                for: .inactive,
                speechStatus: .requestingPermission
            )
        )
    }

    func testReaderPausesInBackgroundEvenWhileRequestingSpeechPermission() {
        XCTAssertTrue(
            ReaderPlaybackLifecyclePolicy.shouldPause(
                for: .background,
                speechStatus: .requestingPermission
            )
        )
    }

    func testReaderPausesWhenInactiveAfterSpeechPermissionRequest() {
        XCTAssertTrue(
            ReaderPlaybackLifecyclePolicy.shouldPause(
                for: .inactive,
                speechStatus: .starting
            )
        )
    }

    func testReaderPlaybackWaitsForTrackerAndBookmarkResolution() {
        XCTAssertFalse(
            ReaderSessionInteractionGate.allowsPlayback(
                sessionIsReady: false,
                hasTracker: false
            )
        )
        XCTAssertFalse(
            ReaderSessionInteractionGate.allowsPlayback(
                sessionIsReady: false,
                hasTracker: true
            )
        )
        XCTAssertFalse(
            ReaderSessionInteractionGate.allowsPlayback(
                sessionIsReady: true,
                hasTracker: false
            )
        )
        XCTAssertTrue(
            ReaderSessionInteractionGate.allowsPlayback(
                sessionIsReady: true,
                hasTracker: true
            )
        )
    }

    func testOnlyTerminalSpeechStatesStopReaderPlayback() {
        XCTAssertTrue(SpeechRecognitionService.Status.denied.shouldStopReaderPlayback)
        XCTAssertTrue(
            SpeechRecognitionService.Status.unavailable("Unavailable").shouldStopReaderPlayback
        )
        XCTAssertFalse(SpeechRecognitionService.Status.idle.shouldStopReaderPlayback)
        XCTAssertFalse(SpeechRecognitionService.Status.requestingPermission.shouldStopReaderPlayback)
        XCTAssertFalse(SpeechRecognitionService.Status.starting.shouldStopReaderPlayback)
        XCTAssertFalse(SpeechRecognitionService.Status.listening.shouldStopReaderPlayback)
    }

    func testSpeechRestartBackoffIsBounded() {
        XCTAssertEqual(SpeechRestartPolicy.delay(afterFailureCount: 0), .milliseconds(150))
        XCTAssertEqual(SpeechRestartPolicy.delay(afterFailureCount: 2), .milliseconds(1_350))
        XCTAssertEqual(SpeechRestartPolicy.delay(afterFailureCount: 10), .milliseconds(2_000))
    }

    // MARK: - Activation priority recovery (build 14)

    func testActivationRecoveryAttemptSemanticsAndBoundedDelay() {
        XCTAssertEqual(SpeechActivationRecovery.maxBeginAttempts, 4)
        XCTAssertEqual(SpeechActivationRecovery.retryDelaysMilliseconds, [150, 300, 600])
        XCTAssertEqual(SpeechActivationRecovery.totalBoundedDelayMilliseconds, 1_050)
        XCTAssertLessThan(SpeechActivationRecovery.totalBoundedDelayMilliseconds, 3_000)

        XCTAssertEqual(
            SpeechActivationRecovery.delayBeforeRetry(afterFailedAttempt: 1),
            .milliseconds(150)
        )
        XCTAssertEqual(
            SpeechActivationRecovery.delayBeforeRetry(afterFailedAttempt: 2),
            .milliseconds(300)
        )
        XCTAssertEqual(
            SpeechActivationRecovery.delayBeforeRetry(afterFailedAttempt: 3),
            .milliseconds(600)
        )
        // After 4th failed begin: budget exhausted — no further delay/retry.
        XCTAssertNil(SpeechActivationRecovery.delayBeforeRetry(afterFailedAttempt: 4))
        XCTAssertNil(SpeechActivationRecovery.delayBeforeRetry(afterFailedAttempt: 5))
        XCTAssertNil(SpeechActivationRecovery.delayBeforeRetry(afterFailedAttempt: 0))
        XCTAssertTrue(SpeechActivationRecovery.canRetry(afterFailedAttempt: 1))
        XCTAssertTrue(SpeechActivationRecovery.canRetry(afterFailedAttempt: 3))
        XCTAssertFalse(SpeechActivationRecovery.canRetry(afterFailedAttempt: 4))
    }

    func testActivationRecoveryClassifiesOnlyExactInsufficientPriority() {
        let pri = Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue)
        XCTAssertEqual(pri, 561_017_449)
        XCTAssertTrue(
            SpeechActivationRecovery.isPriorityContention(
                domain: "NSOSStatusErrorDomain",
                code: pri
            )
        )
        XCTAssertTrue(
            SpeechActivationRecovery.isPriorityContention(
                domain: "AVAudioSessionErrorDomain",
                code: pri
            )
        )
        // Related audio-session codes must not enter the activation retry path.
        for code in [
            Int(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue),
            Int(AVAudioSession.ErrorCode.isBusy.rawValue),
            Int(AVAudioSession.ErrorCode.cannotStartRecording.rawValue),
        ] {
            XCTAssertFalse(
                SpeechActivationRecovery.isPriorityContention(
                    domain: "NSOSStatusErrorDomain",
                    code: code
                ),
                "code \(code) must not be treated as priority contention"
            )
        }
        XCTAssertFalse(
            SpeechActivationRecovery.isPriorityContention(
                domain: "kAFAssistantErrorDomain",
                code: pri
            )
        )
        XCTAssertFalse(
            SpeechActivationRecovery.isPriorityContention(
                domain: "NSOSStatusErrorDomain",
                code: 1_700
            )
        )
    }

    func testActivationRecoveryExhaustionMessageIsStable() {
        let message = SpeechActivationRecovery.micInUseMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("microphone"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("another app") || message.localizedCaseInsensitiveContains("call"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("Play"))
        // Mid-session terminal classification reuses the same user-facing copy.
        XCTAssertEqual(
            SpeechRestartGovernor.userMessage(
                domain: "NSOSStatusErrorDomain",
                code: Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue),
                fallback: "ignored"
            ),
            message
        )
        // Exhausted budget is not schedulable.
        XCTAssertFalse(
            SpeechActivationRecovery.shouldScheduleRetry(
                domain: "NSOSStatusErrorDomain",
                code: Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue),
                failedAttempt: SpeechActivationRecovery.maxBeginAttempts,
                wantsRecognition: true,
                generationMatches: true,
                systemAudioBlocked: false,
                phase: .startingEngine
            )
        )
    }

    func testActivationRecoveryRetryGatesStopGenerationMismatchAndSystemAudio() {
        let pri = Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue)
        let domain = "NSOSStatusErrorDomain"

        XCTAssertTrue(
            SpeechActivationRecovery.shouldScheduleRetry(
                domain: domain,
                code: pri,
                failedAttempt: 1,
                wantsRecognition: true,
                generationMatches: true,
                systemAudioBlocked: false,
                phase: .startingEngine
            )
        )
        // stop() / wantsRecognition cleared.
        XCTAssertFalse(
            SpeechActivationRecovery.shouldScheduleRetry(
                domain: domain,
                code: pri,
                failedAttempt: 1,
                wantsRecognition: false,
                generationMatches: true,
                systemAudioBlocked: false,
                phase: .startingEngine
            )
        )
        // Generation mismatch after stop/new start.
        XCTAssertFalse(
            SpeechActivationRecovery.shouldScheduleRetry(
                domain: domain,
                code: pri,
                failedAttempt: 1,
                wantsRecognition: true,
                generationMatches: false,
                systemAudioBlocked: false,
                phase: .startingEngine
            )
        )
        // System-audio blocked gate.
        XCTAssertFalse(
            SpeechActivationRecovery.shouldScheduleRetry(
                domain: domain,
                code: pri,
                failedAttempt: 1,
                wantsRecognition: true,
                generationMatches: true,
                systemAudioBlocked: true,
                phase: .startingEngine
            )
        )
        // Permissions not ready.
        XCTAssertFalse(
            SpeechActivationRecovery.shouldScheduleRetry(
                domain: domain,
                code: pri,
                failedAttempt: 1,
                wantsRecognition: true,
                generationMatches: true,
                systemAudioBlocked: false,
                phase: .awaitingMicrophonePermission
            )
        )
        XCTAssertTrue(SpeechActivationRecovery.isPermissionsReady(.permissionsReady))
        XCTAssertTrue(SpeechActivationRecovery.isPermissionsReady(.startingEngine))
        XCTAssertTrue(SpeechActivationRecovery.isPermissionsReady(.live))
        XCTAssertFalse(SpeechActivationRecovery.isPermissionsReady(.idle))
        XCTAssertFalse(SpeechActivationRecovery.isPermissionsReady(.awaitingSpeechPermission))
    }

    func testActivationRecoveryDoesNotStackDuplicateBeginWhenResourcesPresent() {
        // Overlapping recovery paths both enter beginRecognition; canBegin blocks
        // a second request/task/tap while the first attempt still holds resources.
        XCTAssertFalse(
            SpeechCallbackGate.canBegin(
                wantsRecognition: true,
                run: 1,
                generation: 1,
                hasRecognitionRequest: true,
                hasRecognitionTask: false,
                tapInstalled: false
            )
        )
        XCTAssertFalse(
            SpeechCallbackGate.canBegin(
                wantsRecognition: true,
                run: 1,
                generation: 1,
                hasRecognitionRequest: false,
                hasRecognitionTask: true,
                tapInstalled: false
            )
        )
        XCTAssertFalse(
            SpeechCallbackGate.canBegin(
                wantsRecognition: true,
                run: 1,
                generation: 1,
                hasRecognitionRequest: false,
                hasRecognitionTask: false,
                tapInstalled: true
            )
        )
        // Fresh teardown between attempts allows exactly one new begin.
        XCTAssertTrue(
            SpeechCallbackGate.canBegin(
                wantsRecognition: true,
                run: 1,
                generation: 1,
                hasRecognitionRequest: false,
                hasRecognitionTask: false,
                tapInstalled: false
            )
        )
        // Non-priority errors never schedule activation retry.
        XCTAssertFalse(
            SpeechActivationRecovery.shouldScheduleRetry(
                domain: "NSOSStatusErrorDomain",
                code: Int(AVAudioSession.ErrorCode.cannotStartRecording.rawValue),
                failedAttempt: 1,
                wantsRecognition: true,
                generationMatches: true,
                systemAudioBlocked: false,
                phase: .startingEngine
            )
        )
    }

    // MARK: - Input format + teardown order (release red-team)

    func testSpeechInputFormatGateRejectsZeroChannelAndNonFiniteRates() {
        // AVAudioEngine installTap requires IsFormatSampleRateAndChannelCountValid.
        XCTAssertTrue(SpeechInputFormatGate.isValidForTap(sampleRate: 48_000, channelCount: 1))
        XCTAssertTrue(SpeechInputFormatGate.isValidForTap(sampleRate: 16_000, channelCount: 2))
        // Zero / negative rate.
        XCTAssertFalse(SpeechInputFormatGate.isValidForTap(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(SpeechInputFormatGate.isValidForTap(sampleRate: -44_100, channelCount: 1))
        // Zero channels with a positive rate still asserts in installTap.
        XCTAssertFalse(SpeechInputFormatGate.isValidForTap(sampleRate: 48_000, channelCount: 0))
        // Non-finite rates from a corrupted node format must not reach installTap.
        XCTAssertFalse(SpeechInputFormatGate.isValidForTap(sampleRate: .nan, channelCount: 1))
        XCTAssertFalse(SpeechInputFormatGate.isValidForTap(sampleRate: .infinity, channelCount: 1))
        XCTAssertFalse(
            SpeechInputFormatGate.isValidForTap(sampleRate: .nan, channelCount: 0),
            "combined invalid rate+channels must fail closed"
        )
    }

    func testTeardownHaltsAudioGraphBeforeEndingRecognitionRequest() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Phrasa/Speech/SpeechRecognitionService.swift")
        let source = try String(contentsOf: sourceRoot, encoding: .utf8)

        guard let teardownRange = source.range(of: "private func teardownSession(cancelTask: Bool)")
        else {
            return XCTFail("teardownSession must exist")
        }
        let body = String(source[teardownRange.lowerBound...])
        // Relative order: stop → removeTap → cancel task → endAudio.
        // Audio graph must halt before any request termination; cancel aborts
        // recognition before endAudio closes the request stream.
        guard let stopRange = body.range(of: "audioEngine.stop()") else {
            return XCTFail("teardown must stop the engine")
        }
        guard let removeRange = body.range(of: "removeTap(onBus: 0)") else {
            return XCTFail("teardown must remove the input tap")
        }
        guard let cancelRange = body.range(of: "recognitionTask?.cancel()") else {
            return XCTFail("teardown must cancel the recognition task when requested")
        }
        guard let endAudioRange = body.range(of: "recognitionRequest?.endAudio()") else {
            return XCTFail("teardown must end the recognition request")
        }
        XCTAssertLessThan(stopRange.lowerBound, removeRange.lowerBound, "stop engine before removeTap")
        XCTAssertLessThan(
            removeRange.lowerBound,
            cancelRange.lowerBound,
            "removeTap before cancel so tap cannot append after task abort"
        )
        XCTAssertLessThan(
            cancelRange.lowerBound,
            endAudioRange.lowerBound,
            "cancel task before endAudio (abort, then close request stream)"
        )
    }

    func testBeginRecognitionUsesFormatGateAndAlwaysAbandonsRecoveredAudioGraph() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Phrasa/Speech/SpeechRecognitionService.swift")
        let source = try String(contentsOf: sourceRoot, encoding: .utf8)
        XCTAssertTrue(
            source.contains("SpeechInputFormatGate.isValidForTap"),
            "beginRecognition must validate input format before installTap"
        )
        XCTAssertTrue(
            source.contains("channelCount: format.channelCount"),
            "channel count must participate in the installTap validity check"
        )
        XCTAssertTrue(
            source.contains("if systemAudioGate.mediaServicesLost"),
            "live tear-down must abandon engine on media-services loss"
        )
        XCTAssertTrue(
            source.contains("self.systemAudioGate.takeRecoveryWork(id: id) != nil"),
            "recovery must reject stale work before replacing the audio graph"
        )
        XCTAssertFalse(
            source.contains("if replaceEngine { self.replaceAudioEngine() }"),
            "route and interruption recovery must not reuse an audio graph with a stale hidden tap"
        )
        // replaceAudioEngine is used immediately after media loss and for every
        // accepted recovery, including route and interruption recovery.
        let replaceCount = source.components(separatedBy: "replaceAudioEngine()").count - 1
        XCTAssertGreaterThanOrEqual(
            replaceCount,
            2,
            "media-services loss tear-down and every accepted recovery must replace the engine"
        )
    }

    #if DEBUG
    @MainActor
    func testStopClearsArmedPendingRestartTask() {
        // Deterministic proof: arm an inert restartTask via DEBUG seam, then stop()
        // must cancel + clear it through cancelSpeechLifecycleTasks (central path).
        // Does not depend on mic/session activation (which cannot arm !pri retries
        // under permission denial).
        let service = SpeechRecognitionService(
            speechPermissionRequester: { $0(.denied) },
            microphonePermissionRequester: { $0(false) }
        )
        XCTAssertFalse(service.hasPendingRestartTaskForTests)
        service.armPendingRestartTaskForTests()
        XCTAssertTrue(
            service.hasPendingRestartTaskForTests,
            "DEBUG seam must arm a pending restartTask for cancellation proof"
        )
        service.stop()
        XCTAssertFalse(
            service.hasPendingRestartTaskForTests,
            "stop() must cancel and clear restartTask via cancelSpeechLifecycleTasks"
        )
        XCTAssertEqual(service.activationAttemptCountForTests, 0)
        XCTAssertEqual(service.status, .idle)
    }
    #endif
    private let scriptID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let recapID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testContentSignatureIsStableAndSensitiveToEdits() {
        XCTAssertEqual(
            ReaderContentSignature.make(for: "Hello, world."),
            ReaderContentSignature.make(for: "Hello, world.")
        )
        XCTAssertNotEqual(
            ReaderContentSignature.make(for: "Hello, world."),
            ReaderContentSignature.make(for: "Hello world.")
        )
    }

    func testBookmarkOnlyResumesUnchangedIncompleteScript() {
        let bookmark = ReaderBookmark(
            scriptID: scriptID,
            contentSignature: ReaderContentSignature.make(for: "Original"),
            progress: 0.42,
            focusTokenIndex: 4,
            mode: .voice,
            speedWPM: 155,
            elapsedActiveTime: 12,
            updatedAt: start
        )

        XCTAssertTrue(bookmark.isResumeEligible(for: "Original"))
        XCTAssertFalse(bookmark.isResumeEligible(for: "Edited"))
        XCTAssertEqual(bookmark.focusTokenIndex, 4)
        XCTAssertEqual(bookmark.mode, .voice)
        XCTAssertEqual(bookmark.speedWPM, 155)

        var nearlyDone = bookmark
        nearlyDone.progress = 0.999
        XCTAssertFalse(nearlyDone.isResumeEligible(for: "Original"))
    }

    func testBookmarkMigratesLegacyArchiveAndRoundTripsDomainContext() throws {
        let script = ScriptDocument(
            id: scriptID,
            title: "Talk",
            body: "one two three four five six"
        )
        // Legacy v1 payload: scalar progress + body hash only (no mode/token fields).
        struct LegacyBookmark: Encodable {
            var scriptID: UUID
            var contentSignature: String
            var progress: Double
            var elapsedActiveTime: TimeInterval
            var activeRunCount: Int
            var updatedAt: Date
        }
        let legacyData = try JSONEncoder().encode(
            LegacyBookmark(
                scriptID: scriptID,
                contentSignature: ReaderContentSignature.make(for: script.body),
                progress: 0.4,
                elapsedActiveTime: 12,
                activeRunCount: 1,
                updatedAt: start
            )
        )
        let legacy = try JSONDecoder().decode(ReaderBookmark.self, from: legacyData)
        XCTAssertEqual(legacy.progress, 0.4, accuracy: 0.0001)
        XCTAssertEqual(legacy.mode, .speed)
        XCTAssertEqual(legacy.speedWPM, 140)
        XCTAssertTrue(legacy.isResumeEligible(for: script.body))

        let modern = ReaderBookmark.make(
            script: script,
            progress: 0.5,
            focusTokenIndex: 3,
            mode: .voice,
            speedWPM: 170,
            elapsedActiveTime: 20,
            activeRunCount: 2,
            updatedAt: start
        )
        XCTAssertEqual(modern.domainContentSignature, ScriptContentSignature.make(script))
        XCTAssertTrue(modern.isResumeEligible(for: script))
        let domain = modern.domainResume(for: script)
        XCTAssertEqual(domain.focusTokenIndex, 3)
        XCTAssertEqual(domain.mode, .voice)
        XCTAssertEqual(domain.speedWPM, 170)
        XCTAssertEqual(domain.speedProgress, 0.5)

        let encoded = try JSONEncoder().encode(modern)
        let decoded = try JSONDecoder().decode(ReaderBookmark.self, from: encoded)
        XCTAssertEqual(decoded.focusTokenIndex, 3)
        XCTAssertEqual(decoded.mode, .voice)
        XCTAssertEqual(decoded.speedWPM, 170)
        XCTAssertEqual(decoded.domainContentSignature, modern.domainContentSignature)
    }

    func testTrackerAccumulatesActiveTimeAcrossResumeAndBuildsRecap() {
        let body = Array(repeating: "word", count: 100).joined(separator: " ")
        var firstRun = ReaderSessionTracker(scriptID: scriptID, body: body)
        firstRun.start(at: start)
        firstRun.update(progress: 0.4)
        let bookmark = firstRun.pause(at: start.addingTimeInterval(20))

        var resumed = ReaderSessionTracker(scriptID: scriptID, body: body, bookmark: bookmark)
        XCTAssertEqual(resumed.progress, 0.4, accuracy: 0.0001)
        XCTAssertTrue(resumed.wasResumed)
        resumed.start(at: start.addingTimeInterval(60))
        let recap = resumed.complete(
            at: start.addingTimeInterval(100),
            targetDuration: 55,
            recapID: recapID
        )

        XCTAssertEqual(recap.activeTime, 60, accuracy: 0.001)
        XCTAssertEqual(recap.wordCount, 100)
        XCTAssertEqual(recap.averageWordsPerMinute, 100, accuracy: 0.001)
        XCTAssertEqual(recap.targetDelta ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(recap.activeRunCount, 2)
        XCTAssertTrue(recap.wasResumed)
    }

    func testTrackerIgnoresMismatchedBookmarkAndClampsProgress() {
        let bookmark = ReaderBookmark(
            scriptID: scriptID,
            contentSignature: ReaderContentSignature.make(for: "Old text"),
            progress: 0.6,
            elapsedActiveTime: 30,
            updatedAt: start
        )
        var tracker = ReaderSessionTracker(scriptID: scriptID, body: "New text", bookmark: bookmark)
        XCTAssertEqual(tracker.progress, 0)
        XCTAssertFalse(tracker.wasResumed)
        tracker.update(progress: 2)
        XCTAssertEqual(tracker.progress, 1)
    }

    func testClosingBeforePlaybackDoesNotReplaceAnUnresolvedBookmark() {
        var fresh = ReaderSessionTracker(scriptID: scriptID, body: "Saved script")
        XCTAssertFalse(ReaderBookmarkPersistencePolicy.shouldSaveAfterPause(fresh))
        _ = fresh.pause(at: start)
        XCTAssertFalse(ReaderBookmarkPersistencePolicy.shouldSaveAfterPause(fresh))

        fresh.start(at: start.addingTimeInterval(1))
        XCTAssertTrue(ReaderBookmarkPersistencePolicy.shouldSaveAfterPause(fresh))
    }

    func testOverlayAutoHideAndBlackoutEscapeAreDeterministic() {
        var state = ReaderOverlayState()
        ReaderOverlayReducer.reduce(&state, event: .playbackStarted, now: start, autoHideDelay: 2)
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.controlsVisible)

        ReaderOverlayReducer.reduce(
            &state,
            event: .timerFired,
            now: start.addingTimeInterval(1.9),
            autoHideDelay: 2
        )
        XCTAssertTrue(state.controlsVisible)
        ReaderOverlayReducer.reduce(
            &state,
            event: .timerFired,
            now: start.addingTimeInterval(2),
            autoHideDelay: 2
        )
        XCTAssertFalse(state.controlsVisible)

        ReaderOverlayReducer.reduce(&state, event: .toggleBlackout, now: start)
        XCTAssertTrue(state.isBlackout)
        ReaderOverlayReducer.reduce(&state, event: .stageTapped, now: start)
        XCTAssertFalse(state.isBlackout)
        XCTAssertTrue(state.controlsVisible)
    }

    func testSessionStoreRoundTripsBookmarkRecapAndStatistics() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-sessions-\(UUID().uuidString).json")
        let body = "one two three four"
        let bookmark = ReaderBookmark(
            scriptID: scriptID,
            contentSignature: ReaderContentSignature.make(for: body),
            progress: 0.5,
            elapsedActiveTime: 12,
            activeRunCount: 1,
            updatedAt: start
        )
        let firstStore = ReaderSessionStore(fileURL: url)
        try await firstStore.save(bookmark: bookmark)

        let secondStore = ReaderSessionStore(fileURL: url)
        let loaded = try await secondStore.bookmark(for: scriptID, matchingBody: body)
        XCTAssertEqual(loaded, bookmark)
        let stale = try await secondStore.bookmark(for: scriptID, matchingBody: "edited")
        XCTAssertNil(stale)

        let recap = ReaderCompletionRecap(
            id: recapID,
            scriptID: scriptID,
            completedAt: start.addingTimeInterval(12),
            activeTime: 12,
            wordCount: 40,
            targetDuration: 10,
            activeRunCount: 1,
            wasResumed: false
        )
        try await secondStore.save(recap: recap)
        let clearedBookmark = try await secondStore.bookmark(for: scriptID, matchingBody: body)
        let recaps = try await secondStore.recentRecaps()
        XCTAssertNil(clearedBookmark)
        XCTAssertEqual(recaps, [recap])

        let statistics = try await secondStore.statistics()
        XCTAssertEqual(statistics.completedSessions, 1)
        XCTAssertEqual(statistics.totalActiveTime, 12, accuracy: 0.001)
        XCTAssertEqual(statistics.totalWordsPresented, 40)
        XCTAssertEqual(statistics.averageWordsPerMinute, 200, accuracy: 0.001)
    }

    func testCorruptSessionArchiveIsPreservedThenReaderProgressResets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-recovery-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("reader-sessions.json")
        let corruptData = Data("not valid reader json".utf8)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try corruptData.write(to: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ReaderSessionStore(fileURL: url)
        do {
            _ = try await store.recentRecaps()
            XCTFail("Expected the first corrupt read to report recovery")
        } catch {
            XCTAssertEqual(error as? ReaderSessionStore.StoreError, .unreadableData)
        }

        let recoveryURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("recovery-") }
        XCTAssertEqual(recoveryURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(recoveryURLs.first)), corruptData)

        let resetRecaps = try await store.recentRecaps()
        XCTAssertTrue(resetRecaps.isEmpty)
        let reopened = ReaderSessionStore(fileURL: url)
        let reopenedRecaps = try await reopened.recentRecaps()
        XCTAssertTrue(reopenedRecaps.isEmpty)
    }

    @MainActor
    func testSessionMutationQueuePreservesRestartAfterASlowBookmarkSave() async {
        let recorder = ReaderMutationRecorder()
        let queue = ReaderSessionMutationQueue()

        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(40))
            await recorder.append("bookmark")
        }
        queue.enqueue {
            await recorder.append("clear")
        }

        await queue.waitForAll()
        let events = await recorder.events()
        XCTAssertEqual(events, ["bookmark", "clear"])
    }

    @MainActor
    func testSpeechServiceStartHandlesBackgroundPermissionCallbacks() async {
        final class Status: @unchecked Sendable {
            var mic: AVAudioApplication.recordPermission = .undetermined
        }
        let status = Status()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { resume in
                DispatchQueue.global(qos: .userInitiated).async {
                    resume(.authorized)
                }
            },
            microphonePermissionRequester: { resume in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Real TCC flips to denied when the user refuses the prompt.
                    status.mic = .denied
                    resume(false)
                }
            },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { status.mic }
        )
        await service.start(language: "en-US") { _ in }
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(service.lastPermissionFailure, .microphoneDenied)
        XCTAssertEqual(
            service.health,
            .terminalFailure(VoicePermissionFailure.microphoneDenied.userMessage)
        )
    }

    // MARK: - Speech rolling tail (pure)

    func testSpeechRollingTailGrowsCumulativelyWithinATask() {
        var normalizer = SpeechRollingTailNormalizer(maxTailWords: 12)
        XCTAssertEqual(
            normalizer.apply(segments: [Self.seg("hello")], isFinal: false, at: 1),
            "hello"
        )
        XCTAssertEqual(
            normalizer.apply(
                segments: [Self.seg("hello"), Self.seg("world"), Self.seg("today")],
                isFinal: false,
                at: 1.2
            ),
            "hello world today"
        )
    }

    func testSpeechRollingTailRewritesSameTaskHypothesis() {
        var normalizer = SpeechRollingTailNormalizer(maxTailWords: 12)
        _ = normalizer.apply(
            segments: [Self.seg("hello"), Self.seg("world")],
            isFinal: false,
            at: 1
        )
        XCTAssertEqual(
            normalizer.apply(
                segments: [Self.seg("hello"), Self.seg("word")],
                isFinal: false,
                at: 1.1
            ),
            "hello word"
        )
    }

    func testSpeechRollingTailSurvivesTaskRotation() {
        var normalizer = SpeechRollingTailNormalizer(maxTailWords: 12)
        _ = normalizer.apply(
            segments: [Self.seg("one"), Self.seg("two")],
            isFinal: true,
            at: 1
        )
        normalizer.rotateTask()
        XCTAssertEqual(
            normalizer.apply(segments: [Self.seg("three")], isFinal: false, at: 1.5),
            "one two three"
        )
        XCTAssertEqual(normalizer.taskOrdinal, 1)
    }

    func testSpeechRollingTailFlushesAfterEightSecondPause() {
        var normalizer = SpeechRollingTailNormalizer(maxTailWords: 12, silenceFlushSeconds: 8)
        _ = normalizer.apply(
            segments: [Self.seg("stale"), Self.seg("context")],
            isFinal: true,
            at: 10
        )
        XCTAssertEqual(
            normalizer.apply(segments: [Self.seg("fresh")], isFinal: false, at: 18),
            "fresh"
        )
        XCTAssertEqual(
            normalizer.apply(
                segments: [Self.seg("fresh"), Self.seg("words")],
                isFinal: false,
                at: 20
            ),
            "fresh words"
        )
        XCTAssertEqual(
            normalizer.apply(
                segments: [Self.seg("fresh"), Self.seg("words"), Self.seg("kept")],
                isFinal: false,
                at: 27.9
            ),
            "fresh words kept"
        )
    }

    func testSpeechRollingTailIsBoundedAndNotWholeSession() {
        var normalizer = SpeechRollingTailNormalizer(maxTailWords: 4)
        let many = (0..<20).map { Self.seg("w\($0)") }
        let tail = normalizer.apply(segments: many, isFinal: false, at: 1)
        XCTAssertEqual(tail, "w16 w17 w18 w19")
        XCTAssertEqual(normalizer.currentTask.count, 4)
    }

    // MARK: - Snapshot bound (finding 1)

    func testRecognitionCallbackSnapshotBoundsSegmentSuffix() {
        XCTAssertEqual(RecognitionCallbackSnapshot.maxCapturedSegments, 32)
        let many = (0..<100).map { index in
            Self.seg("w\(index)", timestamp: Double(index) * 0.1, duration: 0.1)
        }
        let clipped = RecognitionCallbackSnapshot.clipSegments(many)
        XCTAssertEqual(clipped.count, RecognitionCallbackSnapshot.maxCapturedSegments)
        XCTAssertEqual(clipped.first?.substring, "w68")
        XCTAssertEqual(clipped.last?.substring, "w99")
        XCTAssertLessThanOrEqual(
            clipped.count,
            RecognitionCallbackSnapshot.maxCapturedSegments
        )
    }

    func testRecognitionCallbackSnapshotIsSendableValueType() {
        let snapshot = RecognitionCallbackSnapshot(
            segments: [Self.seg("hello"), Self.seg("world")],
            totalSegmentCount: 2,
            isFinal: false,
            errorDomain: nil,
            errorCode: nil,
            errorDescription: nil,
            receivedAt: 42
        )
        XCTAssertEqual(snapshot.segments.count, 2)
        XCTAssertEqual(snapshot.segments[0].substring, "hello")
        XCTAssertFalse(snapshot.isFinal)

        let withError = RecognitionCallbackSnapshot(
            segments: [Self.seg("partial")],
            totalSegmentCount: 1,
            isFinal: false,
            errorDomain: "kAFAssistantErrorDomain",
            errorCode: 203,
            errorDescription: "fail",
            receivedAt: 43
        )
        XCTAssertEqual(withError.errorCode, 203)
        XCTAssertEqual(withError.errorDomain, "kAFAssistantErrorDomain")
    }

    // MARK: - Context hints (finding 6)

    func testSpeechContextHintsRequireFourCharTermsInDocumentOrder() {
        let script = """
        a to of the and Alpha alpha ALPHA café cafe \
        Quantum entanglement Quantum bridge-bridge hi me
        """
        let hints = SpeechContextHints.make(from: script)
        XCTAssertLessThanOrEqual(hints.count, SpeechContextHints.maxCount)
        XCTAssertTrue(hints.allSatisfy { $0.count <= SpeechContextHints.maxLength })
        XCTAssertTrue(hints.allSatisfy { $0.count >= SpeechContextHints.minTermLength })
        // Short noise never admitted.
        XCTAssertFalse(hints.contains("a"))
        XCTAssertFalse(hints.contains("to"))
        XCTAssertFalse(hints.contains("of"))
        XCTAssertFalse(hints.contains("the"))
        XCTAssertFalse(hints.contains("and"))
        XCTAssertFalse(hints.contains("hi"))
        XCTAssertFalse(hints.contains("me"))
        // Document-order first meaningful term.
        XCTAssertEqual(hints.first, "Alpha")
        // Case/diacritic-insensitive dedupe.
        let folded = hints.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
        }
        XCTAssertEqual(folded.filter { $0 == "alpha" }.count, 1)
        XCTAssertEqual(folded.filter { $0 == "cafe" || $0 == "café" }.count, 1)
        XCTAssertTrue(hints.contains("Quantum"))
        XCTAssertTrue(hints.contains("entanglement"))
        // No n-gram flood: each entry is a single token (no spaces).
        XCTAssertTrue(hints.allSatisfy { !$0.contains(" ") })
    }

    func testSpeechContextHintsHardCapAtEightyPreservesOrder() {
        let words = (0..<200).map { "Term\($0)xyz" }.joined(separator: " ")
        let hints = SpeechContextHints.make(from: words)
        XCTAssertEqual(hints.count, SpeechContextHints.maxCount)
        XCTAssertEqual(hints.first, "Term0xyz")
        XCTAssertEqual(hints.last, "Term79xyz")
        XCTAssertTrue(hints.allSatisfy { $0.count <= 100 })
        XCTAssertTrue(hints.allSatisfy { $0.count >= 4 })
    }

    // MARK: - Evidence (finding 3)

    func testSpeechEvidenceDoesNotDoubleCountCumulativePartialDurations() {
        var evidence = SpeechSessionEvidence()
        // Cumulative partials re-emit prior segments — durations must not sum.
        let partial1 = [
            Self.seg("hello", timestamp: 0.0, duration: 0.4),
            Self.seg("world", timestamp: 0.4, duration: 0.4),
        ]
        let partial2 = [
            Self.seg("hello", timestamp: 0.0, duration: 0.4),
            Self.seg("world", timestamp: 0.4, duration: 0.4),
            Self.seg("today", timestamp: 0.8, duration: 0.4),
        ]
        evidence.note(segments: partial1, isFinal: false, at: 1.0)
        evidence.note(segments: partial2, isFinal: false, at: 1.3)
        // Unique extent of latest hypothesis is ~1.2, not 0.8+1.2 additive.
        XCTAssertEqual(evidence.maxHypothesisExtent, 1.2, accuracy: 0.001)
        XCTAssertEqual(evidence.partialCount, 2)
        XCTAssertEqual(evidence.wordCount, 3)
    }

    func testSpeechEvidenceLonePartialIsNeverMeaningful() {
        var evidence = SpeechSessionEvidence()
        // One partial with many cumulative segments and large individual durations.
        let segments = (0..<8).map { index in
            Self.seg("w\(index)", timestamp: Double(index) * 0.3, duration: 0.5)
        }
        evidence.note(segments: segments, isFinal: false, at: 0)
        XCTAssertFalse(evidence.isMeaningful, "lone partial must never clear a failure budget")
        XCTAssertEqual(evidence.partialCount, 1)
        // Extent reflects unique utterance window, not sum of durations (8 * 0.5 = 4).
        XCTAssertLessThan(evidence.maxHypothesisExtent, 4.0)
        XCTAssertEqual(evidence.maxHypothesisExtent, 2.6, accuracy: 0.01)
    }

    func testSpeechEvidenceSustainedPartialsBecomeMeaningful() {
        var evidence = SpeechSessionEvidence()
        evidence.note(
            segments: [
                Self.seg("alpha", timestamp: 0, duration: 0.3),
                Self.seg("bravo", timestamp: 0.3, duration: 0.3),
            ],
            isFinal: false,
            at: 0
        )
        evidence.note(
            segments: [
                Self.seg("alpha", timestamp: 0, duration: 0.3),
                Self.seg("bravo", timestamp: 0.3, duration: 0.3),
                Self.seg("charlie", timestamp: 0.6, duration: 0.3),
            ],
            isFinal: false,
            at: 0.7
        )
        XCTAssertTrue(evidence.isMeaningful)
    }

    // MARK: - Restart governance (findings 2, 4, 8)

    func testSpeechGovernanceHealthyFinalWithMeaningfulSpeechResetsBudget() {
        var governor = SpeechRestartGovernor()
        governor.beginSession(at: 0)
        for (index, _) in ["alpha", "bravo", "charlie", "delta"].enumerated() {
            let words = Array(["alpha", "bravo", "charlie", "delta"].prefix(index + 1))
            let segs = words.enumerated().map { i, w in
                Self.seg(w, timestamp: Double(i) * 0.25, duration: 0.2)
            }
            governor.noteRecognition(segments: segs, isFinal: false, at: Double(index) * 0.3)
        }
        XCTAssertTrue(governor.evidence.isMeaningful)
        let plan = governor.endSession(reason: .healthyFinal, at: 1.2)
        XCTAssertEqual(plan, .restart(delay: SpeechRestartPolicy.delay(afterFailureCount: 0)))
        XCTAssertEqual(governor.failureCount, 0)
        XCTAssertEqual(governor.noSpeechCount, 0)
    }

    func testSpeechGovernanceManyConsecutiveNoSpeechRemainRestartable() {
        var governor = SpeechRestartGovernor()
        // Silence may be indefinite — 20+ rotations must never terminal.
        for step in 0..<20 {
            governor.beginSession(at: Double(step))
            let plan = governor.endSession(reason: .noSpeech, at: Double(step) + 0.1)
            guard case .restart = plan else {
                return XCTFail("no-speech rotation \(step) must remain restartable, got \(plan)")
            }
        }
        XCTAssertEqual(governor.noSpeechCount, 20)
        XCTAssertEqual(governor.failureCount, 0, "no-speech must not spend failure budget")
        XCTAssertEqual(governor.shortLoopCount, 0, "no-speech must not spend short-loop budget")
    }

    func testSpeechGovernanceNoSpeechAfterLonePartialIsNotTerminalAndDoesNotResetFailures() {
        var governor = SpeechRestartGovernor()
        // Seed a recoverable failure first.
        governor.beginSession(at: 0)
        governor.noteRecognition(segments: [Self.seg("uh")], isFinal: false, at: 0.05)
        let afterError = governor.endSession(
            reason: .recoverableError(domain: "kAFAssistantErrorDomain", code: 203, message: "fail"),
            at: 0.1
        )
        guard case .restart = afterError else {
            return XCTFail("expected restart after first recoverable error")
        }
        XCTAssertEqual(governor.failureCount, 1)

        // No-speech after a lone partial: not terminal; must not erase the failure count.
        governor.beginSession(at: 1)
        governor.noteRecognition(segments: [Self.seg("uh")], isFinal: false, at: 1.05)
        let afterSilence = governor.endSession(reason: .noSpeech, at: 1.2)
        guard case .restart = afterSilence else {
            return XCTFail("no-speech after partial must restart, not terminal")
        }
        XCTAssertEqual(governor.failureCount, 1, "lone partial + no-speech must not reset failure budget")
        XCTAssertFalse(governor.evidence.isMeaningful)
    }

    func testSpeechGovernancePartialBeforeErrorStillConsumesFailureBudget() {
        var governor = SpeechRestartGovernor()
        var terminal: SpeechRestartPlan?
        for step in 0..<(SpeechRestartGovernor.maxFailures + 2) {
            let t0 = Double(step) * 2
            governor.beginSession(at: t0)
            governor.noteRecognition(segments: [Self.seg("uh")], isFinal: false, at: t0 + 0.05)
            XCTAssertFalse(governor.evidence.isMeaningful)
            let plan = governor.endSession(
                reason: .recoverableError(domain: "kAFAssistantErrorDomain", code: 203, message: "fail"),
                at: t0 + 0.1
            )
            if case .terminal = plan {
                terminal = plan
                break
            }
        }
        XCTAssertNotNil(terminal, "genuine repeated recoverable errors must eventually terminal")
    }

    func testSpeechGovernanceClassifiesExactDomainCodes() {
        // Exact no-speech.
        XCTAssertEqual(
            SpeechRestartGovernor.classifyError(
                domain: "kAFAssistantErrorDomain",
                code: 1110,
                message: "whatever localized"
            ),
            .noSpeech
        )
        // Unrelated-domain 1110 is recoverable, not no-speech.
        let wrongDomain1110 = SpeechRestartGovernor.classifyError(
            domain: "SomeOtherDomain",
            code: 1110,
            message: "nope"
        )
        guard case .recoverableError(let d1, let c1, _) = wrongDomain1110 else {
            return XCTFail("unrelated-domain 1110 must be recoverable, got \(wrongDomain1110)")
        }
        XCTAssertEqual(d1, "SomeOtherDomain")
        XCTAssertEqual(c1, 1110)

        // Speech-domain 6/10 must NOT be treated as terminal authorization.
        for code in [6, 10] {
            let reason = SpeechRestartGovernor.classifyError(
                domain: "SFSpeechErrorDomain",
                code: code,
                message: "not auth"
            )
            guard case .recoverableError = reason else {
                return XCTFail("SFSpeechErrorDomain \(code) must be recoverable, got \(reason)")
            }
        }

        // Exact kAFAssistantErrorDomain 1700 is terminal auth.
        let terminal = SpeechRestartGovernor.classifyError(
            domain: "kAFAssistantErrorDomain",
            code: 1700,
            message: "not the classifier input"
        )
        guard case .terminalError(let domain, let code, _) = terminal else {
            return XCTFail("Expected terminal authorization error")
        }
        XCTAssertEqual(domain, "kAFAssistantErrorDomain")
        XCTAssertEqual(code, 1700)

        // SFSpeechErrorDomain audioReadFailed (2) is terminal; internal/timeout recoverable.
        let audioRead = SpeechRestartGovernor.classifyError(
            domain: "SFSpeechErrorDomain",
            code: 2,
            message: "audio"
        )
        guard case .terminalError(_, let audioCode, _) = audioRead else {
            return XCTFail("audioReadFailed must be terminal")
        }
        XCTAssertEqual(audioCode, 2)

        for recoverableCode in [1, 12] {
            let reason = SpeechRestartGovernor.classifyError(
                domain: "SFSpeechErrorDomain",
                code: recoverableCode,
                message: "transient"
            )
            guard case .recoverableError = reason else {
                return XCTFail("SFSpeechErrorDomain \(recoverableCode) must be recoverable")
            }
        }

        let recoverable = SpeechRestartGovernor.classifyError(
            domain: "kAFAssistantErrorDomain",
            code: 1107,
            message: "interrupted"
        )
        guard case .recoverableError = recoverable else {
            return XCTFail("Expected recoverable connection error")
        }
    }

    func testSpeechGovernanceTerminalAuthorizationDoesNotRestart() {
        var governor = SpeechRestartGovernor()
        governor.beginSession(at: 0)
        let plan = governor.endSession(
            reason: .terminalError(
                domain: "kAFAssistantErrorDomain",
                code: 1700,
                message: "Speech recognition is not authorized. Check Settings, or use Speed mode."
            ),
            at: 0.2
        )
        guard case .terminal(let message) = plan else {
            return XCTFail("Expected terminal plan")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("authorized"))
    }

    func testSpeechGovernanceMeaningfulSpeechResetsNoSpeechBackoff() {
        var governor = SpeechRestartGovernor()
        for step in 0..<4 {
            governor.beginSession(at: Double(step))
            _ = governor.endSession(reason: .noSpeech, at: Double(step) + 0.1)
        }
        XCTAssertEqual(governor.noSpeechCount, 4)

        governor.beginSession(at: 10)
        for (index, _) in ["alpha", "bravo", "charlie"].enumerated() {
            let words = Array(["alpha", "bravo", "charlie"].prefix(index + 1))
            let segs = words.enumerated().map { i, w in
                Self.seg(w, timestamp: Double(i) * 0.3, duration: 0.25)
            }
            governor.noteRecognition(segments: segs, isFinal: false, at: 10 + Double(index) * 0.4)
        }
        XCTAssertTrue(governor.evidence.isMeaningful)
        XCTAssertEqual(governor.noSpeechCount, 0, "meaningful speech resets no-speech backoff")
    }

    // MARK: - Event emission (finding 5)

    func testSpeechEventEmissionDedupesIdenticalLifecycleEvents() {
        let first = SpeechEventEmission.nextEvent(
            previous: nil,
            tail: "",
            health: .starting,
            status: .requestingPermission
        )
        XCTAssertEqual(first?.health, .starting)
        XCTAssertEqual(first?.status, .requestingPermission)

        let dup = SpeechEventEmission.nextEvent(
            previous: first,
            tail: "",
            health: .starting,
            status: .requestingPermission
        )
        XCTAssertNil(dup, "identical lifecycle events must not re-emit")

        let next = SpeechEventEmission.nextEvent(
            previous: first,
            tail: "",
            health: .terminalFailure("denied"),
            status: .denied
        )
        XCTAssertEqual(next?.status, .denied)
        if case .terminalFailure = next?.health {
            // ok
        } else {
            XCTFail("expected terminalFailure health")
        }
    }

    func testSpeechEventEmissionCoversRecoveringAndInactiveTransitions() {
        var previous: SpeechPipelineEvent?
        let sequence: [(String, SpeechPipelineHealth, SpeechRecognitionService.Status)] = [
            ("", .starting, .starting),
            ("", .recovering, .starting),
            ("hello", .hearingSpeech, .listening),
            ("", .inactive, .idle),
        ]
        var emitted: [SpeechPipelineEvent] = []
        for (tail, health, status) in sequence {
            if let event = SpeechEventEmission.nextEvent(
                previous: previous,
                tail: tail,
                health: health,
                status: status
            ) {
                emitted.append(event)
                previous = event
            }
        }
        XCTAssertEqual(emitted.count, 4)
        XCTAssertEqual(emitted.map(\.health), [
            .starting, .recovering, .hearingSpeech, .inactive,
        ])
    }

    @MainActor
    func testSpeechServiceEmitsLifecycleEventsOnDeniedPermissionWithoutTranscriptCallbacks() async {
        var events: [SpeechPipelineEvent] = []
        let service = SpeechRecognitionService(
            speechPermissionRequester: { $0(.denied) },
            microphonePermissionRequester: { $0(true) },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        await service.start(language: "en-US", scriptText: nil) { event in
            events.append(event)
        }
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(service.lastPermissionFailure, .speechDenied)
        XCTAssertTrue(events.contains { $0.status == .requestingPermission || $0.health == .starting })
        XCTAssertTrue(events.contains { $0.status == .denied })
        XCTAssertTrue(events.contains {
            if case .terminalFailure = $0.health { return true }
            return false
        })
        // No empty-string transcript flooding — event tails for permission denial stay empty once.
        XCTAssertTrue(events.allSatisfy { $0.tail.isEmpty })
        // Deduped: not a burst of identical denied events.
        let deniedCount = events.filter { $0.status == .denied }.count
        XCTAssertEqual(deniedCount, 1)
    }

    // MARK: - Callback gate (finding 7)

    func testSpeechCallbackGateRejectsStaleTaskTokens() {
        XCTAssertTrue(
            SpeechCallbackGate.accepts(
                wantsRecognition: true,
                activeRun: 1,
                callbackRun: 1,
                activeToken: 5,
                callbackToken: 5
            )
        )
        // Prior task token after restart.
        XCTAssertFalse(
            SpeechCallbackGate.accepts(
                wantsRecognition: true,
                activeRun: 1,
                callbackRun: 1,
                activeToken: 6,
                callbackToken: 5
            )
        )
        // User stop bumps generation.
        XCTAssertFalse(
            SpeechCallbackGate.accepts(
                wantsRecognition: true,
                activeRun: 2,
                callbackRun: 1,
                activeToken: 5,
                callbackToken: 5
            )
        )
        XCTAssertFalse(
            SpeechCallbackGate.accepts(
                wantsRecognition: false,
                activeRun: 1,
                callbackRun: 1,
                activeToken: 5,
                callbackToken: 5
            )
        )
        XCTAssertFalse(
            SpeechCallbackGate.accepts(
                wantsRecognition: true,
                activeRun: 1,
                callbackRun: 1,
                activeToken: 0,
                callbackToken: 0
            )
        )
    }

    func testSpeechCallbackGateCanBeginPreventsDuplicateRecognitionResourcesAndAudioTap() {
        func canBegin(
            generation: Int = 1,
            hasRecognitionRequest: Bool = false,
            hasRecognitionTask: Bool = false,
            tapInstalled: Bool = false
        ) -> Bool {
            SpeechCallbackGate.canBegin(
                wantsRecognition: true,
                run: 1,
                generation: generation,
                hasRecognitionRequest: hasRecognitionRequest,
                hasRecognitionTask: hasRecognitionTask,
                tapInstalled: tapInstalled
            )
        }

        XCTAssertTrue(canBegin(), "fresh state")
        XCTAssertFalse(canBegin(generation: 2), "generation mismatch")
        XCTAssertFalse(canBegin(hasRecognitionRequest: true), "request present")
        XCTAssertFalse(canBegin(hasRecognitionTask: true), "task present")
        XCTAssertFalse(canBegin(tapInstalled: true), "tap installed")
    }

    // MARK: - System audio recovery gate

    func testInterruptionBlocksRouteUntilEndRecoversIgnoringShouldResume() {
        var gate = SpeechSystemAudioGate()
        let began = AudioSessionSystemEvent.interruption(
            typeRawValue: AVAudioSession.InterruptionType.began.rawValue
        )
        let ended = AudioSessionSystemEvent.interruption(
            typeRawValue: AVAudioSession.InterruptionType.ended.rawValue
        )
        let route = AudioSessionSystemEvent.routeChange(
            reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        )

        let begin = gate.handle(began, wantsRecognition: true)
        XCTAssertTrue(begin.tearDownKeepIntent)
        XCTAssertNil(begin.scheduleRecoveryID)
        XCTAssertTrue(gate.isBlocked)
        // Duplicate began: already interrupted → no tear-down/cancel/schedule.
        XCTAssertEqual(gate.handle(began, wantsRecognition: true), SpeechSystemAudioEffect())

        // First media-lost while interrupted still tears down (independent block).
        XCTAssertTrue(gate.handle(.mediaServicesLost, wantsRecognition: true).tearDownKeepIntent)
        XCTAssertTrue(gate.mediaServicesLost)
        // Reset clears media-lost but stays blocked by interruption — no schedule yet.
        XCTAssertNil(gate.handle(.mediaServicesReset, wantsRecognition: true).scheduleRecoveryID)
        XCTAssertFalse(gate.mediaServicesLost)
        XCTAssertTrue(gate.interrupted)

        // Route while interrupted: pending only — no recovery until unblocked.
        let blockedRoute = gate.handle(route, wantsRecognition: true)
        XCTAssertNil(blockedRoute.scheduleRecoveryID)
        XCTAssertTrue(gate.recoveryPending)
        XCTAssertEqual(gate.activeRecoveryID, 0)

        // End recovers from user intent; shouldResume is not part of the event.
        let end = gate.handle(ended, wantsRecognition: true)
        XCTAssertTrue(end.tearDownKeepIntent)
        XCTAssertEqual(end.scheduleRecoveryID, gate.activeRecoveryID)
        XCTAssertNotNil(end.scheduleRecoveryID)
        XCTAssertFalse(gate.interrupted)

        // Payload snapshot keeps type only (shouldResume option is ignored).
        let info: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: 0,
        ]
        XCTAssertEqual(AudioSessionSystemEvent.interruption(userInfo: info), ended)
        XCTAssertEqual(
            gate.handle(began, wantsRecognition: false).scheduleRecoveryID,
            nil,
            "idle service ignores system audio events"
        )
    }

    func testMalformedAndMissingInterruptionPayloadIsSafeNoOp() {
        XCTAssertNil(AudioSessionSystemEvent.interruption(userInfo: nil))
        XCTAssertNil(AudioSessionSystemEvent.interruption(userInfo: [:]))
        XCTAssertNil(
            AudioSessionSystemEvent.interruption(userInfo: [
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ])
        )
        // Present type still parses.
        let began = AudioSessionSystemEvent.interruption(userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        XCTAssertEqual(
            began,
            .interruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue)
        )
    }

    func testDuplicateInterruptionEndedIsSafeNoOp() {
        var gate = SpeechSystemAudioGate()
        let ended = AudioSessionSystemEvent.interruption(
            typeRawValue: AVAudioSession.InterruptionType.ended.rawValue
        )
        // Ended without prior began.
        XCTAssertEqual(gate.handle(ended, wantsRecognition: true), SpeechSystemAudioEffect())
        XCTAssertFalse(gate.interrupted)
        XCTAssertFalse(gate.recoveryPending)
        XCTAssertEqual(gate.activeRecoveryID, 0)

        // Begin then end schedules once; second end is a no-op.
        _ = gate.handle(
            .interruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue),
            wantsRecognition: true
        )
        let firstEnd = gate.handle(ended, wantsRecognition: true)
        XCTAssertNotNil(firstEnd.scheduleRecoveryID)
        let secondEnd = gate.handle(ended, wantsRecognition: true)
        XCTAssertEqual(secondEnd, SpeechSystemAudioEffect())
        XCTAssertEqual(gate.activeRecoveryID, firstEnd.scheduleRecoveryID)
    }

    func testPreLiveStartupSuppressesRecoveryScheduling() {
        var gate = SpeechSystemAudioGate()
        let began = AudioSessionSystemEvent.interruption(
            typeRawValue: AVAudioSession.InterruptionType.began.rawValue
        )
        let ended = AudioSessionSystemEvent.interruption(
            typeRawValue: AVAudioSession.InterruptionType.ended.rawValue
        )
        let route = AudioSessionSystemEvent.routeChange(
            reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        )

        // During permission await: began still blocks, but no recovery schedule.
        let begin = gate.handle(began, wantsRecognition: true, allowRecovery: false)
        XCTAssertTrue(begin.tearDownKeepIntent)
        XCTAssertTrue(gate.isBlocked)
        XCTAssertNil(begin.scheduleRecoveryID)

        // Route while blocked pre-live: pending only.
        XCTAssertEqual(
            gate.handle(route, wantsRecognition: true, allowRecovery: false),
            SpeechSystemAudioEffect()
        )
        XCTAssertTrue(gate.recoveryPending)

        // End clears block without scheduling when allowRecovery is false.
        let end = gate.handle(ended, wantsRecognition: true, allowRecovery: false)
        XCTAssertEqual(end, SpeechSystemAudioEffect())
        XCTAssertFalse(gate.isBlocked)
        XCTAssertTrue(gate.recoveryPending)
        XCTAssertEqual(gate.activeRecoveryID, 0)
    }

    func testStartupCoordinatorPermissionsReadyAndSystemAudioPrerequisite() {
        var startup = SpeechStartupCoordinator()
        XCTAssertEqual(startup.phase, .idle)
        XCTAssertFalse(startup.canBeginEngine)

        startup.beginStart()
        XCTAssertEqual(startup.phase, .awaitingMicrophonePermission)
        XCTAssertTrue(startup.isAwaitingPermission)
        XCTAssertFalse(startup.canBeginEngine)

        // Interruption during mic-permission await sets system-audio block.
        startup.setSystemAudioBlocked(true)
        XCTAssertTrue(startup.systemAudioBlocked)

        startup.markMicrophonePermissionGranted()
        XCTAssertEqual(startup.phase, .awaitingSpeechPermission)
        XCTAssertTrue(startup.isAwaitingPermission)
        XCTAssertTrue(startup.systemAudioBlocked)

        // Still blocked during speech await.
        startup.setSystemAudioBlocked(true)
        startup.markSpeechPermissionGranted()
        XCTAssertEqual(startup.phase, .permissionsReady)
        XCTAssertFalse(startup.canBeginEngine, "blocked system audio must hold engine start")

        startup.setSystemAudioBlocked(false)
        XCTAssertTrue(startup.canBeginEngine)

        startup.markEngineStarting()
        XCTAssertEqual(startup.phase, .startingEngine)
        startup.markEngineLive()
        XCTAssertEqual(startup.phase, .live)
        XCTAssertFalse(startup.systemAudioBlocked)

        startup.reset()
        XCTAssertEqual(startup.phase, .idle)
    }

    func testStartupCoordinatorBothPermissionAwaitWindowsTrackRouteAndInterruption() {
        var micWindow = SpeechStartupCoordinator()
        micWindow.beginStart()
        XCTAssertEqual(micWindow.phase, .awaitingMicrophonePermission)
        micWindow.setSystemAudioBlocked(true)
        XCTAssertTrue(micWindow.systemAudioBlocked)
        micWindow.setSystemAudioBlocked(false)
        XCTAssertFalse(micWindow.systemAudioBlocked)

        var speechWindow = SpeechStartupCoordinator()
        speechWindow.beginStart()
        speechWindow.markMicrophonePermissionGranted()
        XCTAssertEqual(speechWindow.phase, .awaitingSpeechPermission)
        speechWindow.setSystemAudioBlocked(true)
        XCTAssertTrue(speechWindow.systemAudioBlocked)
        // Clearing during speech await must leave phase unchanged.
        speechWindow.setSystemAudioBlocked(false)
        XCTAssertEqual(speechWindow.phase, .awaitingSpeechPermission)
        XCTAssertFalse(speechWindow.systemAudioBlocked)
    }

    func testProductStatusAfterEngineReadyIsListeningSilentWithoutRecognition() {
        let ready = SpeechProductStatus.afterEngineReady()
        XCTAssertEqual(ready.0, .listening)
        XCTAssertEqual(ready.1, .silent)
        // Starting is setup only — engine-ready must not stay on Starting.
        XCTAssertNotEqual(ready.0, .starting)
        XCTAssertNotEqual(ready.1, .starting)
        XCTAssertNotEqual(ready.1, .hearingSpeech)
    }

    @MainActor
    func testStartupPhaseAdvancesThroughPermissionAwaitsAndBlocksOnSystemAudio() async {
        final class Probe: @unchecked Sendable {
            var speechResume: (@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void)?
            var micResume: (@Sendable (Bool) -> Void)?
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { probe.speechResume = $0 },
            microphonePermissionRequester: { probe.micResume = $0 },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        let startTask = Task { @MainActor in
            await service.start(language: "en-US", scriptText: nil) { _ in }
        }
        // Mic first.
        for _ in 0..<200 where probe.micResume == nil { await Task.yield() }
        XCTAssertEqual(service.startupPhase, .awaitingMicrophonePermission)
        XCTAssertNil(probe.speechResume, "speech must not prompt before mic resolves")

        // Interruption began during mic-permission await (pre-live).
        service.applySystemAudioForTests(
            .interruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue)
        )
        XCTAssertEqual(service.startupPhase, .awaitingMicrophonePermission)

        probe.micResume?(true)
        for _ in 0..<200 where probe.speechResume == nil { await Task.yield() }
        XCTAssertEqual(service.startupPhase, .awaitingSpeechPermission)

        // Route change during speech await must not advance to live.
        service.applySystemAudioForTests(
            .routeChange(reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        )
        XCTAssertEqual(service.startupPhase, .awaitingSpeechPermission)

        // End interruption while still awaiting speech — still not permissionsReady.
        service.applySystemAudioForTests(
            .interruption(typeRawValue: AVAudioSession.InterruptionType.ended.rawValue)
        )
        XCTAssertEqual(service.startupPhase, .awaitingSpeechPermission)

        // Re-block before speech completes so permissionsReady cannot begin engine.
        service.applySystemAudioForTests(
            .interruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue)
        )
        probe.speechResume?(.authorized)
        for _ in 0..<50 { await Task.yield() }
        await startTask.value

        XCTAssertEqual(service.startupPhase, .permissionsReady)
        XCTAssertEqual(service.status, .starting)
        XCTAssertEqual(service.health, .recovering)

        service.stop()
        XCTAssertEqual(service.startupPhase, .idle)
    }

    #if DEBUG
    @MainActor
    func testStopCancelsPendingDiagnosticsFlushWork() async {
        let service = SpeechRecognitionService(
            speechPermissionRequester: { $0(.authorized) },
            microphonePermissionRequester: { $0(true) },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        service.stop()
        XCTAssertFalse(service.hasPendingDiagnosticsFlushForTests)

        // Start may or may not arm a flush depending on simulator mic availability;
        // stop must always leave flush cancelled.
        await service.start(language: "en-US", scriptText: nil) { _ in }
        service.stop()
        XCTAssertFalse(
            service.hasPendingDiagnosticsFlushForTests,
            "teardown must cancel diagnostics flush so delayed writes cannot escape"
        )
    }
    #endif

    func testMediaLostRouteResetCoalesceAndMonotonicIdentity() {
        var gate = SpeechSystemAudioGate()
        let began = AudioSessionSystemEvent.interruption(
            typeRawValue: AVAudioSession.InterruptionType.began.rawValue
        )
        let ended = AudioSessionSystemEvent.interruption(
            typeRawValue: AVAudioSession.InterruptionType.ended.rawValue
        )
        let route = AudioSessionSystemEvent.routeChange(
            reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        )

        // Media lost blocks; duplicate lost is a no-op.
        let lost = gate.handle(.mediaServicesLost, wantsRecognition: true)
        XCTAssertTrue(lost.tearDownKeepIntent)
        XCTAssertTrue(gate.mediaServicesLost)
        XCTAssertEqual(gate.handle(.mediaServicesLost, wantsRecognition: true), SpeechSystemAudioEffect())
        // First interruption began while media-lost still tears down (independent block).
        XCTAssertTrue(gate.handle(began, wantsRecognition: true).tearDownKeepIntent)
        XCTAssertTrue(gate.interrupted)
        XCTAssertEqual(gate.handle(began, wantsRecognition: true), SpeechSystemAudioEffect())
        // End interruption while media still lost: pending only.
        XCTAssertNil(gate.handle(ended, wantsRecognition: true).scheduleRecoveryID)
        XCTAssertNil(gate.handle(route, wantsRecognition: true).scheduleRecoveryID)
        XCTAssertTrue(gate.recoveryPending)

        // Reset unblocks, marks engine replace, schedules one recovery.
        let reset = gate.handle(.mediaServicesReset, wantsRecognition: true)
        let firstID = reset.scheduleRecoveryID!
        XCTAssertTrue(reset.tearDownKeepIntent)
        XCTAssertTrue(gate.replaceEnginePending)
        XCTAssertFalse(gate.mediaServicesLost)

        // Duplicates coalesce; non-invalidating routes are ignored.
        XCTAssertNil(gate.handle(route, wantsRecognition: true).scheduleRecoveryID)
        XCTAssertEqual(gate.activeRecoveryID, firstID)
        XCTAssertNil(
            gate.handle(
                .routeChange(reasonRawValue: AVAudioSession.RouteChangeReason.categoryChange.rawValue),
                wantsRecognition: true
            ).scheduleRecoveryID
        )

        // Cancel via interruption began, then end re-schedules: stale take cannot clear newer id.
        // replaceEnginePending survives so the next successful take still replaces.
        XCTAssertTrue(gate.handle(began, wantsRecognition: true).cancelRecovery)
        XCTAssertEqual(gate.activeRecoveryID, 0)
        let secondID = gate.handle(ended, wantsRecognition: true).scheduleRecoveryID!
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertNil(gate.takeRecoveryWork(id: firstID))
        XCTAssertEqual(gate.activeRecoveryID, secondID)
        XCTAssertEqual(gate.takeRecoveryWork(id: secondID), true)
        XCTAssertEqual(gate.activeRecoveryID, 0)
        XCTAssertFalse(gate.replaceEnginePending)

        // Route-only recovery does not replace the engine.
        let routeID = gate.handle(route, wantsRecognition: true).scheduleRecoveryID!
        XCTAssertEqual(gate.takeRecoveryWork(id: routeID), false)
    }

    func testStopFailResetClearsBlockingPendingAndCancelsRecovery() {
        var gate = SpeechSystemAudioGate()
        _ = gate.handle(
            .interruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue),
            wantsRecognition: true
        )
        _ = gate.handle(
            .routeChange(reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue),
            wantsRecognition: true
        )
        XCTAssertTrue(gate.interrupted)
        XCTAssertTrue(gate.recoveryPending)

        // Blocked with no scheduled recovery → reset clears state, no cancel.
        let idleReset = gate.reset()
        XCTAssertFalse(idleReset.cancelRecovery)
        XCTAssertFalse(gate.interrupted)
        XCTAssertFalse(gate.recoveryPending)
        XCTAssertEqual(gate.activeRecoveryID, 0)

        // Scheduled recovery → reset cancels it (stop/fail path).
        let scheduled = gate.handle(
            .routeChange(reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue),
            wantsRecognition: true
        )
        XCTAssertNotNil(scheduled.scheduleRecoveryID)
        XCTAssertTrue(gate.reset().cancelRecovery)
        XCTAssertEqual(gate.activeRecoveryID, 0)
        XCTAssertFalse(gate.replaceEnginePending)
    }

    @MainActor
    func testPermissionGenerationGuardAndDenialSkipSpeech() async {
        final class Probe: @unchecked Sendable {
            var micResume: (@Sendable (Bool) -> Void)?
            var speechCount = 0
        }

        // Stop between mic and speech prompts must not raise the speech prompt.
        let stopProbe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { stopProbe.speechCount += 1; $0(.authorized) },
            microphonePermissionRequester: { stopProbe.micResume = $0 },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        let startTask = Task { @MainActor in
            await service.start(language: "en-US", scriptText: nil) { _ in }
        }
        for _ in 0..<200 where stopProbe.micResume == nil { await Task.yield() }
        XCTAssertNotNil(stopProbe.micResume)
        XCTAssertEqual(stopProbe.speechCount, 0)
        service.stop()
        stopProbe.micResume?(true)
        await startTask.value
        XCTAssertEqual(stopProbe.speechCount, 0)
        XCTAssertEqual(service.status, .idle)
        XCTAssertEqual(service.health, .inactive)

        // Mic denied finishes without asking for speech.
        final class MicStatus: @unchecked Sendable {
            var value: AVAudioApplication.recordPermission = .undetermined
        }
        let micStatus = MicStatus()
        let denyProbe = Probe()
        let denied = SpeechRecognitionService(
            speechPermissionRequester: { denyProbe.speechCount += 1; $0(.authorized) },
            microphonePermissionRequester: { resume in
                micStatus.value = .denied
                resume(false)
            },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { micStatus.value }
        )
        await denied.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(denied.status, .denied)
        XCTAssertEqual(denied.lastPermissionFailure, .microphoneDenied)
        XCTAssertEqual(denyProbe.speechCount, 0)
    }

    func testVoicePermissionGateOrderAndDecisions() {
        XCTAssertEqual(
            VoicePermissionGate.requestOrder,
            [.microphone, .speechRecognition]
        )
        XCTAssertEqual(
            VoicePermissionGate.decision(forMicrophone: .undetermined),
            .request
        )
        XCTAssertEqual(
            VoicePermissionGate.decision(forMicrophone: .granted),
            .proceed
        )
        XCTAssertEqual(
            VoicePermissionGate.decision(forMicrophone: .denied),
            .denied
        )
        XCTAssertEqual(
            VoicePermissionGate.decision(forSpeech: .notDetermined),
            .request
        )
        XCTAssertEqual(
            VoicePermissionGate.decision(forSpeech: .authorized),
            .proceed
        )
        XCTAssertEqual(
            VoicePermissionGate.decision(forSpeech: .denied),
            .denied
        )
        XCTAssertEqual(
            VoicePermissionGate.decision(forSpeech: .restricted),
            .restricted
        )
        XCTAssertEqual(
            VoicePermissionGate.failure(forSpeech: .restricted),
            .speechRestricted
        )
        // Only undetermined invokes the system API; denied/restricted never re-prompt.
        XCTAssertTrue(VoicePermissionGate.shouldInvokeSystemPrompt(for: .request))
        XCTAssertFalse(VoicePermissionGate.shouldInvokeSystemPrompt(for: .denied))
        XCTAssertFalse(VoicePermissionGate.shouldInvokeSystemPrompt(for: .proceed))
        XCTAssertFalse(VoicePermissionGate.shouldInvokeSystemPrompt(for: .restricted))
        XCTAssertEqual(VoicePermissionFailure.microphoneDenied.diagnosticCode, "micDenied")
        XCTAssertEqual(VoicePermissionFailure.speechDenied.diagnosticCode, "speechDenied")
        XCTAssertTrue(
            VoicePermissionFailure.microphoneDenied.userMessage
                .localizedCaseInsensitiveContains("will not ask again")
        )
        // Incomplete registration (prompt false but TCC still undetermined) is not a denial.
        let incomplete = VoicePermissionGate.failureAfterMicrophonePrompt(
            granted: false,
            statusAfter: .undetermined
        )
        guard case .requestError(let incompleteMessage) = incomplete else {
            return XCTFail("undetermined after false grant must be requestError, not microphoneDenied")
        }
        XCTAssertTrue(incompleteMessage.localizedCaseInsensitiveContains("try again"))
        XCTAssertFalse(incomplete?.offersOpenSettings ?? true)
        if case .unavailable = incomplete?.readerStatus {
            // expected — not .denied, so Open Settings is not the recovery path
        } else {
            XCTFail("incomplete mic registration must surface as unavailable, not denied")
        }
        XCTAssertEqual(
            VoicePermissionGate.failureAfterMicrophonePrompt(
                granted: false,
                statusAfter: .denied
            ),
            .microphoneDenied
        )
        XCTAssertNil(
            VoicePermissionGate.failureAfterMicrophonePrompt(
                granted: true,
                statusAfter: .granted
            )
        )
        XCTAssertEqual(
            VoicePermissionGate.failureAfterSpeechPrompt(status: .denied),
            .speechDenied
        )
        XCTAssertEqual(
            VoicePermissionGate.failureAfterSpeechPrompt(status: .restricted),
            .speechRestricted
        )
        XCTAssertNil(VoicePermissionGate.failureAfterSpeechPrompt(status: .authorized))
        if case .requestError = VoicePermissionGate.failureAfterSpeechPrompt(
            status: .notDetermined
        ) {
            // expected
        } else {
            XCTFail("speech notDetermined after prompt must be requestError")
        }
        XCTAssertTrue(VoicePermissionFailure.microphoneDenied.offersOpenSettings)
        XCTAssertTrue(
            VoicePermissionFailure.microphoneDenied.userMessage
                .contains("Privacy & Security")
        )
        XCTAssertFalse(VoicePermissionFailure.speechRestricted.offersOpenSettings)
        XCTAssertTrue(
            VoicePermissionGate.shouldIgnoreOverlappingStart(
                wantsRecognition: true,
                isAwaitingPermission: true
            )
        )
        XCTAssertFalse(
            VoicePermissionGate.shouldIgnoreOverlappingStart(
                wantsRecognition: false,
                isAwaitingPermission: true
            )
        )
    }

    @MainActor
    func testAlreadyDeniedMicrophoneDoesNotInvokeSystemPrompt() async {
        final class Probe: @unchecked Sendable {
            var micCount = 0
            var speechCount = 0
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { probe.speechCount += 1; $0(.authorized) },
            microphonePermissionRequester: { resume in
                probe.micCount += 1
                resume(false)
            },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .denied }
        )
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(probe.micCount, 0, "already-denied must not re-prompt")
        XCTAssertEqual(probe.speechCount, 0)
        XCTAssertEqual(service.lastPermissionFailure, .microphoneDenied)
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(service.lastPermissionFailure?.diagnosticCode, "micDenied")
        #if DEBUG
        XCTAssertEqual(service.diagnostics.permissionFailureCode, "micDenied")
        XCTAssertEqual(service.diagnostics.micPermission, "denied")
        #endif
    }

    @MainActor
    func testIncompleteMicrophoneRegistrationReportsUnavailableNotDenied() async {
        // Prompt returns false but TCC never flips off undetermined — Open Settings
        // would show no Microphone row; surface retry copy instead of false denial.
        let service = SpeechRecognitionService(
            speechPermissionRequester: { $0(.authorized) },
            microphonePermissionRequester: { $0(false) },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(service.status, .unavailable(
            "Microphone permission did not complete. Tap Try again and choose Allow when iOS asks."
        ))
        if case .requestError = service.lastPermissionFailure {
            // expected
        } else {
            XCTFail("expected requestError, got \(String(describing: service.lastPermissionFailure))")
        }
        XCTAssertFalse(service.lastPermissionFailure?.offersOpenSettings ?? true)
    }

    @MainActor
    func testAlreadyDeniedSpeechDoesNotInvokeSpeechPrompt() async {
        final class Probe: @unchecked Sendable {
            var speechCount = 0
            var micCount = 0
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { resume in
                probe.speechCount += 1
                resume(.authorized)
            },
            microphonePermissionRequester: { resume in
                probe.micCount += 1
                resume(true)
            },
            speechAuthorizationStatusProvider: { .denied },
            microphonePermissionStatusProvider: { .granted }
        )
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(probe.micCount, 0)
        XCTAssertEqual(probe.speechCount, 0, "already-denied speech must not re-prompt")
        XCTAssertEqual(service.lastPermissionFailure, .speechDenied)
        XCTAssertEqual(service.status, .denied)
    }

    @MainActor
    func testMicrophoneAlreadyAuthorizedSkipsMicPromptThenRequestsSpeech() async {
        final class Probe: @unchecked Sendable {
            var micCount = 0
            var speechResume: (@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void)?
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { probe.speechResume = $0 },
            microphonePermissionRequester: { probe.micCount += 1; $0(true) },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .granted }
        )
        let startTask = Task { @MainActor in
            await service.start(language: "en-US", scriptText: nil) { _ in }
        }
        for _ in 0..<200 where probe.speechResume == nil { await Task.yield() }
        XCTAssertEqual(probe.micCount, 0, "granted mic must not re-prompt")
        XCTAssertEqual(service.startupPhase, .awaitingSpeechPermission)
        probe.speechResume?(.denied)
        await startTask.value
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(service.lastPermissionFailure, .speechDenied)
    }

    @MainActor
    func testSpeechRestrictedSurfacesWithoutSettingsWhenStatusAlreadyRestricted() async {
        let service = SpeechRecognitionService(
            speechPermissionRequester: { $0(.authorized) },
            microphonePermissionRequester: { $0(true) },
            speechAuthorizationStatusProvider: { .restricted },
            microphonePermissionStatusProvider: { .granted }
        )
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(service.lastPermissionFailure, .speechRestricted)
        XCTAssertFalse(service.lastPermissionFailure?.offersOpenSettings ?? true)
        XCTAssertEqual(
            service.health,
            .terminalFailure(VoicePermissionFailure.speechRestricted.userMessage)
        )
    }

    @MainActor
    func testPermissionRetryAfterDenialRequestsInMicThenSpeechOrder() async {
        final class Probe: @unchecked Sendable {
            var micCount = 0
            var speechCount = 0
            var order: [String] = []
            var micStatus: AVAudioApplication.recordPermission = .undetermined
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { resume in
                probe.speechCount += 1
                probe.order.append("speech")
                resume(.authorized)
            },
            microphonePermissionRequester: { resume in
                probe.micCount += 1
                probe.order.append("mic")
                // First attempt: undetermined prompt is denied.
                if probe.micCount == 1 {
                    probe.micStatus = .denied
                    resume(false)
                } else {
                    probe.micStatus = .granted
                    resume(true)
                }
            },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { probe.micStatus }
        )
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(probe.order, ["mic"])
        XCTAssertEqual(probe.speechCount, 0)

        // While still denied, Try again must not re-call the system API.
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(probe.order, ["mic"])
        XCTAssertEqual(service.lastPermissionFailure, .microphoneDenied)

        // After the user enables mic in Privacy Settings, the granted status
        // proceeds to speech without another mic prompt.
        probe.micStatus = .granted
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(probe.order, ["mic", "speech"])
        XCTAssertEqual(probe.micCount, 1)
        XCTAssertEqual(probe.speechCount, 1)
    }

    @MainActor
    func testUndeterminedMicrophoneInvokesSystemRequestOnMainActorPath() async {
        final class Probe: @unchecked Sendable {
            var micCount = 0
            var requestedOnMain = false
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { $0(.authorized) },
            microphonePermissionRequester: { resume in
                probe.micCount += 1
                probe.requestedOnMain = Thread.isMainThread
                resume(true)
            },
            speechAuthorizationStatusProvider: { .authorized },
            microphonePermissionStatusProvider: { .undetermined }
        )
        await service.start(language: "en-US", scriptText: nil) { _ in }
        XCTAssertEqual(probe.micCount, 1)
        XCTAssertTrue(probe.requestedOnMain)
        XCTAssertNil(service.lastPermissionFailure)
    }

    @MainActor
    func testOverlappingStartJoinsSingleMicFlightAndReplacementOwnsSpeech() async throws {
        final class Probe: @unchecked Sendable {
            var micResume: (@Sendable (Bool) -> Void)?
            var speechResume: (@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void)?
            var speechCount = 0
            var micRequestCount = 0
            var firstFinished = false
            var secondFinished = false
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { resume in
                probe.speechCount += 1
                probe.speechResume = resume
            },
            microphonePermissionRequester: { resume in
                probe.micRequestCount += 1
                probe.micResume = resume
            },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        Task { @MainActor in
            await service.start(language: "en-US", scriptText: nil) { _ in }
            probe.firstFinished = true
        }
        let firstMicStarted = await waitUntil { probe.micResume != nil }
        XCTAssertTrue(firstMicStarted)
        let micResume = try XCTUnwrap(probe.micResume)
        XCTAssertEqual(probe.micRequestCount, 1, "first start must request microphone once")

        // B supersedes A's state ownership, but joins A's non-cancellable TCC request.
        Task { @MainActor in
            await service.start(language: "en-US", scriptText: nil) { _ in }
            probe.secondFinished = true
        }
        let firstStopped = await waitUntil { probe.firstFinished }
        XCTAssertTrue(firstStopped)
        XCTAssertEqual(probe.micRequestCount, 1, "replacement must join the mic flight")
        XCTAssertFalse(probe.secondFinished)
        XCTAssertEqual(service.status, .requestingPermission)

        // The one shared callback belongs to B now. A is stale and cannot advance.
        DispatchQueue.global(qos: .userInitiated).async {
            micResume(true)
            micResume(false) // Double callback must be ignored thread-safely.
        }
        let speechStarted = await waitUntil { probe.speechResume != nil }
        XCTAssertTrue(speechStarted)
        XCTAssertEqual(probe.micRequestCount, 1)
        XCTAssertEqual(probe.speechCount, 1, "B may request speech at most once")
        XCTAssertFalse(probe.secondFinished)

        let speechResume = try XCTUnwrap(probe.speechResume)
        speechResume(.denied)
        speechResume(.authorized) // Late duplicate cannot change B's result.
        let secondFinished = await waitUntil { probe.secondFinished }
        XCTAssertTrue(secondFinished)
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(service.lastPermissionFailure, .speechDenied)
    }

    @MainActor
    func testStopDuringMicPermissionWaitReturnsPromptlyAndLateCallbackIsHarmless() async throws {
        final class Probe: @unchecked Sendable {
            var micResume: (@Sendable (Bool) -> Void)?
            var speechCount = 0
            var startFinished = false
        }
        let probe = Probe()
        let service = SpeechRecognitionService(
            speechPermissionRequester: { probe.speechCount += 1; $0(.authorized) },
            microphonePermissionRequester: { probe.micResume = $0 },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        Task { @MainActor in
            await service.start(language: "en-US", scriptText: nil) { _ in }
            probe.startFinished = true
        }
        let micStarted = await waitUntil { probe.micResume != nil }
        XCTAssertTrue(micStarted)
        let micResume = try XCTUnwrap(probe.micResume)

        // The app-level start finishes within 500 ms without waiting for TCC.
        service.stop()
        let stoppedPromptly = await waitUntil { probe.startFinished }
        XCTAssertTrue(stoppedPromptly)
        XCTAssertEqual(service.status, .idle)
        XCTAssertEqual(service.health, .inactive)
        XCTAssertEqual(probe.speechCount, 0)

        // The real prompt may resolve later, even twice; neither result can resurrect A.
        DispatchQueue.global(qos: .utility).async {
            micResume(true)
            micResume(false)
        }
        try? await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(service.status, .idle)
        XCTAssertEqual(service.health, .inactive)
        XCTAssertEqual(probe.speechCount, 0)
    }

    func testSpeechPipelineHealthCasesAreDistinctAndEquatable() {
        let cases: [SpeechPipelineHealth] = [
            .inactive,
            .starting,
            .hearingSpeech,
            .silent,
            .recovering,
            .terminalFailure("x"),
        ]
        XCTAssertEqual(Set(cases.map { String(describing: $0) }).count, cases.count)
        XCTAssertEqual(SpeechPipelineHealth.silent, SpeechPipelineHealth.silent)
        XCTAssertNotEqual(SpeechPipelineHealth.hearingSpeech, SpeechPipelineHealth.silent)
    }

    @MainActor
    func testPermissionResultBridgeResumesFromBackgroundQueue() async {
        let value: Bool = await PermissionResultBridge.once { resume in
            DispatchQueue.global(qos: .userInitiated).async {
                resume(true)
            }
        }
        XCTAssertTrue(value)
    }

    /// Polls for at most 500 ms so a permission regression fails instead of hanging CI.
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private static func seg(
        _ text: String,
        timestamp: TimeInterval = 0,
        duration: TimeInterval = 0.1,
        confidence: Float = 0.9
    ) -> SpeechSegmentSnapshot {
        SpeechSegmentSnapshot(
            substring: text,
            timestamp: timestamp,
            duration: duration,
            confidence: confidence
        )
    }
}

private actor ReaderMutationRecorder {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func events() -> [String] { values }
}
