import AVFAudio
import Foundation
import Observation
import Speech

// MARK: - Pipeline health / events (Lane C–ready)

/// Explicit silence/health surface for UI. Stable and Equatable.
/// `Status` remains the coarser Reader-compatible façade.
enum SpeechPipelineHealth: Equatable, Sendable {
    case inactive
    case starting
    case hearingSpeech
    case silent
    case recovering
    case terminalFailure(String)
}

struct SpeechPipelineEvent: Equatable, Sendable {
    var tail: String
    var health: SpeechPipelineHealth
    var status: SpeechRecognitionService.Status
}

/// Deduplicating event emission for lifecycle + transcript updates.
enum SpeechEventEmission {
    /// Returns the next event only when it differs from `previous` (no duplicates).
    static func nextEvent(
        previous: SpeechPipelineEvent?,
        tail: String,
        health: SpeechPipelineHealth,
        status: SpeechRecognitionService.Status
    ) -> SpeechPipelineEvent? {
        let event = SpeechPipelineEvent(tail: tail, health: health, status: status)
        guard previous != event else { return nil }
        return event
    }
}

// MARK: - Sendable segment snapshot (never hop SDK objects across actors)

struct SpeechSegmentSnapshot: Equatable, Sendable {
    var substring: String
    var timestamp: TimeInterval
    var duration: TimeInterval
    var confidence: Float
}

// MARK: - Rolling tail normalizer (pure)

/// Bounded-cost cumulative / revised-partial tail for alignment.
struct SpeechRollingTailNormalizer: Equatable, Sendable {
    var maxTailWords: Int
    var silenceFlushSeconds: TimeInterval

    private(set) var committed: [String] = []
    private(set) var currentTask: [String] = []
    private(set) var lastSpeechAt: TimeInterval?
    private(set) var taskOrdinal: Int = 0

    init(maxTailWords: Int = 16, silenceFlushSeconds: TimeInterval = 8) {
        self.maxTailWords = max(1, maxTailWords)
        self.silenceFlushSeconds = max(0, silenceFlushSeconds)
    }

    mutating func rotateTask() {
        commitCurrentTask()
        taskOrdinal += 1
    }

    mutating func flush() {
        committed = []
        currentTask = []
        lastSpeechAt = nil
    }

    @discardableResult
    mutating func apply(
        segments: [SpeechSegmentSnapshot],
        isFinal: Bool,
        at now: TimeInterval
    ) -> String {
        if let last = lastSpeechAt, now - last >= silenceFlushSeconds {
            committed = []
            currentTask = []
            lastSpeechAt = nil
        }

        let words = Self.words(from: segments)
        if !words.isEmpty {
            lastSpeechAt = now
            currentTask = words.count > maxTailWords
                ? Array(words.suffix(maxTailWords))
                : words
        }

        if isFinal {
            commitCurrentTask()
        }
        return tailString()
    }

    func tailString() -> String {
        if committed.isEmpty { return currentTask.joined(separator: " ") }
        if currentTask.isEmpty { return committed.joined(separator: " ") }
        var combined: [String] = []
        combined.reserveCapacity(min(maxTailWords, committed.count + currentTask.count))
        combined.append(contentsOf: committed)
        combined.append(contentsOf: currentTask)
        if combined.count > maxTailWords {
            return combined.suffix(maxTailWords).joined(separator: " ")
        }
        return combined.joined(separator: " ")
    }

    private mutating func commitCurrentTask() {
        guard !currentTask.isEmpty else { return }
        committed.append(contentsOf: currentTask)
        currentTask = []
        if committed.count > maxTailWords {
            committed = Array(committed.suffix(maxTailWords))
        }
    }

    private static func words(from segments: [SpeechSegmentSnapshot]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(segments.count)
        for segment in segments {
            for part in segment.substring.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
                if !part.isEmpty { out.append(String(part)) }
            }
        }
        return out
    }
}

// MARK: - Script contextual strings (pure)

enum SpeechContextHints {
    static let maxCount = 80
    static let maxLength = 100
    /// Meaningful terms only — at least 4 characters after punctuation trim.
    static let minTermLength = 4

    private static let stopWords: Set<String> = [
        "that", "this", "these", "those", "with", "from", "have", "has", "had",
        "were", "been", "being", "will", "would", "could", "should", "shall",
        "might", "must", "about", "into", "over", "under", "again", "there",
        "here", "when", "what", "who", "how", "why", "which", "than", "very",
        "also", "just", "then", "them", "they", "their", "your", "our", "its",
    ]

    /// Deterministic document-order unigrams: ≥4 chars, case/diacritic-insensitive
    /// dedupe, at most 80 terms each ≤100 chars. No n-gram flooding.
    static func make(from script: String) -> [String] {
        let tokens = script
            .split { $0.isWhitespace || $0.isNewline }
            .map(trimPunctuation)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        var results: [String] = []
        var seen = Set<String>()
        results.reserveCapacity(min(maxCount, tokens.count))

        for word in tokens {
            guard results.count < maxCount else { break }
            guard word.count >= minTermLength else { continue }
            let clipped = word.count <= maxLength ? word : String(word.prefix(maxLength))
            let key = fold(clipped)
            guard !key.isEmpty, !stopWords.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(clipped)
        }
        return results
    }

    private static func fold(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func trimPunctuation(_ raw: Substring) -> String {
        let scalars = raw.unicodeScalars
        let start = scalars.firstIndex(where: { CharacterSet.alphanumerics.contains($0) })
        let end = scalars.lastIndex(where: { CharacterSet.alphanumerics.contains($0) })
        guard let start, let end, start <= end else { return "" }
        return String(String.UnicodeScalarView(scalars[start...end]))
    }
}

// MARK: - Restart governance (pure)

enum SpeechSessionEndReason: Equatable, Sendable {
    case healthyFinal
    case noSpeech
    case recoverableError(domain: String, code: Int, message: String)
    case terminalError(domain: String, code: Int, message: String)
}

enum SpeechRestartPlan: Equatable, Sendable {
    case restart(delay: Duration)
    case terminal(message: String)
}

/// Tracks sustained speech without double-counting cumulative partial durations.
struct SpeechSessionEvidence: Equatable, Sendable {
    private(set) var partialCount = 0
    private(set) var wordCount = 0
    private(set) var firstSpeechAt: TimeInterval?
    private(set) var lastSpeechAt: TimeInterval?
    /// Max unique utterance extent (max end − min start) across hypotheses.
    private(set) var maxHypothesisExtent: TimeInterval = 0
    private(set) var sawFinalWithContent = false

    /// Wall-clock span between first and last recognition callbacks with words.
    var callbackSpan: TimeInterval {
        guard let first = firstSpeechAt, let last = lastSpeechAt else { return 0 }
        return max(0, last - first)
    }

    /// Sustained evidence only — a lone partial never clears failure budgets.
    var isMeaningful: Bool {
        if sawFinalWithContent && wordCount >= 2 { return true }
        if partialCount >= 2 && wordCount >= 3 && callbackSpan >= 0.6 { return true }
        if partialCount >= 4 && callbackSpan >= 1.0 { return true }
        if partialCount >= 2 && maxHypothesisExtent >= 0.8 && wordCount >= 2 { return true }
        return false
    }

    mutating func note(segments: [SpeechSegmentSnapshot], isFinal: Bool, at now: TimeInterval) {
        let words = segments.reduce(into: 0) { count, segment in
            count += segment.substring.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        guard words > 0 else { return }
        if !isFinal { partialCount += 1 }
        wordCount = max(wordCount, words)
        if firstSpeechAt == nil { firstSpeechAt = now }
        lastSpeechAt = now

        // Extent of this hypothesis only — never sum durations across partials.
        if let minTs = segments.map(\.timestamp).min(),
           let maxEnd = segments.map({ $0.timestamp + max(0, $0.duration) }).max() {
            maxHypothesisExtent = max(maxHypothesisExtent, max(0, maxEnd - minTs))
        }

        if isFinal && words >= 2 {
            sawFinalWithContent = true
        }
    }
}

struct SpeechRestartGovernor: Equatable, Sendable {
    private(set) var failureCount = 0
    private(set) var noSpeechCount = 0
    private(set) var shortLoopCount = 0
    private(set) var evidence = SpeechSessionEvidence()
    private(set) var sessionStartedAt: TimeInterval?

    static let maxFailures = 4
    static let maxShortLoops = 5
    static let shortLoopThreshold: TimeInterval = 0.75
    /// Caps no-speech restart backoff only; silence never terminals.
    static let noSpeechBackoffCap = 6

    // Domain / code constants (SDK headers as truth).
    static let assistantDomain = "kAFAssistantErrorDomain"
    static let lsrDomain = "kLSRErrorDomain"
    static let speechErrorDomain = "SFSpeechErrorDomain"
    static let noSpeechCode = 1110
    static let notAuthorizedCode = 1700
    static let lsrDictationDisabledCode = 201
    static let speechAudioReadFailedCode = 2 // SFSpeechErrorCode.audioReadFailed
    static let speechInternalCode = 1
    static let speechTimeoutCode = 12

