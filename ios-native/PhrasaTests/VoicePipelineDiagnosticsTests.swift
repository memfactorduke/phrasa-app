#if DEBUG
import AVFAudio
import XCTest
@testable import Phrasa

final class VoicePipelineDiagnosticsTests: XCTestCase {

    // MARK: - Status after engine ready (presentation fix)

    func testStatusAfterEngineReadyIsListeningSilent() {
        let ready = VoicePipelineDiagnostics.statusAfterEngineReady()
        XCTAssertEqual(ready.0, .listening)
        XCTAssertEqual(ready.1, .silent)
    }

    func testStartingIsReservedForSetupNotAwaitingSpeech() {
        // Contract: once engine+task are live, UI must not remain Starting.
        // Starting → Listening/silent is the only post-setup transition.
        let ready = VoicePipelineDiagnostics.statusAfterEngineReady()
        XCTAssertNotEqual(ready.0, .starting)
        XCTAssertEqual(ready.0.label, "Listening")
    }

    // MARK: - Counter / encoding transitions

    func testDiagnosticsCounterTransitionsAreDeterministic() throws {
        var diagnostics = VoicePipelineDiagnostics()
        diagnostics.permissionOK = true
        diagnostics.recognizerAvailable = true
        diagnostics.onDeviceRequired = true
        diagnostics.inputSampleRateBucket = VoicePipelineDiagnostics.sampleRateBucket(48_000)
        diagnostics.inputChannelCount = 1
        diagnostics.inputPortClass = "builtIn"
        diagnostics.inputCommonFormat = "pcmFloat32"
        diagnostics.inputInterleaved = true
        diagnostics.floatChannelAccessAvailable = true
        diagnostics.int16ChannelAccessAvailable = false
        diagnostics.unsupportedFormatBufferCount = 0
        diagnostics.engineStarted = true
        diagnostics.tapBufferCount = 12
        diagnostics.nonSilentBufferCount = 4
        diagnostics.peakRMSBucket = 5
        diagnostics.recognitionCallbackCount = 3
        diagnostics.wordCallbackCount = 2
        diagnostics.alignmentObservationCount = 2
        diagnostics.acceptedCount = 1
        diagnostics.committedTokenIndex = 7
        diagnostics.statusLabel = "listening"
        diagnostics.healthLabel = "hearingSpeech"

        XCTAssertEqual(diagnostics.inputSampleRateBucket, 48_000)
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseFlag("eng", from: diagnostics.accessibilityValue),
            true
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseInt("tap", from: diagnostics.accessibilityValue),
            12
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseInt("nonsil", from: diagnostics.accessibilityValue),
            4
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseInt("word", from: diagnostics.accessibilityValue),
            2
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseInt("acc", from: diagnostics.accessibilityValue),
            1
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseInt("commit", from: diagnostics.accessibilityValue),
            7
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseFlag("f32", from: diagnostics.accessibilityValue),
            true
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseFlag("i16", from: diagnostics.accessibilityValue),
            false
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseInt("unsup", from: diagnostics.accessibilityValue),
            0
        )
        XCTAssertEqual(
            VoicePipelineDiagnostics.parseFlag("intl", from: diagnostics.accessibilityValue),
            true
        )
        XCTAssertTrue(diagnostics.accessibilityValue.contains("fmt=pcmFloat32"))
        XCTAssertTrue(diagnostics.accessibilityValue.contains("port=builtIn"))

