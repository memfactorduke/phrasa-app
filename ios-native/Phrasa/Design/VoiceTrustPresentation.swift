import Foundation
import os
import PhrasaCore

/// Maps speech service status + pipeline health + recent acceptance into restrained
/// reader trust copy. Actionable problems get explicit labels; tracking stays quiet.
///
/// Quiet pauses (silence / inactive listening) must read as **Listening**, never
/// false **Finding place**. Searching is reserved for sustained miss / provisional
/// re-lock while the pipeline is still actively hearing or recovering.
enum VoiceTrustPresentation: Equatable, Sendable {
    case idle
    case requestingPermission
    case starting
    case listening
    case tracking
    case searching
    /// Permission/system block with concrete copy and optional Settings action.
    case denied(message: String, offersOpenSettings: Bool)
    case unavailable(String)

    /// Default denial when no gate detail is available.
    static let defaultDeniedMessage =
        "Allow microphone and speech recognition in Settings, or use Speed mode."

    var label: String {
        switch self {
        case .idle: "Voice paused"
        case .requestingPermission: "Requesting access"
        case .starting: "Starting"
        case .listening: "Listening"
        case .tracking: "Following"
        case .searching: "Finding place"
        case .denied: "Voice access blocked"
        case .unavailable: "Unavailable"
        }
    }

    /// Permanent meter is forbidden; pulse only while searching.
    var showsSearchingPulse: Bool {
        if case .searching = self { return true }
        return false
    }

    /// Detail appears only for recoverable / actionable failures.
    var actionableDetail: String? {
        switch self {
        case .denied(let message, _):
            return message
        case .unavailable(let message):
            return message
        default:
            return nil
        }
    }

    var offersOpenSettings: Bool {
        if case .denied(_, let offers) = self { return offers }
        return false
    }

    var offersUseSpeed: Bool {
        switch self {
        case .denied, .unavailable: true
        default: false
        }
    }

    /// Non-sensitive token for physical QA and accessibility automation.
    static func accessibilityDiagnosticValue(
        permissionFailure: VoicePermissionFailure?,
        status: SpeechRecognitionService.Status
    ) -> String {
        if let permissionFailure {
            return permissionFailure.diagnosticCode
        }
        switch status {
        case .denied: return "denied"
        case .unavailable: return "unavailable"
        case .idle: return "idle"
        case .requestingPermission: return "requestingPermission"
        case .starting: return "starting"
        case .listening: return "listening"
        }
    }

    /// Compatibility entry used by older call sites (status + acceptance only).
    static func resolve(
        status: SpeechRecognitionService.Status,
        isPlaying: Bool,
        recentlyAccepted: Bool,
        secondsSinceAcceptance: TimeInterval
    ) -> VoiceTrustPresentation {
        resolve(
            status: status,
            health: defaultHealth(for: status),
            isPlaying: isPlaying,
            recentlyAccepted: recentlyAccepted,
            secondsSinceAcceptance: secondsSinceAcceptance,
            missStreak: 0,
            hasProvisional: false,
            permissionFailure: nil
        )
    }

    /// Lane C presentation: speech health + alignment miss / provisional state.
    static func resolve(
        status: SpeechRecognitionService.Status,
        health: SpeechPipelineHealth,
        isPlaying: Bool,
        recentlyAccepted: Bool,
        secondsSinceAcceptance: TimeInterval,
        missStreak: Int,
        hasProvisional: Bool,
        permissionFailure: VoicePermissionFailure? = nil
    ) -> VoiceTrustPresentation {
        switch status {
        case .idle:
            return .idle
        case .requestingPermission:
            return .requestingPermission
        case .starting:
            return .starting
        case .denied:
            if let permissionFailure {
                return .denied(
                    message: permissionFailure.userMessage,
                    offersOpenSettings: permissionFailure.offersOpenSettings
                )
            }
            if case .terminalFailure(let message) = health, !message.isEmpty {
                return .denied(message: message, offersOpenSettings: true)
            }
            return .denied(message: defaultDeniedMessage, offersOpenSettings: true)
        case .unavailable(let message):
            return .unavailable(message)
        case .listening:
            guard isPlaying else { return .listening }

            // Terminal / recovery health still surface via status when failed;
            // recovering without a hard status stays "Starting".
            if case .recovering = health {
                return missStreak >= 3 || hasProvisional ? .searching : .starting
            }
            if case .terminalFailure = health {
                // Status should already be unavailable; keep listening path calm.
                return .listening
            }

            // Quiet pause: silence or inactive — never "Finding place".
            if health == .silent || health == .inactive {
                return recentlyAccepted && secondsSinceAcceptance < trackingWindow
                    ? .tracking
                    : .listening
            }

            // Actively hearing speech.
            if recentlyAccepted && secondsSinceAcceptance < trackingWindow {
                return .tracking
            }

            // Searching only when alignment is struggling, not on ordinary pauses.
            if shouldSearch(
                missStreak: missStreak,
                hasProvisional: hasProvisional,
                secondsSinceAcceptance: secondsSinceAcceptance,
                health: health
            ) {
                return .searching
            }

            return .listening
        }
    }