    mutating func beginSession(at now: TimeInterval) {
        evidence = SpeechSessionEvidence()
        sessionStartedAt = now
    }

    mutating func noteRecognition(segments: [SpeechSegmentSnapshot], isFinal: Bool, at now: TimeInterval) {
        evidence.note(segments: segments, isFinal: isFinal, at: now)
        // Meaningful speech resets the no-speech backoff only (not failure budgets).
        if evidence.isMeaningful {
            noSpeechCount = 0
        }
    }

    mutating func resetBudgets() {
        failureCount = 0
        noSpeechCount = 0
        shortLoopCount = 0
    }

    mutating func endSession(reason: SpeechSessionEndReason, at now: TimeInterval) -> SpeechRestartPlan {
        let duration = sessionStartedAt.map { now - $0 } ?? 0
        let meaningful = evidence.isMeaningful
        let short = duration < Self.shortLoopThreshold

        switch reason {
        case .healthyFinal:
            if meaningful { resetBudgets() }
            return .restart(delay: SpeechRestartPolicy.delay(afterFailureCount: 0))

        case .noSpeech:
            // Healthy silence may be indefinite. Capped backoff only — never spend
            // failure/short-loop budgets, never terminal after N silent rotations.
            noSpeechCount += 1
            let backoff = min(noSpeechCount, Self.noSpeechBackoffCap)
            return .restart(delay: SpeechRestartPolicy.delay(afterFailureCount: backoff))

        case .recoverableError:
            // Partials alone do not cancel the failure; only sustained evidence softens it.
            if short && !meaningful { shortLoopCount += 1 }
            failureCount += 1
            if meaningful {
                failureCount = max(0, failureCount - 1)
                shortLoopCount = 0
            }
            if shortLoopCount >= Self.maxShortLoops || failureCount > Self.maxFailures {
                return .terminal(message: "Speech recognition stopped repeatedly. Tap Play to try again.")
            }
            return .restart(delay: SpeechRestartPolicy.delay(afterFailureCount: failureCount))

        case .terminalError(_, _, let message):
            return .terminal(message: message.isEmpty
                ? "Speech recognition is not available right now."
                : message)
        }
    }

    /// Classify NSError domain/code without depending on localized strings.
    static func classifyError(domain: String, code: Int, message: String) -> SpeechSessionEndReason {
        if isNoSpeech(domain: domain, code: code) {
            return .noSpeech
        }
        if isTerminal(domain: domain, code: code) {
            return .terminalError(domain: domain, code: code, message: userMessage(
                domain: domain, code: code, fallback: message
            ))
        }
        return .recoverableError(domain: domain, code: code, message: message)
    }

    /// Documented dictation "failed to recognize any speech" — exact domain + code.
    static func isNoSpeech(domain: String, code: Int) -> Bool {
        domain == assistantDomain && code == noSpeechCode
    }

    static func isTerminal(domain: String, code: Int) -> Bool {
        // kAFAssistantErrorDomain 1700 — not authorized.
        if domain == assistantDomain && code == notAuthorizedCode { return true }
        // kLSRErrorDomain 201 — Siri/Dictation disabled.
        if domain == lsrDomain && code == lsrDictationDisabledCode { return true }
        // SFSpeechErrorDomain: audioReadFailed is terminal; internal/timeout are recoverable.
        if domain == speechErrorDomain && code == speechAudioReadFailedCode { return true }
        // Hard audio-session failures.
        if domain == "NSOSStatusErrorDomain" || domain == "AVAudioSessionErrorDomain" {
            if code == Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue)
                || code == Int(AVAudioSession.ErrorCode.cannotStartRecording.rawValue)
                || code == Int(AVAudioSession.ErrorCode.isBusy.rawValue)
                || code == Int(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue) {
                return true
            }
        }
        return false
    }

    static func userMessage(domain: String, code: Int, fallback: String) -> String {
        if domain == assistantDomain && code == notAuthorizedCode {
            return "Speech recognition is not authorized. Check Settings, or use Speed mode."
        }
        if domain == lsrDomain && code == lsrDictationDisabledCode {
            return "Dictation is disabled on this device. Enable it in Settings, or use Speed mode."
        }
        if domain == speechErrorDomain && code == speechAudioReadFailedCode {
            return "Microphone audio could not be read. Tap Play to try again."
        }
        if SpeechActivationRecovery.isPriorityContention(domain: domain, code: code) {
            return SpeechActivationRecovery.micInUseMessage
        }
        if !fallback.isEmpty { return fallback }
        return "Speech recognition is not available right now."
    }
}

enum SpeechRestartPolicy {
    static func delay(afterFailureCount count: Int) -> Duration {
        let milliseconds = min(2_000, 150 * max(1, count + 1) * max(1, count + 1))
        return .milliseconds(milliseconds)
    }
}

// MARK: - Activation priority contention recovery (pure)

/// Bounded setup retry for `AVAudioSession.ErrorCode.insufficientPriority` (`!pri`) only.
/// Attempt semantics: 4 total `begin` attempts (1 initial + 3 delayed retries).
/// Delays between attempts: 150 ms, 300 ms, 600 ms (total 1_050 ms < 3 s).
enum SpeechActivationRecovery: Sendable {
    /// Total begin attempts including the first.
    static let maxBeginAttempts = 4
    /// Delay before attempt N+1 after failed attempt N (1-based index into this list).
    static let retryDelaysMilliseconds = [150, 300, 600]
    static let micInUseMessage =
        "The microphone is in use by another app or a call. Finish that audio, then tap Play."

    static var totalBoundedDelayMilliseconds: Int {
        retryDelaysMilliseconds.reduce(0, +)
    }

    /// Exact `!pri` / 561017449 only — never `!int`, `!act`, `!rec`, or auth failures.
    static func isPriorityContention(domain: String, code: Int) -> Bool {
        guard domain == "NSOSStatusErrorDomain" || domain == "AVAudioSessionErrorDomain" else {
            return false
        }
        return code == Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue)
    }

    /// After a failed attempt (1…maxBeginAttempts), delay before the next begin — or nil if exhausted.
    static func delayBeforeRetry(afterFailedAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt < maxBeginAttempts else { return nil }
        let index = attempt - 1
        guard index < retryDelaysMilliseconds.count else { return nil }
        return .milliseconds(retryDelaysMilliseconds[index])
    }

    static func canRetry(afterFailedAttempt attempt: Int) -> Bool {
        delayBeforeRetry(afterFailedAttempt: attempt) != nil
    }

    /// Startup phases that may continue activation after a recoverable `!pri`.
    static func isPermissionsReady(_ phase: SpeechStartupPhase) -> Bool {
        switch phase {
        case .permissionsReady, .startingEngine, .live: true
        case .idle, .awaitingSpeechPermission, .awaitingMicrophonePermission: false
        }
    }

    /// Single predicate for delayed activation retry scheduling (testable).
    static func shouldScheduleRetry(
        domain: String,
        code: Int,
        failedAttempt: Int,
        wantsRecognition: Bool,
        generationMatches: Bool,
        systemAudioBlocked: Bool,
        phase: SpeechStartupPhase
    ) -> Bool {
        isPriorityContention(domain: domain, code: code)
            && canRetry(afterFailedAttempt: failedAttempt)
            && wantsRecognition
            && generationMatches
            && !systemAudioBlocked
            && isPermissionsReady(phase)
    }
}

// MARK: - Callback gate (pure; stale-task race protection)

/// Gates recognition callbacks so a delayed final/error from a prior SFSpeech
/// task cannot tear down the next task after an automatic restart.
enum SpeechCallbackGate {
    static func accepts(
        wantsRecognition: Bool,
        activeRun: Int,
        callbackRun: Int,
        activeToken: Int,
        callbackToken: Int
    ) -> Bool {
        wantsRecognition
            && activeRun == callbackRun
            && activeToken == callbackToken
            && activeToken > 0
    }

    /// Whether `beginRecognition` may create a new request/task/tap.
    /// Blocks stale generation and already-installed audio resources.
    static func canBegin(
        wantsRecognition: Bool,
        run: Int,
        generation: Int,
        hasRecognitionRequest: Bool,
        hasRecognitionTask: Bool,
        tapInstalled: Bool
    ) -> Bool {
        wantsRecognition
            && run == generation
            && !hasRecognitionRequest
            && !hasRecognitionTask
            && !tapInstalled
    }
}

// MARK: - Product status (Release + DEBUG; independent of diagnostics)

/// Production-facing status transitions that must exist in App Store builds.
enum SpeechProductStatus {
    /// After engine + tap + recognition task are live: Listening/silent without waiting for words.
    static func afterEngineReady() -> (SpeechRecognitionService.Status, SpeechPipelineHealth) {
        (.listening, .silent)
    }
}

// MARK: - Input format gate (pure; installTap crash prevention)