        let data = try diagnostics.encodedJSON()
        let decoded = try JSONDecoder().decode(VoicePipelineDiagnostics.self, from: data)
        XCTAssertEqual(decoded, diagnostics)
    }

    func testSampleRateBucketRoundsToNearestHundred() {
        XCTAssertEqual(VoicePipelineDiagnostics.sampleRateBucket(0), 0)
        XCTAssertEqual(VoicePipelineDiagnostics.sampleRateBucket(44_100), 44_100)
        XCTAssertEqual(VoicePipelineDiagnostics.sampleRateBucket(48_000.4), 48_000)
        XCTAssertEqual(VoicePipelineDiagnostics.sampleRateBucket(16_049), 16_000)
    }

    func testRMSBucketAndNonSilentThreshold() {
        // Silence
        var silent = [Float](repeating: 0, count: 64)
        XCTAssertEqual(
            silent.withUnsafeBufferPointer { VoicePipelineDiagnostics.rmsBucket(samples: $0.baseAddress!, count: $0.count) },
            0
        )
        XCTAssertFalse(VoicePipelineDiagnostics.isNonSilent(rmsBucket: 0))
        // Bucket 1 is weak distant speech/ambient — counts as non-silent for harness gating.
        XCTAssertTrue(VoicePipelineDiagnostics.isNonSilent(rmsBucket: 1))
        XCTAssertTrue(VoicePipelineDiagnostics.isNonSilent(rmsBucket: 2))

        // Quiet but non-zero peaks (distant room TTS class).
        var quiet = [Float](repeating: 0, count: 64)
        quiet[0] = 0.002
        quiet[10] = -0.0015
        let quietBucket = quiet.withUnsafeBufferPointer {
            VoicePipelineDiagnostics.rmsBucket(samples: $0.baseAddress!, count: $0.count)
        }
        XCTAssertGreaterThanOrEqual(quietBucket, 1)

        // Loud-ish tone
        var loud = [Float](repeating: 0.2, count: 64)
        let bucket = loud.withUnsafeBufferPointer {
            VoicePipelineDiagnostics.rmsBucket(samples: $0.baseAddress!, count: $0.count)
        }
        XCTAssertGreaterThanOrEqual(bucket, 5)
        XCTAssertTrue(VoicePipelineDiagnostics.isNonSilent(rmsBucket: bucket))
    }

    func testInputPortClassIsPrivacySafe() {
        XCTAssertEqual(VoicePipelineDiagnostics.inputPortClass(from: .builtInMic), "builtIn")
        XCTAssertEqual(VoicePipelineDiagnostics.inputPortClass(from: .bluetoothHFP), "bluetooth")
        XCTAssertEqual(VoicePipelineDiagnostics.inputPortClass(from: .headsetMic), "headset")
        XCTAssertEqual(VoicePipelineDiagnostics.inputPortClass(from: nil), "unknown")
        // Never returns a device-specific name.
        XCTAssertFalse(VoicePipelineDiagnostics.inputPortClass(from: .builtInMic).contains("iPhone"))
    }

    func testCommonFormatClassIsPrivacySafe() {
        XCTAssertEqual(VoicePipelineDiagnostics.commonFormatClass(.pcmFormatFloat32), "pcmFloat32")
        XCTAssertEqual(VoicePipelineDiagnostics.commonFormatClass(.pcmFormatInt16), "pcmInt16")
        XCTAssertEqual(VoicePipelineDiagnostics.commonFormatClass(.pcmFormatFloat64), "pcmFloat64")
        XCTAssertEqual(VoicePipelineDiagnostics.commonFormatClass(.pcmFormatInt32), "pcmInt32")
        XCTAssertEqual(VoicePipelineDiagnostics.commonFormatClass(.otherFormat), "other")
        // Never a device or vendor string.
        XCTAssertFalse(VoicePipelineDiagnostics.commonFormatClass(.pcmFormatFloat32).contains("iPhone"))
        XCTAssertFalse(VoicePipelineDiagnostics.commonFormatClass(.pcmFormatFloat32).contains("Apple"))
    }

    func testTapSinkAccumulatesWithoutStoringAudio() {
        let sink = VoiceTapDiagnosticsSink()
        sink.noteBuffer(
            rmsBucket: 0,
            channelAccess: VoiceBufferChannelAccess(hasFloat32: true, hasInt16: false)
        )
        sink.noteBuffer(
            rmsBucket: 3,
            channelAccess: VoiceBufferChannelAccess(hasFloat32: true, hasInt16: false)
        )
        sink.noteBuffer(
            rmsBucket: 7,
            channelAccess: VoiceBufferChannelAccess(hasFloat32: false, hasInt16: true)
        )
        let snap = sink.snapshot()
        XCTAssertEqual(snap.tapBufferCount, 3)
        XCTAssertEqual(snap.nonSilentBufferCount, 2)
        XCTAssertEqual(snap.peakRMSBucket, 7)
        XCTAssertTrue(snap.floatChannelAccessAvailable)
        XCTAssertTrue(snap.int16ChannelAccessAvailable)
        XCTAssertEqual(snap.unsupportedFormatBufferCount, 0)
        sink.reset()
        XCTAssertEqual(sink.snapshot().tapBufferCount, 0)
        XCTAssertFalse(sink.snapshot().floatChannelAccessAvailable)
        XCTAssertEqual(sink.snapshot().unsupportedFormatBufferCount, 0)
    }

    func testTapSinkTracksUnsupportedFormatBuffersSeparatelyFromSilence() {
        let sink = VoiceTapDiagnosticsSink()
        // Unsupported layout: energy reports 0, but unsupported counter advances.
        sink.noteBuffer(rmsBucket: 0, channelAccess: VoiceBufferChannelAccess())
        sink.noteBuffer(rmsBucket: 0, channelAccess: VoiceBufferChannelAccess())
        // Supported float path with real silence.
        sink.noteBuffer(
            rmsBucket: 0,
            channelAccess: VoiceBufferChannelAccess(hasFloat32: true, hasInt16: false)
        )
        let snap = sink.snapshot()
        XCTAssertEqual(snap.tapBufferCount, 3)
        XCTAssertEqual(snap.nonSilentBufferCount, 0)
        XCTAssertEqual(snap.unsupportedFormatBufferCount, 2)
        XCTAssertTrue(snap.floatChannelAccessAvailable)
        XCTAssertFalse(snap.int16ChannelAccessAvailable)
    }

    func testEnergyBucketFromFloatAndInt16BuffersIsDeterministic() {
        // Float path: quiet peak should register as non-silent.
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 64)!
        floatBuffer.frameLength = 64
        floatBuffer.floatChannelData![0][0] = 0.002
        let floatAccess = VoiceBufferEnergy.channelAccess(from: floatBuffer)
        XCTAssertTrue(floatAccess.hasFloat32)
        XCTAssertTrue(floatAccess.isSupported)
        let floatBucket = VoiceBufferEnergy.rmsBucket(from: floatBuffer, access: floatAccess)
        XCTAssertGreaterThanOrEqual(floatBucket, 1)

        // Int16 path: scaled peak above silence floor.
        let intFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let intBuffer = AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 64)!
        intBuffer.frameLength = 64
        intBuffer.int16ChannelData![0][0] = 200 // ~0.006 peak
        let intAccess = VoiceBufferEnergy.channelAccess(from: intBuffer)
        XCTAssertTrue(intAccess.hasInt16)
        XCTAssertTrue(intAccess.isSupported)
        let intBucket = VoiceBufferEnergy.rmsBucket(from: intBuffer, access: intAccess)
        XCTAssertGreaterThanOrEqual(intBucket, 1)
    }

    func testDoesNotForcePreferredBuiltInInputInSource() throws {
        // Guardrail: unconditional setPreferredInput(builtIn) overrides user mics and
        // did not fix silence — product source must not reintroduce a call site.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Phrasa/Speech/SpeechRecognitionService.swift")
        let source = try String(contentsOf: sourceRoot, encoding: .utf8)
        XCTAssertFalse(
            source.contains("session.setPreferredInput"),
            "SpeechRecognitionService must not force setPreferredInput (built-in or otherwise)"
        )
        XCTAssertFalse(
            source.contains("portType == .builtInMic"),
            "SpeechRecognitionService must not select builtInMic as preferred input"
        )
    }

    func testRecordMeasurementCategoryUsesAllowBluetoothHFPWithoutDuckOthers() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Phrasa/Speech/SpeechRecognitionService.swift")
        let source = try String(contentsOf: sourceRoot, encoding: .utf8)
        // Strip line comments so historical/forbidden API names in prose do not trip guards.
        let codeOnly = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let range = line.range(of: "//") {
                    return String(line[..<range.lowerBound])
                }
                return String(line)
            }
            .joined(separator: "\n")

        // Exact production configuration contract for build-14 priority recovery.
        XCTAssertTrue(
            codeOnly.contains(
                "setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])"
            ),
            "Voice session must use .record + .measurement + [.allowBluetoothHFP]"
        )
        XCTAssertFalse(
            codeOnly.contains(".duckOthers"),
            ".duckOthers is invalid with AVAudioSessionCategoryRecord and must not reappear"
        )
        XCTAssertFalse(
            codeOnly.contains("setPreferredInput"),
            "Must not force preferred audio input"
        )
        // Activation uses bare setActive(true); notifyOthers only on teardown deactivation.
        XCTAssertTrue(
            codeOnly.contains("try session.setActive(true)"),
            "Activation must call setActive(true) with no options"
        )
        XCTAssertFalse(
            codeOnly.contains("setActive(true, options:"),
            "Do not pass options on setActive(true)"
        )
        XCTAssertTrue(
            codeOnly.contains("setActive(false, options: .notifyOthersOnDeactivation)"),
            "Teardown must keep notifyOthersOnDeactivation"
        )
        // Stay on .record — do not switch product path to playAndRecord.
        XCTAssertFalse(
            codeOnly.contains("setCategory(.playAndRecord"),
            "Must not switch activation category to .playAndRecord"
        )
    }

    // MARK: - Privacy: no transcript/script text in diagnostic output

    func testDiagnosticAccessibilityValueContainsNoTranscriptOrScriptText() {
        var diagnostics = VoicePipelineDiagnostics()
        diagnostics.statusLabel = "listening"
        diagnostics.healthLabel = "hearingSpeech"
        diagnostics.lastErrorDomain = "kAFAssistantErrorDomain"
        diagnostics.lastErrorCode = 1110
        let value = diagnostics.accessibilityValue.lowercased()

        // Must not embed free-form speech/script content fields.
        for forbidden in ["welcome to phrasa", "transcript=", "script=", "tail=", "utterance="] {
            XCTAssertFalse(value.contains(forbidden), "accessibility leaked \(forbidden)")
        }
        // Must be the compact counter surface.
        XCTAssertTrue(value.contains("permok="))
        XCTAssertTrue(value.contains("tap="))
        XCTAssertTrue(value.contains("commit="))
    }

    func testEncodedJSONRejectsPrivacyViolationsAndDefaultPayloadIsClean() throws {
        var diagnostics = VoicePipelineDiagnostics()
        diagnostics.permissionOK = true
        diagnostics.engineStarted = true
        diagnostics.wordCallbackCount = 4
        diagnostics.acceptedCount = 2
        diagnostics.committedTokenIndex = 11
        diagnostics.lastErrorDomain = "SFSpeechErrorDomain"
        let data = try diagnostics.encodedJSON()
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.isEmpty)

        for forbidden in VoicePipelineDiagnostics.forbiddenPayloadSubstrings {
            XCTAssertFalse(
                text.lowercased().contains(forbidden.lowercased()),
                "JSON contained forbidden privacy token \(forbidden)"
            )
        }

        // Positive control: assertPrivacySafe throws when a forbidden token appears.
        let poisoned = Data(#"{"transcript":"hello world"}"#.utf8)
        XCTAssertThrowsError(try VoicePipelineDiagnostics.assertPrivacySafe(jsonUTF8: poisoned)) { error in
            guard let violation = error as? VoicePipelineDiagnosticsError,
                  case .privacyViolation = violation else {
                return XCTFail("Expected privacyViolation, got \(error)")
            }
        }
    }

    func testAccessibilityValueDoesNotContainScriptBodySnippet() {
        // Even if a caller tried to stuff text into lastErrorDomain, the privacy
        // JSON gate still blocks known field names; accessibility remains counters.
        var diagnostics = VoicePipelineDiagnostics()
        diagnostics.lastErrorDomain = "NSOSStatusErrorDomain"
        diagnostics.inputCommonFormat = "pcmFloat32"
        diagnostics.floatChannelAccessAvailable = true
        let value = diagnostics.accessibilityValue
        XCTAssertTrue(value.hasPrefix("permOK="))
        XCTAssertFalse(value.contains("\n"))
        XCTAssertLessThan(value.count, 500, "Diagnostic AX value must stay compact")
        // Format diagnostics remain class labels only.
        XCTAssertTrue(value.contains("fmt=pcmFloat32"))
        XCTAssertTrue(value.contains("f32=1"))
        XCTAssertFalse(value.lowercased().contains("transcript"))
    }

    // MARK: - Service alignment note (indices only)

    @MainActor
    func testSpeechServiceAlignmentNotesUpdateCountersOnly() {
        let service = SpeechRecognitionService(
            speechPermissionRequester: { $0(.denied) },
            microphonePermissionRequester: { $0(false) }
        )
        XCTAssertEqual(service.diagnostics.alignmentObservationCount, 0)
        service.noteAlignmentObservation(
            accepted: false,
            committedTokenIndex: 3,
            candidateIndex: 3,
            confidence: 0.4,
            provisionalIndex: nil,
            strongStreak: 0
        )
        service.noteAlignmentObservation(
            accepted: true,
            committedTokenIndex: 5,
            candidateIndex: 7,
            confidence: 0.825,
            provisionalIndex: 7,
            strongStreak: 1
        )
        XCTAssertEqual(service.diagnostics.alignmentObservationCount, 2)
        XCTAssertEqual(service.diagnostics.acceptedCount, 1)
        XCTAssertEqual(service.diagnostics.committedTokenIndex, 5)
        // No transcript text is stored by the note API.
        XCTAssertEqual(service.transcript, "")
    }

    @MainActor
    func testSpeechServiceDeniedStartSetsPermissionDiagnostic() async {
        let service = SpeechRecognitionService(
            speechPermissionRequester: { resume in
                DispatchQueue.global().async { resume(.denied) }
            },
            microphonePermissionRequester: { resume in
                DispatchQueue.global().async { resume(true) }
            },
            speechAuthorizationStatusProvider: { .notDetermined },
            microphonePermissionStatusProvider: { .undetermined }
        )
        await service.start(language: "en-US") { _ in }
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(service.lastPermissionFailure, .speechDenied)
        XCTAssertFalse(service.diagnostics.permissionOK)
        XCTAssertFalse(service.diagnostics.engineStarted)
    }
}

#endif
