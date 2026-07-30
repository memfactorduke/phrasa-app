#if DEBUG
import AVFAudio
import Foundation
import os

// MARK: - Privacy-safe voice pipeline diagnostics

/// Counters and coarse setup flags only — never transcript, script, or token text.
/// Used by DEBUG physical-device harnesses and unit tests. Safe to serialize to
/// accessibility values and app-container JSON for `devicectl` copy-out.
struct VoicePipelineDiagnostics: Equatable, Sendable, Codable {
    var permissionOK = false
    /// Compact terminal permission failure code for physical QA.
    var permissionFailureCode = ""
    /// Microphone TCC snapshot: undetermined / granted / denied / unknown.
    var micPermission = "unknown"
    /// Speech auth snapshot: notDetermined / authorized / denied / restricted / unknown.
    var speechPermission = "unknown"
    var recognizerAvailable = false
    var onDeviceRequired = false
    /// Input sample rate rounded to nearest 100 Hz (identity only; not a device name).
    var inputSampleRateBucket = 0
    var inputChannelCount = 0
    /// Coarse input port class only: builtIn / bluetooth / headset / other / unknown.
    var inputPortClass = "unknown"
    /// Privacy-safe AVAudioCommonFormat class (e.g. pcmFloat32 / pcmInt16 / other / unknown).
    var inputCommonFormat = "unknown"
    /// Whether the input format is interleaved.
    var inputInterleaved = false
    /// True once any tap buffer exposed floatChannelData (DEBUG energy path).
    var floatChannelAccessAvailable = false
    /// True once any tap buffer exposed int16ChannelData (DEBUG energy path).
    var int16ChannelAccessAvailable = false
    /// Tap buffers where neither float nor int16 channel access was available.
    var unsupportedFormatBufferCount = 0
    var engineStarted = false
    var tapBufferCount = 0
    var nonSilentBufferCount = 0
    /// Peak coarse RMS bucket 0…10 seen this session (0 = silence).
    var peakRMSBucket = 0
    var recognitionCallbackCount = 0
    var wordCallbackCount = 0
    var lastErrorDomain = ""
    var lastErrorCode = 0
    var alignmentObservationCount = 0
    var acceptedCount = 0
    var committedTokenIndex = 0
    /// Last accepted alignment proposal; indices and confidence only, never text.
    var lastAcceptedCandidateIndex = -1
    var lastAcceptedConfidencePermille = 0
    var lastAcceptedProvisionalIndex = -1
    var lastAcceptedStrongStreak = 0
    var statusLabel = "idle"
    var healthLabel = "inactive"

    /// Compact stable key=value surface for XCTest accessibility reads.
    var accessibilityValue: String {
        [
            "permOK=\(permissionOK ? 1 : 0)",
            "permFail=\(permissionFailureCode.isEmpty ? "none" : permissionFailureCode)",
            "mic=\(micPermission)",
            "speech=\(speechPermission)",
            "recOK=\(recognizerAvailable ? 1 : 0)",
            "onDev=\(onDeviceRequired ? 1 : 0)",
            "eng=\(engineStarted ? 1 : 0)",
            "tap=\(tapBufferCount)",
            "nonsil=\(nonSilentBufferCount)",
            "rms=\(peakRMSBucket)",
            "cb=\(recognitionCallbackCount)",
            "word=\(wordCallbackCount)",
            "align=\(alignmentObservationCount)",
            "acc=\(acceptedCount)",
            "commit=\(committedTokenIndex)",
            "cand=\(lastAcceptedCandidateIndex)",
            "conf=\(lastAcceptedConfidencePermille)",
            "prov=\(lastAcceptedProvisionalIndex)",
            "streak=\(lastAcceptedStrongStreak)",
            "err=\(lastErrorDomain):\(lastErrorCode)",
            "sr=\(inputSampleRateBucket)",
            "ch=\(inputChannelCount)",
            "port=\(inputPortClass)",
            "fmt=\(inputCommonFormat)",
            "intl=\(inputInterleaved ? 1 : 0)",
            "f32=\(floatChannelAccessAvailable ? 1 : 0)",
            "i16=\(int16ChannelAccessAvailable ? 1 : 0)",
            "unsup=\(unsupportedFormatBufferCount)",
            "status=\(statusLabel)",
            "health=\(healthLabel)",
        ].joined(separator: " ")
    }

    static let accessibilityIdentifier = "VoicePipelineDiagnostics"
    static let fileName = "voice-pipeline-diagnostics.json"