/// Rejects input formats that make `installTap` assert or fail at runtime.
/// AVAudioEngine requires a positive finite sample rate and at least one channel
/// (`IsFormatSampleRateAndChannelCountValid`). Zero-channel graphs appear after
/// route loss, media-services reset races, and some simulator/no-mic states.
enum SpeechInputFormatGate {
    static func isValidForTap(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }
}

// MARK: - Startup phase + system-audio prerequisite (pure)

/// Explicit voice startup phases. Listening is only valid after permissions,
/// clear system audio, and a successful engine/tap/task start.
///
/// Permission order is fixed: **microphone first**, then speech recognition.
enum SpeechStartupPhase: Equatable, Sendable {
    case idle
    case awaitingMicrophonePermission
    case awaitingSpeechPermission
    case permissionsReady
    case startingEngine
    case live
}

/// Compact startup coordinator: permission windows + system-audio-blocked prerequisite.
struct SpeechStartupCoordinator: Equatable, Sendable {
    private(set) var phase: SpeechStartupPhase = .idle
    /// True while interruption / media-services loss blocks engine start.
    private(set) var systemAudioBlocked = false

    var isAwaitingPermission: Bool {
        phase == .awaitingMicrophonePermission || phase == .awaitingSpeechPermission
    }

    var isPreLive: Bool {
        switch phase {
        case .idle, .live: false
        case .awaitingMicrophonePermission, .awaitingSpeechPermission, .permissionsReady, .startingEngine:
            true
        }
    }

    /// Permissions granted and system audio clear — engine may start.
    var canBeginEngine: Bool {
        phase == .permissionsReady && !systemAudioBlocked
    }

    mutating func beginStart() {
        phase = .awaitingMicrophonePermission
        systemAudioBlocked = false
    }

    mutating func markMicrophonePermissionGranted() {
        guard phase == .awaitingMicrophonePermission else { return }
        phase = .awaitingSpeechPermission
    }

    mutating func markSpeechPermissionGranted() {
        guard phase == .awaitingSpeechPermission else { return }
        phase = .permissionsReady
    }

    /// Sync system-audio prerequisite from the gate during pre-live startup.
    mutating func setSystemAudioBlocked(_ blocked: Bool) {
        guard isPreLive || phase == .permissionsReady else { return }
        systemAudioBlocked = blocked
    }

    mutating func markEngineStarting() {
        guard canBeginEngine || phase == .permissionsReady && !systemAudioBlocked else { return }
        phase = .startingEngine
    }

    mutating func markEngineLive() {
        phase = .live
        systemAudioBlocked = false
    }

    mutating func reset() {
        phase = .idle
        systemAudioBlocked = false
    }
}

// MARK: - Voice permission gate (pure; mic then speech)

/// Deterministic first-start permission order for Voice Follow and Outline.
enum VoicePermissionStep: Equatable, Sendable, CaseIterable {
    case microphone
    case speechRecognition
}

/// Outcome of inspecting or resolving one permission.
enum VoicePermissionDecision: Equatable, Sendable {
    /// Already authorized — do not re-prompt.
    case proceed
    /// `notDetermined` / undetermined — show the system prompt once.
    case request
    /// Explicit user denial.
    case denied
    /// Parental controls / MDM / system restriction.
    case restricted
}

/// Terminal permission failures before the audio engine starts.
enum VoicePermissionFailure: Equatable, Sendable {
    case microphoneDenied
    case microphoneRestricted
    case speechDenied
    case speechRestricted
    case cancelled
    case requestError(String)

    /// Compact non-sensitive code for accessibility / DEBUG harnesses.
    /// Distinguishes mic vs speech vs restricted vs incomplete request.
    var diagnosticCode: String {
        switch self {
        case .microphoneDenied: "micDenied"
        case .microphoneRestricted: "micRestricted"
        case .speechDenied: "speechDenied"
        case .speechRestricted: "speechRestricted"
        case .cancelled: "cancelled"
        case .requestError: "requestError"
        }
    }

    /// Unmistakable in-app copy. Settings is offered when it can change the state.
    /// Denied never re-prompts: Apple only shows the system alert while undetermined.
    var userMessage: String {
        switch self {
        case .microphoneDenied:
            // App Settings page often omits Microphone; Privacy path is the reliable recovery.
            // Copy is universal iOS (iPhone + iPad) — never device-family-specific (e.g. iPadOS).
            return "Microphone access is off. iOS will not ask again. Enable Phrasa under Settings → Privacy & Security → Microphone, then return and tap Try again. Or use Speed mode."
        case .microphoneRestricted:
            return "Microphone access is restricted on this device (Screen Time or device management). Use Speed mode, or ask an administrator to allow it."
        case .speechDenied:
            return "Speech recognition is off. iOS will not ask again. Enable Phrasa under Settings → Privacy & Security → Speech Recognition, then return and tap Try again. Or use Speed mode."
        case .speechRestricted:
            return "Speech recognition is restricted on this device (Screen Time or device management). Use Speed mode, or ask an administrator to allow it."
        case .cancelled:
            return "Voice start was cancelled."
        case .requestError(let message):
            return message
        }
    }

    var offersOpenSettings: Bool {
        switch self {
        case .microphoneDenied, .speechDenied: true
        case .microphoneRestricted, .speechRestricted, .cancelled, .requestError: false
        }
    }

    var readerStatus: SpeechRecognitionService.Status {
        switch self {
        case .requestError(let message):
            return .unavailable(message)
        case .cancelled:
            return .idle
        case .microphoneDenied, .microphoneRestricted, .speechDenied, .speechRestricted:
            return .denied
        }
    }
}

/// Pure policy for mic-then-speech authorization. No AV/Speech side effects.
enum VoicePermissionGate: Sendable {
    /// Fixed order: never reverse, never request both concurrently.
    static let requestOrder: [VoicePermissionStep] = [.microphone, .speechRecognition]

    static func decision(
        forMicrophone permission: AVAudioApplication.recordPermission
    ) -> VoicePermissionDecision {
        switch permission {
        case .undetermined: .request
        case .granted: .proceed
        case .denied: .denied
        // Unknown raw values must not hard-deny without invoking the system API.
        @unknown default: .request
        }
    }

    static func decision(
        forSpeech status: SFSpeechRecognizerAuthorizationStatus
    ) -> VoicePermissionDecision {
        switch status {
        case .notDetermined: .request
        case .authorized: .proceed
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .request
        }
    }

    /// Whether `start` should call the system permission API for this decision.
    ///
    /// Only **undetermined / notDetermined** (`.request`) shows a system alert.
    /// Once the user grants or denies recording, the completion runs immediately
    /// with no alert; there is no public API to re-prompt from `.denied`.
    static func shouldInvokeSystemPrompt(
        for decision: VoicePermissionDecision
    ) -> Bool {
        switch decision {
        case .request: true
        case .proceed, .denied, .restricted: false
        }
    }

    static func afterMicrophonePrompt(granted: Bool) -> VoicePermissionDecision {
        granted ? .proceed : .denied
    }

    /// Map a mic prompt result against post-prompt TCC status so incomplete
    /// registration is not reported as a user denial (Open Settings would be empty).
    static func failureAfterMicrophonePrompt(
        granted: Bool,
        statusAfter: AVAudioApplication.recordPermission
    ) -> VoicePermissionFailure? {
        if granted { return nil }
        switch statusAfter {
        case .granted:
            // Concurrent grant between callback and re-read — treat as success.
            return nil
        case .denied:
            return .microphoneDenied
        case .undetermined:
            return .requestError(
                "Microphone permission did not complete. Tap Try again and choose Allow when iOS asks."
            )
        @unknown default:
            return .requestError(
                "Microphone permission did not complete. Tap Try again and choose Allow when iOS asks."
            )
        }
    }

    /// Map a speech prompt result against post-prompt authorization status.
    static func failureAfterSpeechPrompt(
        status: SFSpeechRecognizerAuthorizationStatus
    ) -> VoicePermissionFailure? {
        switch status {
        case .authorized:
            return nil
        case .denied:
            return .speechDenied
        case .restricted:
            return .speechRestricted
        case .notDetermined:
            return .requestError(
                "Speech recognition permission did not complete. Tap Try again and choose Allow when iOS asks."
            )
        @unknown default:
            return .requestError(
                "Speech recognition permission did not resolve. Try again, or check Settings."
            )
        }
    }

    static func failure(
        forMicrophone decision: VoicePermissionDecision
    ) -> VoicePermissionFailure? {
        switch decision {
        case .proceed, .request: nil
        case .denied: .microphoneDenied
        case .restricted: .microphoneRestricted
        }
    }

    static func failure(
        forSpeech decision: VoicePermissionDecision
    ) -> VoicePermissionFailure? {
        switch decision {
        case .proceed, .request: nil
        case .denied: .speechDenied
        case .restricted: .speechRestricted
        }
    }

    /// True when a second `start` must not raise overlapping system prompts.
    static func shouldIgnoreOverlappingStart(
        wantsRecognition: Bool,
        isAwaitingPermission: Bool
    ) -> Bool {
        wantsRecognition && isAwaitingPermission
    }
}