    /// Sustained miss / provisional far candidate while the mic is still live.
    static func shouldSearch(
        missStreak: Int,
        hasProvisional: Bool,
        secondsSinceAcceptance: TimeInterval,
        health: SpeechPipelineHealth
    ) -> Bool {
        // Never search purely on wall-clock silence.
        if health == .silent || health == .inactive { return false }

        if hasProvisional && missStreak >= 1 { return true }
        if missStreak >= 3 { return true }
        // Hearing speech but no acceptance for a while and elevated miss streak.
        if health == .hearingSpeech,
           missStreak >= 2,
           secondsSinceAcceptance > searchAfterSeconds {
            return true
        }
        return false
    }

    static let trackingWindow: TimeInterval = 1.8
    static let searchAfterSeconds: TimeInterval = 2.4

    private static func defaultHealth(
        for status: SpeechRecognitionService.Status
    ) -> SpeechPipelineHealth {
        switch status {
        case .idle: .inactive
        case .requestingPermission, .starting: .starting
        case .listening: .hearingSpeech
        case .denied:
            // Prefer actionable Settings copy over the short status label.
            .terminalFailure(defaultDeniedMessage)
        case .unavailable(let message):
            .terminalFailure(message)
        }
    }
}

// MARK: - Pure voice follow binding (testable; no Speech I/O)

/// Deterministic glue between AlignmentEngine results, VisiblePositionController,
/// and reader progress. ReaderView owns the live instances; tests exercise this.
enum VoiceFollowBinding: Sendable {
    /// Privacy-safe alignment log: indices/flags only (never transcript or script text).
    private static let voiceFollowLogger = Logger(
        subsystem: "com.phrasa.app",
        category: "VoiceFollow"
    )

    static let completionDwellSeconds: TimeInterval = 1.2
    /// Arrow nudge ≈ one display token; page step ≈ a few tokens.
    static let nudgeTokenStep = 1
    static let pageTokenStep = 4

    static func progress(tokenIndex: Int, tokenCount: Int) -> Double {
        guard tokenCount > 1 else { return 0 }
        let clamped = max(0, min(tokenIndex, tokenCount - 1))
        return Double(clamped) / Double(tokenCount - 1)
    }

    static func tokenIndex(progress: Double, tokenCount: Int) -> Int {
        guard tokenCount > 1 else { return 0 }
        let ratio = progress.clamped(to: 0...1)
        let index = Int((ratio * Double(tokenCount - 1)).rounded())
        return max(0, min(index, tokenCount - 1))
    }