    /// Keys that must never appear in encoded diagnostic payloads (privacy gate).
    static let forbiddenPayloadSubstrings: [String] = [
        "transcript", "script", "body", "tail", "utterance", "hypothesis",
        "substring", "tokenText", "recognizedText", "partialText",
    ]

    mutating func resetForNewSession() {
        self = VoicePipelineDiagnostics()
    }

    /// Coarse energy bucket 0…10 from float samples in −1…1.
    /// Uses peak-abs with RMS assist so quiet room speech still registers.
    /// Pure and privacy-safe: discards samples; never stores audio.
    static func rmsBucket(samples: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        var peak: Float = 0
        // Bound work: stride through long buffers.
        let step = max(1, count / 256)
        var n = 0
        var i = 0
        while i < count {
            let s = samples[i]
            let a = abs(s)
            if a > peak { peak = a }
            sum += s * s
            n += 1
            i += step
        }
        guard n > 0 else { return 0 }
        let rms = sqrt(sum / Float(n))
        return energyBucket(peakAbs: peak, rms: rms)
    }

    /// Map peak/RMS into 0…10. Sensitive enough for distant room TTS.
    static func energyBucket(peakAbs: Float, rms: Float) -> Int {
        let peak = max(0, peakAbs)
        let r = max(0, rms)
        // Peak-first: a single speech frame often has low RMS but clear peaks.
        if peak < 0.0004 && r < 0.0002 { return 0 }
        if peak < 0.001 || r < 0.0005 { return 1 }
        if peak < 0.003 || r < 0.0015 { return 2 }
        if peak < 0.008 || r < 0.004 { return 3 }
        if peak < 0.02 || r < 0.01 { return 4 }
        if peak < 0.05 || r < 0.025 { return 5 }
        if peak < 0.1 || r < 0.05 { return 6 }
        if peak < 0.18 || r < 0.09 { return 7 }
        if peak < 0.3 || r < 0.15 { return 8 }
        if peak < 0.5 || r < 0.25 { return 9 }
        return 10
    }

    static func isNonSilent(rmsBucket: Int) -> Bool {
        // Bucket 1 is weak ambient/speech at a distance — still counts as non-silent.
        rmsBucket >= 1
    }

    /// Privacy-safe AVAudioSession port class (never a device name).
    static func inputPortClass(from portType: AVAudioSession.Port?) -> String {
        guard let portType else { return "unknown" }
        switch portType {
        case .builtInMic: return "builtIn"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "bluetooth"
        case .headsetMic: return "headset"
        case .usbAudio: return "usb"
        case .carAudio: return "car"
        default: return "other"
        }
    }