// MARK: - System audio recovery gate (pure)

/// Sendable snapshot of AVAudioSession notification payloads, taken before MainActor hop.
enum AudioSessionSystemEvent: Equatable, Sendable {
    case interruption(typeRawValue: UInt)
    case routeChange(reasonRawValue: UInt)
    case mediaServicesLost
    case mediaServicesReset

    /// Missing/malformed interruption type → nil (safe no-op at the call site).
    static func interruption(userInfo: [AnyHashable: Any]?) -> Self? {
        guard let raw = uint(userInfo?[AVAudioSessionInterruptionTypeKey]) else { return nil }
        return .interruption(typeRawValue: raw)
    }

    static func routeChange(userInfo: [AnyHashable: Any]?) -> Self {
        .routeChange(reasonRawValue: uint(userInfo?[AVAudioSessionRouteChangeReasonKey])
            ?? AVAudioSession.RouteChangeReason.unknown.rawValue)
    }

    private static func uint(_ raw: Any?) -> UInt? {
        (raw as? UInt) ?? (raw as? NSNumber)?.uintValue
    }
}

/// Service-side effects produced by the pure gate (never touches AVFoundation).
struct SpeechSystemAudioEffect: Equatable, Sendable {
    var tearDownKeepIntent = false
    var cancelRecovery = false
    var scheduleRecoveryID: Int?
}

/// Interruption / route / media-services recovery reducer.
/// End recovers from user intent (ignores shouldResume). Routes/media while blocked
/// stay pending. Duplicate began/lost for an already-active condition is a no-op.
/// Duplicate ended when not interrupted is a no-op.
/// First of each condition still tears down even if the other is active.
/// One recovery identity at a time; stale takes cannot clear a newer id.
/// `allowRecovery: false` during pre-live startup tracks block state without scheduling.
struct SpeechSystemAudioGate: Equatable, Sendable {
    private(set) var interrupted = false
    private(set) var mediaServicesLost = false
    private(set) var recoveryPending = false
    private(set) var replaceEnginePending = false
    /// 0 = none. Positive = identity of the in-flight recovery task.
    private(set) var activeRecoveryID = 0
    private var recoverySeq = 0

    var isBlocked: Bool { interrupted || mediaServicesLost }

    private static let invalidatingRoutes: Set<UInt> = [
        AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
    ]

    mutating func handle(
        _ event: AudioSessionSystemEvent,
        wantsRecognition: Bool,
        allowRecovery: Bool = true
    ) -> SpeechSystemAudioEffect {
        guard wantsRecognition else { return SpeechSystemAudioEffect() }
        switch event {
        case .interruption(let raw):
            switch AVAudioSession.InterruptionType(rawValue: raw) {
            case .began:
                // Idempotent for this condition; still tears down on first began while media-lost.
                guard !interrupted else { return SpeechSystemAudioEffect() }
                interrupted = true
                return block()
            case .ended:
                // Duplicate ended (not interrupted) is a safe no-op.
                guard interrupted else { return SpeechSystemAudioEffect() }
                interrupted = false
                recoveryPending = true
                return allowRecovery ? scheduleIfReady() : SpeechSystemAudioEffect()
            default:
                return SpeechSystemAudioEffect()
            }
        case .routeChange(let raw):
            guard Self.invalidatingRoutes.contains(raw) else { return SpeechSystemAudioEffect() }
            recoveryPending = true
            if isBlocked || !allowRecovery { return SpeechSystemAudioEffect() }
            return scheduleIfReady()
        case .mediaServicesLost:
            // Idempotent for this condition; still tears down on first lost while interrupted.
            guard !mediaServicesLost else { return SpeechSystemAudioEffect() }
            mediaServicesLost = true
            return block()
        case .mediaServicesReset:
            mediaServicesLost = false
            replaceEnginePending = true
            recoveryPending = true
            return allowRecovery ? scheduleIfReady() : SpeechSystemAudioEffect()
        }
    }

    /// stop() / fail(): clear blocking + pending and invalidate any recovery.
    mutating func reset() -> SpeechSystemAudioEffect {
        var effect = SpeechSystemAudioEffect()
        effect.cancelRecovery = activeRecoveryID != 0
        recoverySeq += 1
        interrupted = false
        mediaServicesLost = false
        recoveryPending = false
        replaceEnginePending = false
        activeRecoveryID = 0
        return effect
    }

    /// Consume work for `id` only if still current. Returns replace-engine flag, or nil if stale.
    mutating func takeRecoveryWork(id: Int) -> Bool? {
        guard id != 0, id == activeRecoveryID else { return nil }
        activeRecoveryID = 0
        let replace = replaceEnginePending
        replaceEnginePending = false
        recoveryPending = false
        return replace
    }

    private mutating func block() -> SpeechSystemAudioEffect {
        var effect = SpeechSystemAudioEffect()
        effect.tearDownKeepIntent = true
        if activeRecoveryID != 0 {
            recoverySeq += 1
            activeRecoveryID = 0
            effect.cancelRecovery = true
        }
        return effect
    }

    private mutating func scheduleIfReady() -> SpeechSystemAudioEffect {
        guard recoveryPending, !isBlocked, activeRecoveryID == 0 else {
            return SpeechSystemAudioEffect()
        }
        recoverySeq += 1
        activeRecoveryID = recoverySeq
        var effect = SpeechSystemAudioEffect()
        effect.tearDownKeepIntent = true
        effect.scheduleRecoveryID = activeRecoveryID
        return effect
    }
}

/// Observer tokens live off MainActor so deinit can remove them (Swift 6-safe).
private final class AudioSessionObserverRegistration: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    func removeAll() {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { removeAll() }
}

// MARK: - Callback snapshot (Sendable value types only)

struct RecognitionCallbackSnapshot: Sendable {
    /// Fixed suffix bound — covers the 16-word rolling tail with margin.
    /// All MainActor work must stay O(this), never O(total session segments).
    static let maxCapturedSegments = 32

    var segments: [SpeechSegmentSnapshot]
    /// Unbounded count before suffix clipping (metadata only).
    var totalSegmentCount: Int
    var isFinal: Bool
    var errorDomain: String?
    var errorCode: Int?
    var errorDescription: String?
    var receivedAt: TimeInterval

    static func capture(
        result: SFSpeechRecognitionResult?,
        error: (any Error)?,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> RecognitionCallbackSnapshot {
        let segments: [SpeechSegmentSnapshot]
        let totalCount: Int
        if let transcription = result?.bestTranscription {
            let all = transcription.segments
            totalCount = all.count
            // Bound copy cost: only the trailing window needed for the rolling tail.
            let window = all.suffix(maxCapturedSegments)
            segments = window.map {
                SpeechSegmentSnapshot(
                    substring: $0.substring,
                    timestamp: $0.timestamp,
                    duration: $0.duration,
                    confidence: $0.confidence
                )
            }
        } else {
            segments = []
            totalCount = 0
        }
        let nsError = error as NSError?
        return RecognitionCallbackSnapshot(
            segments: segments,
            totalSegmentCount: totalCount,
            isFinal: result?.isFinal ?? false,
            errorDomain: nsError?.domain,
            errorCode: nsError.map(\.code),
            errorDescription: error?.localizedDescription,
            receivedAt: now
        )
    }

    /// Pure clip for tests — same bound as live capture.
    static func clipSegments(_ segments: [SpeechSegmentSnapshot]) -> [SpeechSegmentSnapshot] {
        segments.count > maxCapturedSegments
            ? Array(segments.suffix(maxCapturedSegments))
            : segments
    }
}

// MARK: - Service

@MainActor
@Observable
final class SpeechRecognitionService {
    enum Status: Equatable {
        case idle
        case requestingPermission
        case starting
        case listening
        case unavailable(String)
        case denied

        var label: String {
            switch self {
            case .idle: "Paused"
            case .requestingPermission: "Requesting access"
            case .starting: "Starting"
            case .listening: "Listening"
            case .unavailable: "Unavailable"
            case .denied: "Voice access blocked"
            }
        }