    /// Normalized nonempty tail key for alignment dedup. Empty → nil (skip).
    static func alignmentTailKey(_ tail: String) -> String? {
        let words = ReaderTokenizer.normalizeUtterance(tail)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// Skip empty tails and unchanged duplicates so health-only events cannot
    /// re-drive alignment or refresh acceptance tracking.
    static func shouldProcessAlignmentTail(
        tail: String,
        lastAlignedNonemptyTail: String?
    ) -> Bool {
        guard let key = alignmentTailKey(tail) else { return false }
        if key == lastAlignedNonemptyTail { return false }
        return true
    }

    /// Feed an **accepted** candidate only. UI may only use the returned visible index.
    @discardableResult
    static func observeCandidate(
        candidateIndex: Int,
        confidence: Double,
        controller: inout VisiblePositionController
    ) -> VisiblePositionSnapshot {
        controller.observe(candidateIndex: candidateIndex, confidence: confidence)
    }

    /// Hold committed position and clear stale provisional without proposing a token.
    @discardableResult
    static func holdCommittedClearingProvisional(
        controller: inout VisiblePositionController
    ) -> VisiblePositionSnapshot {
        controller.observe(candidateIndex: controller.committedIndex, confidence: 1)
    }

    /// Only **accepted** alignment results may propose a candidate to the controller.
    /// Rejected results clear/hold provisional state and never advance via +1.
    /// Logs accepted/candidate/confidence/visible/reanchor (indices only) after the gate.
    @discardableResult
    static func applyAlignmentObservation(
        accepted: Bool,
        candidateIndex: Int,
        confidence: Double,
        reanchored: Bool = false,
        allowInitialAcquisition: Bool = false,
        controller: inout VisiblePositionController
    ) -> VisiblePositionSnapshot {
        let snapshot: VisiblePositionSnapshot
        if accepted {
            if allowInitialAcquisition,
               controller.committedIndex == 0,
               (1...16).contains(candidateIndex) {
                // The recognition tail is bounded to 16 words. An
                // AlignmentEngine-accepted opening match inside that same
                // bound is a safe initial lock, not an arbitrary far jump.
                snapshot = controller.manualReseat(to: candidateIndex)
            } else {
                snapshot = observeCandidate(
                    candidateIndex: candidateIndex,
                    confidence: confidence,
                    controller: &controller
                )
            }
        } else {
            snapshot = holdCommittedClearingProvisional(controller: &controller)
        }
        // privacy: .public so Console shows indices on device; fields are never user text.
        voiceFollowLogger.log(
            "align accepted=\(accepted, privacy: .public) candidate=\(candidateIndex, privacy: .public) conf=\(confidence, privacy: .public) visible=\(snapshot.visibleIndex, privacy: .public) reanchor=\(reanchored, privacy: .public)"
        )
        return snapshot
    }

    /// Manual arrows, completed scrubs: authoritative for both controller and caller.
    @discardableResult
    static func manualReseat(
        to tokenIndex: Int,
        tokenCount: Int,
        controller: inout VisiblePositionController
    ) -> Int {
        let clamped = tokenCount > 0
            ? max(0, min(tokenIndex, tokenCount - 1))
            : 0
        return controller.manualReseat(to: clamped).visibleIndex
    }

    /// Live language restart: keep committed display token, clear provisional /
    /// confirmation streak, and return the index AlignmentEngine should reseat to.
    @discardableResult
    static func prepareLanguageRestart(
        committedIndex: Int,
        controller: inout VisiblePositionController
    ) -> Int {
        let kept = max(0, committedIndex)
        controller.reset(committedIndex: kept)
        return controller.committedIndex
    }

    /// Language restart preserves committed cursor and leaves provisional cleared.
    static func cursorPreservedAfterLanguageRestart(
        committedBefore: Int,
        controller: VisiblePositionController
    ) -> Bool {
        controller.visibleIndex == committedBefore
            && controller.committedIndex == committedBefore
            && controller.provisionalIndex == nil
    }

    /// Last display token that carries matchable (non-empty normalized) text.
    static func finalMatchableTokenIndex(in tokens: [ReaderToken]) -> Int? {
        tokens.last(where: { !$0.normalized.isEmpty })?.index
    }

    static func shouldArmCompletionDwell(
        visibleIndex: Int,
        finalMatchableTokenIndex: Int?
    ) -> Bool {
        guard let final = finalMatchableTokenIndex else { return false }
        return visibleIndex >= final
    }

    /// Dwell must not fire while paused or blacked out.
    static func shouldAllowCompletionDwell(
        isPlaying: Bool,
        isBlackout: Bool
    ) -> Bool {
        isPlaying && !isBlackout
    }

    static func shouldCompleteAfterDwell(
        dwellStartedAt: Date?,
        now: Date,
        dwellSeconds: TimeInterval = completionDwellSeconds
    ) -> Bool {
        guard let start = dwellStartedAt else { return false }
        return now.timeIntervalSince(start) >= dwellSeconds
    }

    /// Token step for keyboard/remote nudges in voice mode.
    static func tokenDelta(forProgressDelta delta: Double) -> Int {
        if abs(delta) >= 0.03 {
            return delta < 0 ? -pageTokenStep : pageTokenStep
        }
        return delta < 0 ? -nudgeTokenStep : nudgeTokenStep
    }
}