    /// Privacy-safe AVAudioCommonFormat class (never a device/vendor name).
    static func commonFormatClass(_ format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: return "pcmFloat32"
        case .pcmFormatFloat64: return "pcmFloat64"
        case .pcmFormatInt16: return "pcmInt16"
        case .pcmFormatInt32: return "pcmInt32"
        case .otherFormat: return "other"
        @unknown default: return "unknown"
        }
    }

    /// Sample-rate identity without floating noise (nearest 100 Hz).
    static func sampleRateBucket(_ sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int((sampleRate / 100.0).rounded() * 100.0)
    }

    /// DEBUG convenience: mirrors production `SpeechProductStatus.afterEngineReady()`.
    /// Product status transition itself does not depend on this type.
    static func statusAfterEngineReady() -> (SpeechRecognitionService.Status, SpeechPipelineHealth) {
        SpeechProductStatus.afterEngineReady()
    }

    /// Encode JSON; fails the privacy gate if forbidden substrings appear as keys
    /// or if arbitrary free text fields sneak in beyond allowlisted scalars.
    func encodedJSON(encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try Self.assertPrivacySafe(jsonUTF8: data)
        return data
    }

    static func assertPrivacySafe(jsonUTF8 data: Data) throws {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else {
            throw VoicePipelineDiagnosticsError.unreadablePayload
        }
        for forbidden in forbiddenPayloadSubstrings {
            // Allow only if the forbidden token is not present at all.
            if text.contains(forbidden.lowercased()) {
                throw VoicePipelineDiagnosticsError.privacyViolation(forbidden)
            }
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Phrasa", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// DEBUG physical runs only — Release builds never call this from the service.
    static func persist(_ diagnostics: VoicePipelineDiagnostics, to fileURL: URL = defaultFileURL()) {
        do {
            let data = try diagnostics.encodedJSON()
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort diagnostic surface; never throw into speech pipeline.
        }
    }

    static func parseInt(_ key: String, from accessibilityValue: String) -> Int? {
        // Match key=value tokens (value ends at space).
        guard let token = parseToken(key, from: accessibilityValue) else { return nil }
        // err=domain:code — not an int key.
        if key == "err" { return nil }
        return Int(token)
    }

    static func parseFlag(_ key: String, from accessibilityValue: String) -> Bool? {
        guard let value = parseInt(key, from: accessibilityValue) else { return nil }
        return value != 0
    }

    /// String token for non-integer keys such as mic, speech, and permFail.
    static func parseToken(_ key: String, from accessibilityValue: String) -> String? {
        let pattern = "\(key)="
        guard let range = accessibilityValue.range(of: pattern) else { return nil }
        let rest = accessibilityValue[range.upperBound...]
        return rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }
}

enum VoicePipelineDiagnosticsError: Error, Equatable {
    case unreadablePayload
    case privacyViolation(String)
}

// MARK: - Audio-thread tap counters (DEBUG path)

/// Which PCM channel pointers the energy meter can read (no samples retained).
struct VoiceBufferChannelAccess: Equatable, Sendable {
    var hasFloat32 = false
    var hasInt16 = false

    var isSupported: Bool { hasFloat32 || hasInt16 }
}

/// Lock-protected counters updated from the audio tap. Never stores buffer contents.
final class VoiceTapDiagnosticsSink: @unchecked Sendable {
    private struct State {
        var tapBufferCount = 0
        var nonSilentBufferCount = 0
        var peakRMSBucket = 0
        var floatChannelAccessAvailable = false
        var int16ChannelAccessAvailable = false
        var unsupportedFormatBufferCount = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func reset() {
        lock.withLock { $0 = State() }
    }

    func noteBuffer(rmsBucket: Int, channelAccess: VoiceBufferChannelAccess = VoiceBufferChannelAccess()) {
        lock.withLock { state in
            state.tapBufferCount += 1
            if channelAccess.hasFloat32 { state.floatChannelAccessAvailable = true }
            if channelAccess.hasInt16 { state.int16ChannelAccessAvailable = true }
            if !channelAccess.isSupported {
                state.unsupportedFormatBufferCount += 1
            }
            if VoicePipelineDiagnostics.isNonSilent(rmsBucket: rmsBucket) {
                state.nonSilentBufferCount += 1
            }
            if rmsBucket > state.peakRMSBucket {
                state.peakRMSBucket = rmsBucket
            }
        }
    }

    func snapshot() -> (
        tapBufferCount: Int,
        nonSilentBufferCount: Int,
        peakRMSBucket: Int,
        floatChannelAccessAvailable: Bool,
        int16ChannelAccessAvailable: Bool,
        unsupportedFormatBufferCount: Int
    ) {
        lock.withLock { state in
            (
                state.tapBufferCount,
                state.nonSilentBufferCount,
                state.peakRMSBucket,
                state.floatChannelAccessAvailable,
                state.int16ChannelAccessAvailable,
                state.unsupportedFormatBufferCount
            )
        }
    }
}

// MARK: - PCM buffer energy helper

enum VoiceBufferEnergy {
    /// Privacy-safe channel-access probe (no samples retained beyond the call).
    static func channelAccess(from buffer: AVAudioPCMBuffer) -> VoiceBufferChannelAccess {
        VoiceBufferChannelAccess(
            hasFloat32: buffer.floatChannelData != nil,
            hasInt16: buffer.int16ChannelData != nil
        )
    }

    /// Best-effort energy bucket from an AVAudioPCMBuffer without retaining audio.
    /// Handles float32 and int16 channel data (common on-device input formats).
    static func rmsBucket(
        from buffer: AVAudioPCMBuffer,
        access: VoiceBufferChannelAccess? = nil
    ) -> Int {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let resolved = access ?? channelAccess(from: buffer)
        if resolved.hasFloat32, let channel = buffer.floatChannelData?[0] {
            return VoicePipelineDiagnostics.rmsBucket(samples: channel, count: frames)
        }

        if resolved.hasInt16, let channel = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            var peak: Float = 0
            let step = max(1, frames / 256)
            var n = 0
            var i = 0
            let scale = 1.0 / Float(Int16.max)
            while i < frames {
                let s = Float(channel[i]) * scale
                let a = abs(s)
                if a > peak { peak = a }
                sum += s * s
                n += 1
                i += step
            }
            guard n > 0 else { return 0 }
            return VoicePipelineDiagnostics.energyBucket(peakAbs: peak, rms: sqrt(sum / Float(n)))
        }

        // Unsupported layout for the energy meter — report silence energy without
        // claiming channel access worked (caller tracks unsupportedFormatBufferCount).
        return 0
    }
}

#endif