        var shouldStopReaderPlayback: Bool {
            switch self {
            case .unavailable, .denied: true
            case .idle, .requestingPermission, .starting, .listening: false
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var health: SpeechPipelineHealth = .inactive
    private(set) var transcript = ""
    private(set) var usesOnDeviceRecognition = false
    /// Explicit startup phase (permissions + system-audio prerequisite + engine).
    private(set) var startupPhase: SpeechStartupPhase = .idle
    #if DEBUG
    /// Privacy-safe pipeline counters (no transcript/script text). DEBUG harness only.
    private(set) var diagnostics = VoicePipelineDiagnostics()
    #endif

    /// Replaced after invalidating system-audio recovery — prior graphs can retain stale taps.
    private var audioEngine = AVAudioEngine()
    private let speechPermissionRequester: PermissionRequester<SFSpeechRecognizerAuthorizationStatus>
    private let microphonePermissionRequester: PermissionRequester<Bool>
    private let speechAuthorizationStatusProvider: @Sendable () -> SFSpeechRecognizerAuthorizationStatus
    private let microphonePermissionStatusProvider: @Sendable () -> AVAudioApplication.recordPermission
    /// Last permission-gate failure for trust copy / Settings affordance.
    private(set) var lastPermissionFailure: VoicePermissionFailure?
    /// Cancels only the active start's permission waiter. The underlying TCC
    /// request remains alive so a replacement start can join the same flight.
    private var permissionWaitCancel: (@Sendable () -> Void)?
    /// Identity of the active permission wait; stale waits must not clear a newer canceler.
    private var permissionWaitToken: UUID?
    /// System permission prompts are not cancellable. Keep each real request alive
    /// across stop/replacement and fan its one result out to the current generation.
    private var microphonePermissionFlight: PermissionSingleFlight<Bool>?
    private var speechPermissionFlight: PermissionSingleFlight<SFSpeechRecognizerAuthorizationStatus>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var transcriptHandler: ((String) -> Void)?
    private var eventHandler: ((SpeechPipelineEvent) -> Void)?
    private var lastEmittedEvent: SpeechPipelineEvent?
    private var restartTask: Task<Void, Never>?
    private var silenceWatchTask: Task<Void, Never>?
    /// System-audio recovery only — never shares speech-failure restart budgets.
    private var audioRecoveryTask: Task<Void, Never>?
    private var systemAudioGate = SpeechSystemAudioGate()
    private var startup = SpeechStartupCoordinator()
    /// Bumped on user stop / new start — invalidates in-flight permission + restarts.
    private var generation = 0
    /// Monotonic SFSpeech task token; bumped per beginRecognition and on teardown/stop.
    private var recognitionToken = 0
    private var wantsRecognition = false
    private var tapInstalled = false
    /// Count of activation/setup begins for the current user start (bounded `!pri` retries).
    private var activationAttemptCount = 0
    private var activeLanguage = "en-US"
    private var contextHints: [String] = []
    private var normalizer = SpeechRollingTailNormalizer()
    private var governor = SpeechRestartGovernor()
    private var sessionFinished = false
    private let audioSessionObservers = AudioSessionObserverRegistration()
    #if DEBUG
    private let tapDiagnostics = VoiceTapDiagnosticsSink()
    private var diagnosticsFlushTask: Task<Void, Never>?
    #endif

    init(
        speechPermissionRequester: @escaping PermissionRequester<SFSpeechRecognizerAuthorizationStatus> = { resume in
            SFSpeechRecognizer.requestAuthorization(resume)
        },
        microphonePermissionRequester: @escaping PermissionRequester<Bool> = { resume in
            AVAudioApplication.requestRecordPermission(completionHandler: resume)
        },
        speechAuthorizationStatusProvider: @escaping @Sendable () -> SFSpeechRecognizerAuthorizationStatus = {
            SFSpeechRecognizer.authorizationStatus()
        },
        microphonePermissionStatusProvider: @escaping @Sendable () -> AVAudioApplication.recordPermission = {
            AVAudioApplication.shared.recordPermission
        }
    ) {
        self.speechPermissionRequester = speechPermissionRequester
        self.microphonePermissionRequester = microphonePermissionRequester
        self.speechAuthorizationStatusProvider = speechAuthorizationStatusProvider
        self.microphonePermissionStatusProvider = microphonePermissionStatusProvider
        installAudioSessionObservers()
    }

    /// Compatibility wrapper for ReaderView — no script hints, transcript-only callback.
    func start(language: String, onTranscript: @escaping (String) -> Void) async {
        await start(language: language, scriptText: nil, onTranscript: onTranscript, onEvent: nil)
    }

    /// Lane C–ready entry: optional script contextual strings + full pipeline events.
    func start(
        language: String,
        scriptText: String?,
        onEvent: @escaping (SpeechPipelineEvent) -> Void
    ) async {
        await start(language: language, scriptText: scriptText, onTranscript: nil, onEvent: onEvent)
    }

    private func start(
        language: String,
        scriptText: String?,
        onTranscript: ((String) -> Void)?,
        onEvent: ((SpeechPipelineEvent) -> Void)?
    ) async {
        // Always stop first: bumps generation and detaches the prior generation's
        // permission waiter. A non-cancellable system prompt remains single-flight,
        // so this replacement joins it rather than asking TCC a second time.
        stop()
        let run = generation
        wantsRecognition = true
        lastPermissionFailure = nil
        transcriptHandler = onTranscript
        eventHandler = onEvent
        lastEmittedEvent = nil
        transcript = ""
        usesOnDeviceRecognition = false
        activeLanguage = language
        contextHints = scriptText.map(SpeechContextHints.make(from:)) ?? []
        normalizer = SpeechRollingTailNormalizer()
        governor = SpeechRestartGovernor()
        activationAttemptCount = 0
        startup.beginStart()
        publishStartupPhase()
        #if DEBUG
        diagnostics.resetForNewSession()
        tapDiagnostics.reset()
        #endif
        setStatus(.requestingPermission, health: .starting)

        // 1) Microphone first (deterministic order; never prompt speech before mic).
        if let failure = await resolveMicrophonePermission(run: run) {
            finishPermissionFailure(failure)
            return
        }
        guard run == generation, wantsRecognition else { return }
        startup.markMicrophonePermissionGranted()
        publishStartupPhase()

        // 2) Speech recognition second — only after mic is authorized.
        if let failure = await resolveSpeechPermission(run: run) {
            finishPermissionFailure(failure)
            return
        }
        guard run == generation, wantsRecognition else { return }
        startup.markSpeechPermissionGranted()
        // Reflect any system-audio block that arrived during permission awaits.
        startup.setSystemAudioBlocked(systemAudioGate.isBlocked)
        publishStartupPhase()
        #if DEBUG
        diagnostics.permissionOK = true
        publishDiagnostics()
        #endif

        // permissionsReady: only begin when system-audio prerequisite is clear.
        if startup.canBeginEngine {
            beginRecognition(run: run)
        } else {
            setStatus(.starting, health: .recovering)
        }
    }

    func stop() {
        generation += 1
        // Unblock this generation's permission await promptly. This deliberately
        // does not cancel/forget the real system prompt, which TCC cannot cancel.
        cancelInFlightPermissionWait()
        invalidateRecognitionToken()
        wantsRecognition = false
        activationAttemptCount = 0
        cancelSpeechLifecycleTasks()
        applySystemAudioEffect(systemAudioGate.reset(), allowLiveRecovery: false)
        startup.reset()
        publishStartupPhase()
        teardownSession(cancelTask: true)
        normalizer.flush()
        governor = SpeechRestartGovernor()
        transcript = ""
        // Emit inactive before clearing handlers so event clients see the transition.
        setStatus(.idle, health: .inactive)
        clearHandlers()
        lastEmittedEvent = nil
        #if DEBUG
        publishDiagnostics(persist: true)
        #endif
    }

    /// Test seam: inject system-audio events without NotificationCenter.
    func applySystemAudioForTests(_ event: AudioSessionSystemEvent) {
        applySystemAudio(event)
    }

    #if DEBUG
    /// Reader alignment glue — indices/flags only (never text).
    func noteAlignmentObservation(
        accepted: Bool,
        committedTokenIndex: Int,
        candidateIndex: Int,
        confidence: Double,
        provisionalIndex: Int?,
        strongStreak: Int
    ) {
        diagnostics.alignmentObservationCount += 1
        if accepted {
            diagnostics.acceptedCount += 1
            diagnostics.lastAcceptedCandidateIndex = max(0, candidateIndex)
            diagnostics.lastAcceptedConfidencePermille = max(
                0,
                min(1_000, Int((confidence * 1_000).rounded()))
            )
            diagnostics.lastAcceptedProvisionalIndex = provisionalIndex ?? -1
            diagnostics.lastAcceptedStrongStreak = max(0, strongStreak)
        }
        diagnostics.committedTokenIndex = max(0, committedTokenIndex)
        publishDiagnostics()
    }

    /// Test seam: whether a diagnostics flush task is currently armed.
    var hasPendingDiagnosticsFlushForTests: Bool {
        diagnosticsFlushTask != nil
    }

    /// Test seam: activation attempt counter for bounded `!pri` retries.
    var activationAttemptCountForTests: Int { activationAttemptCount }

    /// Test seam: whether a speech/activation restart task is pending.
    var hasPendingRestartTaskForTests: Bool { restartTask != nil }

    /// Test seam: arm a long-lived inert restartTask (no audio/session work) so
    /// central cancellation via `stop()` / `cancelSpeechLifecycleTasks()` is provable.
    func armPendingRestartTaskForTests() {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3_600))
            guard let self, !Task.isCancelled else { return }
            // Same ownership rule as production delayed retry: cancelled tasks never clear.
            self.restartTask = nil
        }
    }
    #endif

    private func beginRecognition(run: Int) {
        // System-audio prerequisite: never install engine while blocked.
        guard !systemAudioGate.isBlocked else {
            startup.setSystemAudioBlocked(true)
            publishStartupPhase()
            setStatus(.starting, health: .recovering)
            return
        }
        // No duplicate request/task/tap — recovery and speech restarts both enter here.
        guard SpeechCallbackGate.canBegin(
            wantsRecognition: wantsRecognition,
            run: run,
            generation: generation,
            hasRecognitionRequest: recognitionRequest != nil,
            hasRecognitionTask: recognitionTask != nil,
            tapInstalled: tapInstalled
        ) else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: activeLanguage)),
              recognizer.isAvailable else {
            #if DEBUG
            diagnostics.recognizerAvailable = false
            publishDiagnostics()
            #endif
            fail("Speech recognition is not available for this language right now.")
            return
        }
        #if DEBUG
        diagnostics.recognizerAvailable = true
        #endif

        if startup.phase == .permissionsReady || startup.phase == .startingEngine {
            startup.markEngineStarting()
            publishStartupPhase()
        }

        // New task token — stale callbacks from the prior SFSpeech task are rejected.
        recognitionToken += 1
        let token = recognitionToken
        sessionFinished = false
        activationAttemptCount += 1
        setStatus(.starting, health: health == .recovering ? .recovering : .starting)
        let now = Date.timeIntervalSinceReferenceDate
        governor.beginSession(at: now)
        normalizer.rotateTask()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if !contextHints.isEmpty {
            request.contextualStrings = contextHints
        }
        usesOnDeviceRecognition = request.requiresOnDeviceRecognition
        #if DEBUG
        diagnostics.onDeviceRequired = request.requiresOnDeviceRecognition
        #endif
        recognitionRequest = request

        do {
            let session = AVAudioSession.sharedInstance()
            // Never force a preferred mic/route over the user's current input.
            // Ducking is invalid with the record category (SDK); Bluetooth HFP only.
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            // Activate with no options; notify-others is for teardown deactivation only.
            try session.setActive(true)
            #if DEBUG
            diagnostics.inputPortClass = VoicePipelineDiagnostics.inputPortClass(
                from: session.currentRoute.inputs.first?.portType
            )
            #endif

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            // Zero rate *or* zero channels assert inside installTap on device.
            guard SpeechInputFormatGate.isValidForTap(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            ) else {
                fail("No microphone input is available.")
                return
            }
            #if DEBUG
            diagnostics.inputSampleRateBucket = VoicePipelineDiagnostics.sampleRateBucket(format.sampleRate)
            diagnostics.inputChannelCount = Int(format.channelCount)
            diagnostics.inputCommonFormat = VoicePipelineDiagnostics.commonFormatClass(format.commonFormat)
            diagnostics.inputInterleaved = format.isInterleaved
            #endif

            let tapRequest = AudioRequestReference(request: request)
            #if DEBUG
            let tapSink = tapDiagnostics
            let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
                let access = VoiceBufferEnergy.channelAccess(from: buffer)
                let bucket = VoiceBufferEnergy.rmsBucket(from: buffer, access: access)
                tapSink.noteBuffer(rmsBucket: bucket, channelAccess: access)
                tapRequest.request.append(buffer)
            }
            #else
            let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
                tapRequest.request.append(buffer)
            }
            #endif
            input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tapHandler)
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()

            let recognitionHandler: @Sendable (
                SFSpeechRecognitionResult?,
                (any Error)?
            ) -> Void = { [weak self] result, error in
                let snapshot = RecognitionCallbackSnapshot.capture(result: result, error: error)
                Task { @MainActor [weak self] in
                    self?.handleRecognition(snapshot, run: run, token: token)
                }
            }
            recognitionTask = recognizer.recognitionTask(with: request, resultHandler: recognitionHandler)

            // Engine + task live: Starting → Listening/silent (Release + DEBUG; no word wait).
            activationAttemptCount = 0
            startup.markEngineLive()
            publishStartupPhase()
            #if DEBUG
            diagnostics.engineStarted = audioEngine.isRunning
            #endif
            let ready = SpeechProductStatus.afterEngineReady()
            setStatus(ready.0, health: ready.1)
            #if DEBUG
            armDiagnosticsFlush(run: run, token: token)
            publishDiagnostics(persist: true)
            #endif
        } catch {
            let nsError = error as NSError
            #if DEBUG
            diagnostics.lastErrorDomain = nsError.domain
            diagnostics.lastErrorCode = nsError.code
            diagnostics.engineStarted = false
            publishDiagnostics(persist: true)
            #endif
            handleActivationFailure(nsError, run: run)
        }
    }

    /// Setup/activation failure: bounded `!pri` retry via `restartTask`, else terminal fail.
    private func handleActivationFailure(_ error: NSError, run: Int) {
        // Always drop partial request/task/tap/engine before retry or terminal fail.
        invalidateRecognitionToken()
        cancelSpeechLifecycleTasks()
        teardownSession(cancelTask: true)

        guard wantsRecognition, generation == run else { return }

        if SpeechActivationRecovery.isPriorityContention(domain: error.domain, code: error.code) {
            // Exhausted budget or not permission-ready → terminal mic-in-use.
            // (Blocked system audio is recovering, not terminal — see below.)
            guard SpeechActivationRecovery.canRetry(afterFailedAttempt: activationAttemptCount),
                  SpeechActivationRecovery.isPermissionsReady(startup.phase) else {
                fail(SpeechActivationRecovery.micInUseMessage)
                return
            }
            setStatus(.starting, health: .recovering)
            // Shared predicate for delayed scheduling. When system audio is blocked,
            // stay recovering and wait for pre-live unblock → beginRecognition
            // (no competing restartTask) rather than failing terminal.
            guard SpeechActivationRecovery.shouldScheduleRetry(
                domain: error.domain,
                code: error.code,
                failedAttempt: activationAttemptCount,
                wantsRecognition: wantsRecognition,
                generationMatches: generation == run,
                systemAudioBlocked: systemAudioGate.isBlocked,
                phase: startup.phase
            ),
            let delay = SpeechActivationRecovery.delayBeforeRetry(
                afterFailedAttempt: activationAttemptCount
            ) else {
                return
            }
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self else { return }
                // Cancelled ⇒ a newer owner may hold restartTask; never clear/clobber.
                guard !Task.isCancelled else { return }
                // Still current: release the slot before gate checks / begin.
                self.restartTask = nil
                guard self.wantsRecognition, self.generation == run,
                      !self.systemAudioGate.isBlocked,
                      SpeechActivationRecovery.isPermissionsReady(self.startup.phase)
                else { return }
                self.beginRecognition(run: run)
            }
            return
        }

        let reason = SpeechRestartGovernor.classifyError(
            domain: error.domain,
            code: error.code,
            message: "The microphone could not start. Tap Play to try again."
        )
        switch reason {
        case .terminalError(_, _, let message):
            fail(message)
        default:
            fail("The microphone could not start. Tap Play to try again.")
        }
    }

    private func handleRecognition(_ snapshot: RecognitionCallbackSnapshot, run: Int, token: Int) {
        guard SpeechCallbackGate.accepts(
            wantsRecognition: wantsRecognition,
            activeRun: generation,
            callbackRun: run,
            activeToken: recognitionToken,
            callbackToken: token
        ), !sessionFinished else { return }

        // Snapshot is already bounded to maxCapturedSegments — all work below is O(bound).
        assert(snapshot.segments.count <= RecognitionCallbackSnapshot.maxCapturedSegments)

        #if DEBUG
        mergeTapDiagnostics()
        diagnostics.recognitionCallbackCount += 1
        #endif

        let now = snapshot.receivedAt
        let hasWords = snapshot.segments.contains {
            $0.substring.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).contains { !$0.isEmpty }
        }

        if hasWords || snapshot.isFinal {
            governor.noteRecognition(segments: snapshot.segments, isFinal: snapshot.isFinal, at: now)
            let tail = normalizer.apply(
                segments: snapshot.segments,
                isFinal: snapshot.isFinal,
                at: now
            )
            if hasWords {
                #if DEBUG
                diagnostics.wordCallbackCount += 1
                #endif
                transcript = tail
                setStatus(.listening, health: .hearingSpeech)
                armSilenceWatch(run: run, token: token)
                publishTranscript(tail)
            } else if snapshot.isFinal {
                transcript = tail
                publishTranscript(tail)
            }
        }

        if let domain = snapshot.errorDomain, let code = snapshot.errorCode {
            #if DEBUG
            diagnostics.lastErrorDomain = domain
            diagnostics.lastErrorCode = code
            publishDiagnostics()
            #endif
            let reason = SpeechRestartGovernor.classifyError(
                domain: domain,
                code: code,
                message: snapshot.errorDescription ?? ""
            )
            finishSession(run: run, token: token, reason: reason, at: now)
        } else if snapshot.isFinal {
            #if DEBUG
            publishDiagnostics()
            #endif
            finishSession(run: run, token: token, reason: .healthyFinal, at: now)
        } else {
            #if DEBUG
            publishDiagnostics()
            #endif
        }
    }

    private func finishSession(
        run: Int,
        token: Int,
        reason: SpeechSessionEndReason,
        at now: TimeInterval
    ) {
        guard SpeechCallbackGate.accepts(
            wantsRecognition: wantsRecognition,
            activeRun: generation,
            callbackRun: run,
            activeToken: recognitionToken,
            callbackToken: token
        ), !sessionFinished else { return }
        sessionFinished = true
        teardownSession(cancelTask: false)

        let plan = governor.endSession(reason: reason, at: now)
        switch plan {
        case .terminal(let message):
            fail(message)
        case .restart(let delay):
            // No-competition with system recovery: token invalidation on system tear-down
            // rejects this session's callbacks; system block cancels restartTask.
            setStatus(.starting, health: .recovering)
            restartTask?.cancel()
            restartTask = Task { @MainActor [weak self] in
                if delay != .zero {
                    try? await Task.sleep(for: delay)
                }
                guard let self else { return }
                // Cancelled ⇒ a newer owner may hold restartTask; never clear/clobber.
                guard !Task.isCancelled else { return }
                self.restartTask = nil
                guard self.wantsRecognition, self.generation == run else { return }
                // beginRecognition bumps recognitionToken so stale handlers die.
                self.beginRecognition(run: run)
            }
        }
    }

    private func fail(_ message: String) {
        wantsRecognition = false
        activationAttemptCount = 0
        invalidateRecognitionToken()
        cancelSpeechLifecycleTasks()
        applySystemAudioEffect(systemAudioGate.reset(), allowLiveRecovery: false)
        startup.reset()
        publishStartupPhase()
        teardownSession(cancelTask: true)
        setStatus(.unavailable(message), health: .terminalFailure(message))
        publishTranscript(transcript)
        clearHandlers()
    }

    // MARK: - System audio interruption / route / media-services recovery

    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        // queue: nil — snapshot payload off the notification thread, then hop to MainActor.
        audioSessionObservers.add(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            // Missing/malformed type → nil → safe no-op.
            guard let event = AudioSessionSystemEvent.interruption(userInfo: note.userInfo) else { return }
            Task { @MainActor [weak self] in self?.applySystemAudio(event) }
        })
        audioSessionObservers.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            let event = AudioSessionSystemEvent.routeChange(userInfo: note.userInfo)
            Task { @MainActor [weak self] in self?.applySystemAudio(event) }
        })
        audioSessionObservers.add(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applySystemAudio(.mediaServicesLost) }
        })
        audioSessionObservers.add(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applySystemAudio(.mediaServicesReset) }
        })
    }

    private func applySystemAudio(_ event: AudioSessionSystemEvent) {
        // Pre-live (permission awaits / permissionsReady): track block without recovery tasks.
        let allowRecovery = startup.phase == .live
        let effect = systemAudioGate.handle(
            event,
            wantsRecognition: wantsRecognition,
            allowRecovery: allowRecovery
        )
        applySystemAudioEffect(effect, allowLiveRecovery: allowRecovery)
    }

    private func applySystemAudioEffect(
        _ effect: SpeechSystemAudioEffect,
        allowLiveRecovery: Bool
    ) {
        if effect.cancelRecovery {
            audioRecoveryTask?.cancel()
            audioRecoveryTask = nil
        }

        if startup.phase != .live {
            // Startup path: system-audio prerequisite only — no tear-down/recovery loop.
            startup.setSystemAudioBlocked(systemAudioGate.isBlocked)
            publishStartupPhase()
            if systemAudioGate.isBlocked {
                if startup.phase == .permissionsReady || startup.phase == .startingEngine {
                    setStatus(.starting, health: .recovering)
                }
            } else if wantsRecognition,
                      (startup.canBeginEngine || startup.phase == .startingEngine) {
                // Cancel delayed !pri activation retry so interruption-end cannot stack
                // a second begin with the pending restartTask.
                restartTask?.cancel()
                restartTask = nil
                beginRecognition(run: generation)
            }
            return
        }

        if effect.tearDownKeepIntent {
            invalidateRecognitionToken()
            cancelSpeechLifecycleTasks()
            teardownSession(cancelTask: true)
            // Media-services loss invalidates the graph; abandon the dead engine
            // immediately so a later stop/removeTap cannot hit a zombie node.
            if systemAudioGate.mediaServicesLost {
                replaceAudioEngine()
            }
            // Stay live-phase for recovery; product status shows recovering.
            setStatus(.starting, health: .recovering)
        }
        if allowLiveRecovery, let recoveryID = effect.scheduleRecoveryID {
            launchSystemAudioRecovery(id: recoveryID)
        }
    }

    private func launchSystemAudioRecovery(id: Int) {
        let run = generation
        audioRecoveryTask = Task { @MainActor [weak self] in
            // Settle briefly so nested interruption/route/reset notifications coalesce.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled,
                  self.wantsRecognition, self.generation == run,
                  self.systemAudioGate.takeRecoveryWork(id: id) != nil
            else { return }
            self.audioRecoveryTask = nil
            // Never reuse an AVAudioEngine after an invalidating interruption or
            // route change. On device, AVFAudio can retain a tap internally even
            // after removeTap reports success; installing the recovery tap on that
            // graph raises an Objective-C exception and aborts the app. A fresh
            // graph is cheap here and makes recovery deterministic for every event,
            // not only media-services resets.
            self.replaceAudioEngine()
            // Recovery re-enters begin after a live interruption; phase stays live.
            self.beginRecognition(run: run)
        }
    }

    private func replaceAudioEngine() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine = AVAudioEngine()
    }

    private func cancelSpeechLifecycleTasks() {
        restartTask?.cancel()
        restartTask = nil
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        #if DEBUG
        // Centrally cancel pending diagnostic flush so delayed writes cannot escape teardown.
        diagnosticsFlushTask?.cancel()
        diagnosticsFlushTask = nil
        #endif
    }

    private func publishStartupPhase() {
        startupPhase = startup.phase
    }

    private func armSilenceWatch(run: Int, token: Int) {
        silenceWatchTask?.cancel()
        silenceWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self,
                  SpeechCallbackGate.accepts(
                      wantsRecognition: self.wantsRecognition,
                      activeRun: self.generation,
                      callbackRun: run,
                      activeToken: self.recognitionToken,
                      callbackToken: token
                  ) else { return }
            if self.health == .hearingSpeech {
                self.setStatus(.listening, health: .silent)
            }
        }
    }

    private func setStatus(
        _ status: Status,
        health: SpeechPipelineHealth
    ) {
        self.status = status
        self.health = health
        #if DEBUG
        diagnostics.statusLabel = statusDiagnosticsLabel(status)
        diagnostics.healthLabel = healthDiagnosticsLabel(health)
        #endif
        // Lifecycle events for event clients (starting/recovering/terminal/inactive).
        // Never pushes empty strings through the legacy transcript callback.
        emitEventIfNeeded(tail: transcript)
    }

    private func publishTranscript(_ tail: String) {
        emitEventIfNeeded(tail: tail)
        if !tail.isEmpty {
            transcriptHandler?(tail)
        }
    }

    private func emitEventIfNeeded(tail: String) {
        guard let event = SpeechEventEmission.nextEvent(
            previous: lastEmittedEvent,
            tail: tail,
            health: health,
            status: status
        ) else { return }
        lastEmittedEvent = event
        eventHandler?(event)
    }

    private func clearHandlers() {
        transcriptHandler = nil
        eventHandler = nil
    }

    private func invalidateRecognitionToken() {
        recognitionToken += 1
        sessionFinished = true
    }

    private func teardownSession(cancelTask: Bool) {
        // Halt the audio graph *before* any request termination so the installTap
        // block cannot append buffers after cancel/endAudio (audio-thread race).
        // Production order: stop engine → remove tap → cancel task → end request.
        // Cancel aborts recognition; endAudio then closes the request audio stream.
        // (When cancelTask is false, cancel is skipped and endAudio finalizes.)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if DEBUG
    private func publishDiagnostics(persist: Bool = false) {
        mergeTapDiagnostics()
        if persist {
            VoicePipelineDiagnostics.persist(diagnostics)
        }
        // Touch diagnostics so @Observable clients re-read accessibility values.
        diagnostics = diagnostics
    }

    private func mergeTapDiagnostics() {
        let snap = tapDiagnostics.snapshot()
        diagnostics.tapBufferCount = snap.tapBufferCount
        diagnostics.nonSilentBufferCount = snap.nonSilentBufferCount
        diagnostics.peakRMSBucket = max(diagnostics.peakRMSBucket, snap.peakRMSBucket)
        diagnostics.floatChannelAccessAvailable = snap.floatChannelAccessAvailable
        diagnostics.int16ChannelAccessAvailable = snap.int16ChannelAccessAvailable
        diagnostics.unsupportedFormatBufferCount = snap.unsupportedFormatBufferCount
    }

    private func armDiagnosticsFlush(run: Int, token: Int) {
        diagnosticsFlushTask?.cancel()
        diagnosticsFlushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self,
                      SpeechCallbackGate.accepts(
                          wantsRecognition: self.wantsRecognition,
                          activeRun: self.generation,
                          callbackRun: run,
                          activeToken: self.recognitionToken,
                          callbackToken: token
                      ) else { return }
                self.publishDiagnostics(persist: true)
            }
        }
    }

    private func statusDiagnosticsLabel(_ status: Status) -> String {
        switch status {
        case .idle: "idle"
        case .requestingPermission: "requestingPermission"
        case .starting: "starting"
        case .listening: "listening"
        case .unavailable: "unavailable"
        case .denied: "denied"
        }
    }

    private func healthDiagnosticsLabel(_ health: SpeechPipelineHealth) -> String {
        switch health {
        case .inactive: "inactive"
        case .starting: "starting"
        case .hearingSpeech: "hearingSpeech"
        case .silent: "silent"
        case .recovering: "recovering"
        case .terminalFailure: "terminalFailure"
        }
    }
    #endif

    /// Mic first: inspect status; invoke the system API only while undetermined.
    /// Already denied/restricted fails with Settings recovery and no false re-prompt.
    /// Returns `nil` on success **or** when this generation was superseded (caller re-checks).
    private func resolveMicrophonePermission(run: Int) async -> VoicePermissionFailure? {
        let statusBefore = microphonePermissionStatusProvider()
        #if DEBUG
        diagnostics.micPermission = Self.micPermissionDiagnosticsLabel(statusBefore)
        #endif
        let decision = VoicePermissionGate.decision(forMicrophone: statusBefore)
        if decision == .proceed {
            microphonePermissionFlight = nil
            return nil
        }
        if decision == .restricted {
            microphonePermissionFlight = nil
            return .microphoneRestricted
        }
        // Denied is final until the user changes Privacy Settings.
        guard VoicePermissionGate.shouldInvokeSystemPrompt(for: decision) else {
            microphonePermissionFlight = nil
            return VoicePermissionGate.failure(forMicrophone: decision)
        }

        // Undetermined only: the @MainActor service performs the real request.
        let flight = microphonePermissionFlight ?? PermissionSingleFlight<Bool>()
        microphonePermissionFlight = flight
        guard let granted = await waitForPermissionRequest(
            microphonePermissionRequester,
            flight: flight
        ) else {
            // stop()/replacement detached this waiter — do not treat as denial.
            return nil
        }
        if flight.isResolved, microphonePermissionFlight === flight {
            microphonePermissionFlight = nil
        }
        // Superseded by stop()/newer start — never mutate state for a stale run.
        guard run == generation, wantsRecognition else { return nil }
        let statusAfter = microphonePermissionStatusProvider()
        #if DEBUG
        diagnostics.micPermission = Self.micPermissionDiagnosticsLabel(statusAfter)
        #endif
        // Re-read TCC so incomplete registration is not reported as user denial
        // (which would offer empty Open Settings recovery).
        return VoicePermissionGate.failureAfterMicrophonePrompt(
            granted: granted,
            statusAfter: statusAfter
        )
    }

    /// Speech second: inspect status; invoke the system API only for notDetermined.
    /// Denied/restricted never re-prompt. Returns `nil` on success or supersession.
    private func resolveSpeechPermission(run: Int) async -> VoicePermissionFailure? {
        let statusBefore = speechAuthorizationStatusProvider()
        #if DEBUG
        diagnostics.speechPermission = Self.speechPermissionDiagnosticsLabel(statusBefore)
        #endif
        let decision = VoicePermissionGate.decision(forSpeech: statusBefore)
        if decision == .proceed {
            speechPermissionFlight = nil
            return nil
        }
        if decision == .restricted {
            speechPermissionFlight = nil
            return .speechRestricted
        }
        guard VoicePermissionGate.shouldInvokeSystemPrompt(for: decision) else {
            speechPermissionFlight = nil
            return VoicePermissionGate.failure(forSpeech: decision)
        }

        let flight = speechPermissionFlight
            ?? PermissionSingleFlight<SFSpeechRecognizerAuthorizationStatus>()
        speechPermissionFlight = flight
        guard let status = await waitForPermissionRequest(
            speechPermissionRequester,
            flight: flight
        ) else {
            return nil
        }
        if flight.isResolved, speechPermissionFlight === flight {
            speechPermissionFlight = nil
        }
        guard run == generation, wantsRecognition else { return nil }
        #if DEBUG
        diagnostics.speechPermission = Self.speechPermissionDiagnosticsLabel(status)
        #endif
        return VoicePermissionGate.failureAfterSpeechPrompt(status: status)
    }

    /// Join one real system request, or return `nil` when stop detaches this waiter.
    /// Cancelling a waiter never cancels or forgets the shared request itself.
    private func waitForPermissionRequest<T: Sendable>(
        _ request: PermissionRequester<T>,
        flight: PermissionSingleFlight<T>
    ) async -> T? {
        let token = UUID()
        let result: T? = await withCheckedContinuation { continuation in
            permissionWaitToken = token
            permissionWaitCancel = { flight.cancel(waiter: token) }
            flight.join(waiter: token, request: request) { value in
                continuation.resume(returning: value)
            }
        }
        // A superseded wait must not wipe a replacement start's cancel registration.
        if permissionWaitToken == token {
            permissionWaitToken = nil
            permissionWaitCancel = nil
        }
        return result
    }

    private func cancelInFlightPermissionWait() {
        let cancel = permissionWaitCancel
        permissionWaitCancel = nil
        permissionWaitToken = nil
        cancel?()
    }

    private func finishPermissionFailure(_ failure: VoicePermissionFailure) {
        // `.cancelled` is reserved for policy/tests; live supersession returns nil above.
        if failure == .cancelled {
            return
        }
        wantsRecognition = false
        lastPermissionFailure = failure
        startup.reset()
        publishStartupPhase()
        #if DEBUG
        diagnostics.permissionOK = false
        diagnostics.permissionFailureCode = failure.diagnosticCode
        publishDiagnostics(persist: true)
        #endif
        let message = failure.userMessage
        setStatus(failure.readerStatus, health: .terminalFailure(message))
        clearHandlers()
    }

    #if DEBUG
    private static func micPermissionDiagnosticsLabel(
        _ permission: AVAudioApplication.recordPermission
    ) -> String {
        switch permission {
        case .undetermined: "undetermined"
        case .granted: "granted"
        case .denied: "denied"
        @unknown default: "unknown"
        }
    }

    private static func speechPermissionDiagnosticsLabel(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
    }
    #endif
}

/// Thread-safe broker for a system permission request that cannot be cancelled.
/// Each start owns a detachable waiter; all waiters share one requester invocation.
private final class PermissionSingleFlight<Value: Sendable>: @unchecked Sendable {
    typealias Completion = @Sendable (Value?) -> Void

    private let lock = NSLock()
    private var requestStarted = false
    private var resolvedValue: Value?
    private var resolved = false
    private var waiters: [UUID: Completion] = [:]

    var isResolved: Bool {
        lock.withLock { resolved }
    }

    func join(
        waiter id: UUID,
        request: PermissionRequester<Value>,
        completion: @escaping Completion
    ) {
        var immediateValue: Value?
        var completeImmediately = false
        let shouldRequest = lock.withLock {
            if resolved {
                immediateValue = resolvedValue
                completeImmediately = true
                return false
            }
            waiters[id] = completion
            guard !requestStarted else { return false }
            requestStarted = true
            return true
        }

        if completeImmediately {
            completion(immediateValue)
        }
        if shouldRequest {
            request { [self] value in
                resolve(value)
            }
        }
    }

    func cancel(waiter id: UUID) {
        let completion = lock.withLock { waiters.removeValue(forKey: id) }
        completion?(nil)
    }

    private func resolve(_ value: Value) {
        let completions: [Completion] = lock.withLock {
            guard !resolved else { return [] }
            resolved = true
            resolvedValue = value
            let current = Array(waiters.values)
            waiters.removeAll()
            return current
        }
        for completion in completions {
            completion(value)
        }
    }
}

private struct AudioRequestReference: Sendable {
    // AVAudioEngine owns this block and calls it off MainActor. Speech's audio
    // request is designed to receive buffers there, but its SDK type is not Sendable.
    nonisolated(unsafe) let request: SFSpeechAudioBufferRecognitionRequest
}

typealias PermissionRequester<T: Sendable> =
    @Sendable (@escaping @Sendable (T) -> Void) -> Void

enum PermissionResultBridge {
    /// Resumes exactly once even if the system permission API double-fires.
    nonisolated static func once<T: Sendable>(
        _ request: PermissionRequester<T>
    ) async -> T {
        await withCheckedContinuation { continuation in
            let gate = PermissionContinuationGate()
            request { value in
                gate.resumeOnce {
                    continuation.resume(returning: value)
                }
            }
        }
    }
}

/// Thread-safe one-shot gate for system permission callbacks that may double-fire.
private final class PermissionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        let shouldResume = !resumed
        if shouldResume { resumed = true }
        lock.unlock()
        guard shouldResume else { return }
        body()
    }
}
