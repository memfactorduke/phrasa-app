import SwiftUI
import UIKit
import PhrasaCore

enum ReaderSettingsPersistencePolicy {
    static func shouldFlush(for scenePhase: ScenePhase) -> Bool {
        scenePhase != .active
    }
}

enum ReaderPlaybackLifecyclePolicy {
    static func shouldPause(
        for scenePhase: ScenePhase,
        speechStatus: SpeechRecognitionService.Status
    ) -> Bool {
        switch scenePhase {
        case .active:
            false
        case .background:
            true
        case .inactive:
            speechStatus != .requestingPermission
        @unknown default:
            true
        }
    }
}

/// Matches ReaderView's PrompterTextView hit-testing modifier.
/// Normal stage allows UITextView scrubbing; blackout must not.
enum ReaderStageInteractionPolicy {
    static func prompterAllowsHitTesting(isBlackout: Bool) -> Bool {
        !isBlackout
    }
}

/// Blackout freezes elapsed timing and prompter motion without a pause bookmark.
/// Logically playing stays true so reveal resumes without pre-roll.
enum ReaderBlackoutPlaybackPolicy {
    /// Display-link / auto-scroll motion. False while blacked out even if playing.
    static func prompterIsEffectivelyPlaying(
        isPlaying: Bool,
        preRollActive: Bool,
        isBlackout: Bool
    ) -> Bool {
        isPlaying && !preRollActive && !isBlackout
    }

    static func shouldRememberResumeOnBlackoutEntry(isPlaying: Bool) -> Bool {
        isPlaying
    }

    static func shouldResumeOnReveal(
        resumeRemembered: Bool,
        isLogicallyPlaying: Bool
    ) -> Bool {
        resumeRemembered && isLogicallyPlaying
    }

    /// Fold the active interval into banked elapsed; clear `startedAt` (freeze).
    static func freezeElapsed(
        elapsedBeforeStart: TimeInterval,
        startedAt: Date?,
        at freezeAt: Date
    ) -> (elapsedBeforeStart: TimeInterval, startedAt: Date?) {
        if let startedAt {
            return (
                elapsedBeforeStart + max(0, freezeAt.timeIntervalSince(startedAt)),
                nil
            )
        }
        return (elapsedBeforeStart, nil)
    }

    static func resumeElapsed(
        elapsedBeforeStart: TimeInterval,
        at resumeAt: Date
    ) -> (elapsedBeforeStart: TimeInterval, startedAt: Date?) {
        (elapsedBeforeStart, resumeAt)
    }

    static func activeElapsed(
        elapsedBeforeStart: TimeInterval,
        startedAt: Date?,
        now: Date
    ) -> TimeInterval {
        elapsedBeforeStart + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

/// Keyboard and remote command mapping for the reader stage.
enum ReaderCommand: Equatable, Sendable {
    case playPause
    case blackout
    case slower
    case faster
    case nudgeBackward
    case nudgeForward
    case stepBackward
    case stepForward
    case exit
    case shortcutsHelp
    case useSpeed

    /// Maps SwiftUI key equivalents and character input without requiring a live KeyPress.
    static func resolve(key: KeyEquivalent?, characters: String) -> ReaderCommand? {
        if let key {
            switch key {
            case .space: return .playPause
            case .upArrow: return .slower
            case .downArrow: return .faster
            case .leftArrow: return .nudgeBackward
            case .rightArrow: return .nudgeForward
            case .pageUp: return .stepBackward
            case .pageDown: return .stepForward
            case .escape: return .exit
            default: break
            }
        }
        switch characters.lowercased() {
        case "b": return .blackout
        case "?": return .shortcutsHelp
        default: return nil
        }
    }

    static func fromKeyPress(_ keyPress: KeyPress) -> ReaderCommand? {
        resolve(key: keyPress.key, characters: keyPress.characters)
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryStore.self) private var library
    let script: ScriptDocument

    @State private var settings = ReaderSettings()
    @State private var isPlaying = false
    @State private var progress = 0.0
    @State private var overlay = ReaderOverlayState()
    @State private var showingSettings = false
    @State private var showingShortcuts = false
    @State private var startedAt: Date?
    @State private var elapsedBeforeStart: TimeInterval = 0
    @State private var preRoll: Int?
    @State private var preRollTask: Task<Void, Never>?
    @State private var speech = SpeechRecognitionService()
    @State private var alignment: AlignmentEngine?
    @State private var visiblePosition = VisiblePositionController()
    @State private var voiceFocusTokenIndex = 0
    @State private var lastMissStreak = 0
    @State private var tokenCount = 0
    @State private var finalMatchableTokenIndex: Int?
    @State private var sessionStore = ReaderSessionStore()
    @State private var sessionMutationQueue = ReaderSessionMutationQueue()
    @State private var sessionTracker: ReaderSessionTracker?
    @State private var sessionIsReady = false
    @State private var pendingBookmark: ReaderBookmark?
    @State private var completionRecap: ReaderCompletionRecap?
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var lastVoiceAcceptanceAt: Date?
    @State private var voiceRecentlyAccepted = false
    /// True when blackout interrupted an active run; reveal resumes without pre-roll.
    @State private var resumeAfterBlackout = false
    @State private var completionDwellTask: Task<Void, Never>?
    @State private var completionDwellStartedAt: Date?
    /// Last nonempty normalized tail fed to alignment (dedup health-only events).
    @State private var lastAlignedNonemptyTail: String?
    /// Last successful spoken paragraph navigation (cooldown gate).
    @State private var lastSpokenNavigationAt: Date?
    @FocusState private var stageFocused: Bool

    private var chromeForeground: Color {
        settings.theme.foreground
    }

    private var voiceTrust: VoiceTrustPresentation {
        VoiceTrustPresentation.resolve(
            status: speech.status,
            health: speech.health,
            isPlaying: isPlaying && settings.mode == .voice,
            recentlyAccepted: voiceRecentlyAccepted,
            secondsSinceAcceptance: lastVoiceAcceptanceAt.map { Date.now.timeIntervalSince($0) } ?? 100,
            missStreak: lastMissStreak,
            hasProvisional: visiblePosition.provisionalIndex != nil,
            permissionFailure: speech.lastPermissionFailure
        )
    }

    private var showChrome: Bool {
        overlay.controlsVisible && !overlay.isBlackout
    }

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()

            // Bottom chrome participates in layout so the prompter's bounds are the
            // readable stage only. A full-bleed text overlay under controls left
            // live script (and large Dynamic Type) continuing behind the panel.
            // Hidden chrome removes the reservation → full stage for performance.
            VStack(spacing: 0) {
                ZStack {
                    PrompterTextView(
                        text: script.body,
                        settings: settings,
                        isPlaying: ReaderBlackoutPlaybackPolicy.prompterIsEffectivelyPlaying(
                            isPlaying: isPlaying,
                            preRollActive: preRoll != nil,
                            isBlackout: overlay.isBlackout
                        ),
                        progress: $progress,
                        voiceTargetTokenIndex: settings.mode == .voice ? voiceFocusTokenIndex : nil,
                        reduceMotion: reduceMotion,
                        onScrubEndedNearToken: settings.mode == .voice
                            ? { token in reseatVoice(to: token) }
                            : nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Stage taps reveal chrome; controls live outside this view,
                    // so tapping Play/Settings cannot also fire the stage gesture.
                    .simultaneousGesture(TapGesture().onEnded { handleStageTap() })
                    .allowsHitTesting(
                        ReaderStageInteractionPolicy.prompterAllowsHitTesting(
                            isBlackout: overlay.isBlackout
                        )
                    )

                    focusBand

                    if showChrome {
                        VStack(spacing: 0) {
                            topChrome
                            Spacer(minLength: 0)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showChrome {
                    bottomChrome
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()

            if overlay.isBlackout {
                Color.black.ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 10) {
                            Text("Blackout")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.9))
                            Text("Tap or press B to return")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Blackout. Tap or press B to return")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { reduceOverlay(.toggleBlackout) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Return to reader") {
                        reduceOverlay(.toggleBlackout)
                    }
                    .contentShape(Rectangle())
                    .transition(.opacity)
            }
            if let preRoll {
                Text("\(preRoll)")
                    .font(.system(size: 96, weight: .semibold, design: .default))
                    .foregroundStyle(chromeForeground)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    .accessibilityLabel("Starting in \(preRoll)")
            }
            #if DEBUG
            // Always-present privacy-safe diagnostic surface (not under chrome auto-hide).
            // Physical harnesses poll this instead of volatile ProgressIndicator.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier(VoicePipelineDiagnostics.accessibilityIdentifier)
                .accessibilityLabel(VoicePipelineDiagnostics.accessibilityIdentifier)
                .accessibilityValue(speech.diagnostics.accessibilityValue)
                .accessibilityElement(children: .ignore)
                .allowsHitTesting(false)
            #endif
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($stageFocused)
        .onKeyPress { keyPress in
            guard let command = ReaderCommand.fromKeyPress(keyPress) else { return .ignored }
            handleCommand(command)
            return .handled
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear { stageFocused = true }
        .sheet(isPresented: $showingSettings) {
            ReaderSettingsView(settings: $settings)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingShortcuts) {
            ReaderShortcutsSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $completionRecap) { recap in
            ReaderCompletionView(
                recap: recap,
                onReadAgain: restart,
                onDone: { dismiss() }
            )
        }
        .confirmationDialog(
            "Continue where you left off?",
            isPresented: Binding(
                get: { pendingBookmark != nil },
                set: { if !$0 { pendingBookmark = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Continue") { resumeSavedSession() }
            Button("Start from the beginning") { startFreshSession() }
        } message: {
            Text("Phrasa saved your position on this device.")
        }
        .interactiveDismissDisabled(true)
        .task {
            sessionIsReady = false
            settings = library.settings
            let tokens = ReaderTokenizer.tokenize(script.body)
            tokenCount = tokens.count
            finalMatchableTokenIndex = VoiceFollowBinding.finalMatchableTokenIndex(in: tokens)
            alignment = AlignmentEngine(tokens: tokens)
            visiblePosition = VisiblePositionController(committedIndex: 0)
            voiceFocusTokenIndex = 0
            sessionTracker = ReaderSessionTracker(scriptID: script.id, body: script.body)
            UIApplication.shared.isIdleTimerDisabled = true
            let bookmark: ReaderBookmark?
            do {
                // Prefer domain-aware eligibility (title+body signature + context).
                if let domainMatch = try await sessionStore.bookmark(for: script) {
                    bookmark = domainMatch
                } else {
                    bookmark = try await sessionStore.bookmark(
                        for: script.id,
                        matchingBody: script.body
                    )
                }
            } catch {
                bookmark = nil
                library.report(error)
            }
            guard !Task.isCancelled else { return }
            pendingBookmark = bookmark
            sessionIsReady = true
            await library.markOpened(script.id)
        }
        .onDisappear {
            stop()
            overlayHideTask?.cancel()
            completionDwellTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await library.saveSettings(settings) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Returning from Settings must reveal the recovery controls, but
                // it must never start playback without an explicit user action.
                revealVoicePermissionRecoveryAfterForeground()
            }
            guard ReaderSettingsPersistencePolicy.shouldFlush(for: phase) else { return }
            if ReaderPlaybackLifecyclePolicy.shouldPause(
                for: phase,
                speechStatus: speech.status
            ) {
                pause()
                reduceOverlay(.appBecameInactive)
            }
            let settingsToSave = settings
            Task { await library.saveSettings(settingsToSave) }
        }
        .onChange(of: progress) { _, value in
            let token = settings.mode == .voice
                ? voiceFocusTokenIndex
                : VoiceFollowBinding.tokenIndex(progress: value, tokenCount: tokenCount)
            sessionTracker?.update(progress: value, focusTokenIndex: token)
            // Speed completes on ratio; voice uses final-token dwell.
            if settings.mode == .speed, value >= 0.999, completionRecap == nil {
                completeSession()
            }
        }
        .onChange(of: settings.mode) { _, _ in
            if isPlaying || preRoll != nil { pause() }
            // Reseat voice engines from current progress when entering voice.
            if settings.mode == .voice {
                let token = VoiceFollowBinding.tokenIndex(progress: progress, tokenCount: tokenCount)
                reseatVoice(to: token)
            }
        }
        .onChange(of: settings.recognitionLanguage) { _, _ in
            // Live language switch: restart speech only; preserve committed cursor.
            guard settings.mode == .voice, isPlaying, preRoll == nil,
                  !overlay.isBlackout else { return }
            startSpeechRecognition(preservingCursor: true)
        }
        .onChange(of: speech.status) { _, status in
            // Keep chrome visible while the system permission sheet may be up,
            // and after terminal blocks so Settings / Speed remain tappable.
            switch status {
            case .requestingPermission, .denied, .unavailable:
                keepVoiceChromeVisible()
            default:
                break
            }
            guard settings.mode == .voice, isPlaying,
                  status.shouldStopReaderPlayback else { return }
            UIAccessibility.post(notification: .announcement, argument: status.label)
            pause(preserveSpeechFailure: true)
        }
        .onChange(of: overlay.isBlackout) { wasBlackout, isBlackout in
            handleBlackoutChange(wasBlackout: wasBlackout, isBlackout: isBlackout)
        }
    }

    private var focusBand: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(chromeForeground.opacity(settings.mode == .voice && voiceTrust == .searching ? 0.35 : 0.85))
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(chromeForeground)
                        .frame(width: 6, height: 6)
                        .offset(x: 12)
                        .opacity(voiceTrust.showsSearchingPulse ? 0.45 : 1)
                }
                .position(
                    x: proxy.size.width / 2,
                    y: PrompterGeometry.visibleFocusY(
                        height: proxy.size.height,
                        focusPosition: settings.focusPosition,
                        mirrorVertical: settings.mirrorVertical
                    )
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(PhrasaDesign.motion(reduceMotion: reduceMotion), value: voiceTrust)
        }
    }

    /// Top-of-stage controls — thin overlay above the focus band, not a text obstruction.
    private var topChrome: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .phrasaTouchTarget()
            }
            .accessibilityLabel("Exit prompter")
            Spacer()
            if settings.showPacing {
                PacingPill(
                    elapsedBeforeStart: elapsedBeforeStart,
                    startedAt: startedAt,
                    target: settings.targetDuration ?? script.estimatedDuration,
                    progress: progress,
                    foreground: chromeForeground
                )
            }
            Spacer()
            HStack(spacing: 4) {
                Button { reduceOverlay(.toggleBlackout) } label: {
                    Image(systemName: "rectangle.fill")
                        .phrasaTouchTarget()
                }
                .accessibilityLabel("Black out screen")
                .accessibilityHint("Press B on a keyboard")
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .phrasaTouchTarget()
                }
                .accessibilityLabel("Reader settings")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .foregroundStyle(chromeForeground)
    }

    /// Bottom control panel — laid out *below* the prompter stage (not over it).
    private var bottomChrome: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .tint(chromeForeground)
                .accessibilityIdentifier(PhrasaA11y.Reader.progress)
                .accessibilityLabel("Script progress")
                .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(1))))

            Picker("Reader mode", selection: $settings.mode) {
                ForEach(ReaderMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(PhrasaA11y.Reader.mode)

            HStack(spacing: 10) {
                Button { restart() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 30, height: 30)
                }
                .phrasaTouchTarget()
                .accessibilityLabel("Restart from top")
                .disabled(!canInteractWithSession)

                if settings.mode == .speed {
                    Spacer(minLength: 0)
                    Button { adjustSpeed(by: -10) } label: {
                        Image(systemName: "minus").frame(width: 30, height: 30)
                    }
                    .phrasaTouchTarget()
                    .accessibilityLabel("Slower")
                    Text("\(Int(settings.speedWPM)) wpm")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 70)
                        .accessibilityLabel("\(Int(settings.speedWPM)) words per minute")
                    Button { adjustSpeed(by: 10) } label: {
                        Image(systemName: "plus").frame(width: 30, height: 30)
                    }
                    .phrasaTouchTarget()
                    .accessibilityLabel("Faster")
                    Spacer(minLength: 0)
                } else {
                    voiceStatusPanel
                }

                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(chromeForeground)
                .foregroundStyle(settings.theme.background)
                .accessibilityIdentifier(PhrasaA11y.Reader.playPause)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .disabled(!canInteractWithSession)
            }
            .controlSize(.large)
        }
        .padding(14)
        .background(
            PhrasaDesign.elevated,
            in: RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
                .stroke(PhrasaDesign.border, lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(settings.theme.background)
        .foregroundStyle(chromeForeground)
    }

    private var voiceStatusPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if voiceTrust.showsSearchingPulse {
                    Circle()
                        .stroke(chromeForeground.opacity(0.7), lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: voiceTrust == .tracking ? "dot.radiowaves.left.and.right" : "mic")
                        .font(.caption.weight(.semibold))
                }
                Text(voiceTrust.label)
                    .font(.caption.weight(.semibold))
            }
            if let detail = voiceTrust.actionableDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(chromeForeground.opacity(0.72))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if voiceTrust.offersOpenSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                if case .denied = voiceTrust {
                    Button("Try again") {
                        retryVoicePermissionAfterUserAction()
                    }
                    .font(.caption.weight(.semibold))
                } else if case .unavailable = voiceTrust {
                    Button("Try again") {
                        retryVoicePermissionAfterUserAction()
                    }
                    .font(.caption.weight(.semibold))
                }
                if voiceTrust.offersUseSpeed {
                    Button("Use Speed") {
                        handleCommand(.useSpeed)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Recovery actions must remain separate, focusable VoiceOver elements.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(PhrasaA11y.Reader.voiceStatus)
        .accessibilityLabel(voiceTrust.label)
        .accessibilityValue(
            VoiceTrustPresentation.accessibilityDiagnosticValue(
                permissionFailure: speech.lastPermissionFailure,
                status: speech.status
            )
        )
    }

    private var canInteractWithSession: Bool {
        ReaderSessionInteractionGate.allowsPlayback(
            sessionIsReady: sessionIsReady,
            hasTracker: sessionTracker != nil
        )
    }

    private func handleCommand(_ command: ReaderCommand) {
        switch command {
        case .playPause:
            togglePlay()
        case .blackout:
            reduceOverlay(.toggleBlackout)
        case .slower:
            adjustSpeed(by: -10)
            bumpChrome()
        case .faster:
            adjustSpeed(by: 10)
            bumpChrome()
        case .nudgeBackward:
            nudge(by: -0.012)
        case .nudgeForward:
            nudge(by: 0.012)
        case .stepBackward:
            // Page Up / remote previous: one line-scale step (larger than arrow nudge).
            nudge(by: -0.04)
        case .stepForward:
            // Page Down / remote next: one line-scale step (larger than arrow nudge).
            nudge(by: 0.04)
        case .exit:
            if showingSettings {
                showingSettings = false
            } else if showingShortcuts {
                showingShortcuts = false
            } else if overlay.isBlackout {
                reduceOverlay(.toggleBlackout)
            } else {
                dismiss()
            }
        case .shortcutsHelp:
            showingShortcuts = true
            bumpChrome()
        case .useSpeed:
            settings.mode = .speed
            if isPlaying { pause() }
            bumpChrome()
        }
    }

    private func adjustSpeed(by delta: Double) {
        settings.speedWPM = (settings.speedWPM + delta).clamped(to: 40...400)
    }

    private func nudge(by delta: Double) {
        if settings.mode == .voice {
            let step = VoiceFollowBinding.tokenDelta(forProgressDelta: delta)
            reseatVoice(to: voiceFocusTokenIndex + step)
        } else {
            progress = (progress + delta).clamped(to: 0...1)
        }
        bumpChrome()
    }

    private func bumpChrome() {
        if !overlay.controlsVisible {
            reduceOverlay(.stageTapped)
        } else if isPlaying {
            reduceOverlay(.playbackStarted)
        }
    }

    private func togglePlay() {
        guard canInteractWithSession else { return }
        if isPlaying || preRoll != nil { pause(); return }
        if SpeedModeStartPolicy.shouldBeginWithCountdown(
            mode: settings.mode,
            progress: progress,
            countdown: settings.speedCountdown
        ) {
            startPreRoll()
        } else {
            play()
        }
    }

    private func play() {
        isPlaying = true
        startedAt = .now
        sessionTracker?.start(at: .now)
        reduceOverlay(.playbackStarted)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if settings.mode == .voice {
            lastVoiceAcceptanceAt = .now
            voiceRecentlyAccepted = false
            lastMissStreak = 0
            // Seed engines at the current committed cursor before ASR starts.
            let seed = voiceFocusTokenIndex > 0
                ? voiceFocusTokenIndex
                : VoiceFollowBinding.tokenIndex(progress: progress, tokenCount: tokenCount)
            reseatVoice(to: seed)
            startSpeechRecognition(preservingCursor: true)
        }
    }

    /// Starts (or restarts) speech.
    /// - `preservingCursor`: keep committed display token, clear provisional, reseat
    ///   AlignmentEngine at that token (language switch / blackout reveal).
    private func startSpeechRecognition(preservingCursor: Bool) {
        // New recognition stream — allow the first real tail through again.
        lastAlignedNonemptyTail = nil
        if preservingCursor {
            let committed = visiblePosition.committedIndex
            let kept = VoiceFollowBinding.prepareLanguageRestart(
                committedIndex: committed,
                controller: &visiblePosition
            )
            alignment?.reset(tokenIndex: kept)
            voiceFocusTokenIndex = kept
        } else {
            let seed = VoiceFollowBinding.tokenIndex(progress: progress, tokenCount: tokenCount)
            alignment?.reset(tokenIndex: seed)
            visiblePosition.reset(committedIndex: seed)
            voiceFocusTokenIndex = seed
        }
        Task {
            await speech.start(
                language: settings.recognitionLanguage,
                scriptText: script.body
            ) { event in
                handleSpeechEvent(event)
            }
        }
    }

    private func handleSpeechEvent(_ event: SpeechPipelineEvent) {
        guard settings.mode == .voice, isPlaying, !overlay.isBlackout else { return }

        // Health/status changes with empty or unchanged tails are not alignment observations.
        // Presentation still tracks SpeechRecognitionService via @Observable status/health.
        guard VoiceFollowBinding.shouldProcessAlignmentTail(
            tail: event.tail,
            lastAlignedNonemptyTail: lastAlignedNonemptyTail
        ) else { return }

        guard let key = VoiceFollowBinding.alignmentTailKey(event.tail) else { return }
        lastAlignedNonemptyTail = key

        // Bounded recognition tail only — never an unbounded cumulative transcript.
        let words = ReaderTokenizer.normalizeUtterance(event.tail)

        // Spoken paragraph navigation (prefix-gated) runs before alignment so
        // command words never advance the match cursor.
        if let intent = SpokenNavigationCommand.match(normalizedWords: words) {
            handleSpokenNavigation(intent)
            return
        }

        guard let engine = alignment else { return }
        let result = engine.observe(words)

        // Only ACCEPTED results may propose to VisiblePositionController.
        // Rejected still update miss/trust and clear stale provisional without advancing.
        let snapshot = VoiceFollowBinding.applyAlignmentObservation(
            accepted: result.accepted,
            candidateIndex: result.tokenIndex,
            confidence: result.confidence,
            reanchored: result.reanchored,
            allowInitialAcquisition: voiceFocusTokenIndex == 0
                && visiblePosition.committedIndex == 0,
            controller: &visiblePosition
        )
        lastMissStreak = result.missStreak
        if result.accepted {
            lastVoiceAcceptanceAt = .now
            voiceRecentlyAccepted = true
        }
        #if DEBUG
        // Privacy-safe counters only (indices/flags — never transcript or script text).
        speech.noteAlignmentObservation(
            accepted: result.accepted,
            committedTokenIndex: snapshot.visibleIndex,
            candidateIndex: result.tokenIndex,
            confidence: result.confidence,
            provisionalIndex: snapshot.provisionalIndex,
            strongStreak: snapshot.strongStreak
        )
        #endif

        // Publish ONLY committed visible index to the prompter.
        applyVoiceVisibleIndex(snapshot.visibleIndex)
    }

    /// Prefix-gated paragraph jumps. Reseats both engines; respects cooldown.
    private func handleSpokenNavigation(_ intent: SpokenNavigationIntent) {
        let now = Date.now
        guard SpokenNavigationCommand.allowsCommand(
            lastFiredAt: lastSpokenNavigationAt,
            now: now
        ) else { return }

        let tokens = ReaderTokenizer.tokenize(script.body)
        guard let target = SpokenNavigationCommand.targetTokenIndex(
            intent: intent,
            tokens: tokens,
            currentIndex: voiceFocusTokenIndex
        ) else { return }

        lastSpokenNavigationAt = now
        reseatVoice(to: target)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func applyVoiceVisibleIndex(_ index: Int) {
        let clamped = tokenCount > 0 ? max(0, min(index, tokenCount - 1)) : 0
        voiceFocusTokenIndex = clamped
        progress = VoiceFollowBinding.progress(tokenIndex: clamped, tokenCount: tokenCount)
        armCompletionDwellIfNeeded()
    }

    /// Manual arrows, completed scrubs: reseat BOTH engines so later ASR cannot snap back.
    private func reseatVoice(to tokenIndex: Int) {
        let visible = VoiceFollowBinding.manualReseat(
            to: tokenIndex,
            tokenCount: tokenCount,
            controller: &visiblePosition
        )
        alignment?.reset(tokenIndex: visible)
        voiceFocusTokenIndex = visible
        progress = VoiceFollowBinding.progress(tokenIndex: visible, tokenCount: tokenCount)
        cancelCompletionDwell()
        armCompletionDwellIfNeeded()
    }

    private func armCompletionDwellIfNeeded() {
        guard settings.mode == .voice,
              completionRecap == nil,
              VoiceFollowBinding.shouldAllowCompletionDwell(
                isPlaying: isPlaying,
                isBlackout: overlay.isBlackout
              ),
              VoiceFollowBinding.shouldArmCompletionDwell(
                visibleIndex: voiceFocusTokenIndex,
                finalMatchableTokenIndex: finalMatchableTokenIndex
              ) else {
            completionDwellStartedAt = nil
            completionDwellTask?.cancel()
            completionDwellTask = nil
            return
        }
        if completionDwellStartedAt != nil { return }
        completionDwellStartedAt = .now
        completionDwellTask?.cancel()
        completionDwellTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(VoiceFollowBinding.completionDwellSeconds))
            guard !Task.isCancelled else { return }
            guard completionRecap == nil,
                  VoiceFollowBinding.shouldAllowCompletionDwell(
                    isPlaying: isPlaying,
                    isBlackout: overlay.isBlackout
                  ),
                  VoiceFollowBinding.shouldCompleteAfterDwell(
                    dwellStartedAt: completionDwellStartedAt,
                    now: .now
                  ),
                  VoiceFollowBinding.shouldArmCompletionDwell(
                    visibleIndex: voiceFocusTokenIndex,
                    finalMatchableTokenIndex: finalMatchableTokenIndex
                  ) else { return }
            completeSession()
        }
    }

    /// Blackout freezes elapsed timing + tracker (no pause bookmark), stops voice
    /// speech, cancels completion dwell, and freezes prompter motion for both modes.
    /// Logically playing stays true so reveal resumes without a second pre-roll.
    private func handleBlackoutChange(wasBlackout: Bool, isBlackout: Bool) {
        if isBlackout && !wasBlackout {
            cancelCompletionDwell()
            if ReaderBlackoutPlaybackPolicy.shouldRememberResumeOnBlackoutEntry(
                isPlaying: isPlaying
            ) {
                resumeAfterBlackout = true
                freezeActiveTimingForBlackout()
                if settings.mode == .voice {
                    speech.stop()
                }
            } else {
                resumeAfterBlackout = false
            }
        } else if !isBlackout && wasBlackout {
            if ReaderBlackoutPlaybackPolicy.shouldResumeOnReveal(
                resumeRemembered: resumeAfterBlackout,
                isLogicallyPlaying: isPlaying
            ) {
                resumeAfterBlackout = false
                resumeActiveTimingAfterBlackout()
                if settings.mode == .voice {
                    startSpeechRecognition(preservingCursor: true)
                }
                armCompletionDwellIfNeeded()
            } else {
                resumeAfterBlackout = false
            }
        }
    }

    /// Bank elapsed and stop tracker clock without persisting a pause bookmark.
    private func freezeActiveTimingForBlackout() {
        let now = Date.now
        let frozen = ReaderBlackoutPlaybackPolicy.freezeElapsed(
            elapsedBeforeStart: elapsedBeforeStart,
            startedAt: startedAt,
            at: now
        )
        elapsedBeforeStart = frozen.elapsedBeforeStart
        startedAt = frozen.startedAt

        if var tracker = sessionTracker, tracker.isActive {
            let token = settings.mode == .voice
                ? voiceFocusTokenIndex
                : VoiceFollowBinding.tokenIndex(progress: progress, tokenCount: tokenCount)
            tracker.update(progress: progress, focusTokenIndex: token)
            // pause() freezes activeSince into elapsedActiveTime; do not persist.
            _ = tracker.pause(at: now, focusTokenIndex: token)
            sessionTracker = tracker
            elapsedBeforeStart = tracker.elapsedActiveTime
        }
    }

    private func resumeActiveTimingAfterBlackout() {
        let now = Date.now
        let resumed = ReaderBlackoutPlaybackPolicy.resumeElapsed(
            elapsedBeforeStart: elapsedBeforeStart,
            at: now
        )
        elapsedBeforeStart = resumed.elapsedBeforeStart
        startedAt = resumed.startedAt
        // New active run count is acceptable if the tracker API has no freeze seam.
        if var tracker = sessionTracker {
            tracker.start(at: now)
            sessionTracker = tracker
        }
    }

    private func cancelCompletionDwell() {
        completionDwellTask?.cancel()
        completionDwellTask = nil
        completionDwellStartedAt = nil
    }

    private func pause(preserveSpeechFailure: Bool = false) {
        preRollTask?.cancel()
        preRollTask = nil
        preRoll = nil
        cancelCompletionDwell()
        let now = Date.now
        if let startedAt { elapsedBeforeStart += now.timeIntervalSince(startedAt) }
        startedAt = nil
        isPlaying = false
        resumeAfterBlackout = false
        if !preserveSpeechFailure { speech.stop() }
        reduceOverlay(.playbackPaused)
        if completionRecap == nil, var tracker = sessionTracker {
            let token = settings.mode == .voice
                ? voiceFocusTokenIndex
                : VoiceFollowBinding.tokenIndex(progress: progress, tokenCount: tokenCount)
            tracker.update(progress: progress, focusTokenIndex: token)
            let shouldPersist = ReaderBookmarkPersistencePolicy
                .shouldSaveAfterPause(tracker)
            let bookmark = tracker.pause(
                at: now,
                script: script,
                mode: settings.mode,
                speedWPM: settings.speedWPM,
                focusTokenIndex: token
            )
            sessionTracker = tracker
            elapsedBeforeStart = bookmark.elapsedActiveTime
            if shouldPersist {
                sessionMutationQueue.enqueue {
                    do { try await sessionStore.save(bookmark: bookmark) }
                    catch { library.report(error) }
                }
            }
        }
    }

    private func stop() { pause() }

    private func restart() {
        guard canInteractWithSession else { return }
        pause()
        progress = 0
        elapsedBeforeStart = 0
        alignment?.reset()
        visiblePosition.reset(committedIndex: 0)
        voiceFocusTokenIndex = 0
        lastMissStreak = 0
        completionRecap = nil
        voiceRecentlyAccepted = false
        lastVoiceAcceptanceAt = nil
        lastAlignedNonemptyTail = nil
        completionDwellStartedAt = nil
        sessionTracker = ReaderSessionTracker(scriptID: script.id, body: script.body)
        sessionMutationQueue.enqueue {
            do { try await sessionStore.clearBookmark(for: script.id) }
            catch { library.report(error) }
        }
    }

    private func startPreRoll() {
        let sequence = settings.speedCountdown.displaySequence
        guard !sequence.isEmpty else {
            play()
            return
        }
        preRollTask?.cancel()
        preRollTask = Task { @MainActor in
            for number in sequence {
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    preRoll = number
                } else {
                    withAnimation(PhrasaDesign.motion) { preRoll = number }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            preRoll = nil
            guard settings.mode == .speed,
                  progress < SpeedModeStartPolicy.nearStartThreshold else { return }
            play()
        }
    }

    private func resumeSavedSession() {
        guard let bookmark = pendingBookmark else { return }
        pendingBookmark = nil
        let domain = bookmark.domainResume(for: script)
        // Restore effective mode and speed from domain resume context.
        if let mode = domain.mode {
            settings.mode = mode
        }
        if let speedWPM = domain.speedWPM {
            settings.speedWPM = speedWPM
        }
        settings.normalize()
        let tracker = ReaderSessionTracker(scriptID: script.id, body: script.body, bookmark: bookmark)
        sessionTracker = tracker
        let resumeProgress = domain.effectiveSpeedProgress(tokenCount: tokenCount)
        progress = resumeProgress > 0 ? resumeProgress : tracker.progress
        let focusToken = domain.focusTokenIndex > 0
            ? domain.focusTokenIndex
            : VoiceFollowBinding.tokenIndex(progress: progress, tokenCount: tokenCount)
        if settings.mode == .voice {
            reseatVoice(to: focusToken)
        } else if focusToken > 0 {
            alignment?.reset(tokenIndex: focusToken)
            visiblePosition.reset(committedIndex: focusToken)
            voiceFocusTokenIndex = focusToken
        }
        elapsedBeforeStart = tracker.elapsedActiveTime
    }

    private func startFreshSession() {
        pendingBookmark = nil
        restart()
    }

    private func completeSession() {
        preRollTask?.cancel()
        preRollTask = nil
        preRoll = nil
        cancelCompletionDwell()
        speech.stop()
        isPlaying = false
        startedAt = nil
        resumeAfterBlackout = false
        reduceOverlay(.playbackPaused)
        guard var tracker = sessionTracker else { return }
        tracker.update(progress: 1, focusTokenIndex: max(0, tokenCount - 1))
        let recap = tracker.complete(
            at: .now,
            targetDuration: settings.targetDuration ?? script.estimatedDuration
        )
        sessionTracker = tracker
        elapsedBeforeStart = recap.activeTime
        completionRecap = recap
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        sessionMutationQueue.enqueue {
            do { try await sessionStore.save(recap: recap) }
            catch { library.report(error) }
        }
    }

    private func handleStageTap() {
        reduceOverlay(.stageTapped)
    }

    /// Permission prompts and terminal voice failures must never leave an empty stage.
    private func keepVoiceChromeVisible() {
        overlay.controlsVisible = true
        overlay.hideControlsAt = nil
        overlayHideTask?.cancel()
        overlayHideTask = nil
    }

    /// Returning from Settings keeps the trust/recovery surface visible without
    /// converting an app lifecycle event into an unsolicited playback start.
    private func revealVoicePermissionRecoveryAfterForeground() {
        guard settings.mode == .voice else { return }
        switch speech.status {
        case .denied, .unavailable:
            keepVoiceChromeVisible()
        default:
            break
        }
    }

    /// An explicit Try again action may restart the permission/playback gate.
    private func retryVoicePermissionAfterUserAction() {
        guard settings.mode == .voice, canInteractWithSession else { return }
        switch speech.status {
        case .denied, .unavailable:
            keepVoiceChromeVisible()
            if !isPlaying, preRoll == nil {
                play()
            } else {
                startSpeechRecognition(preservingCursor: true)
            }
        default:
            break
        }
    }

    private func reduceOverlay(_ event: ReaderOverlayEvent) {
        PhrasaMotion.withAnimationIfAllowed(reduceMotion: reduceMotion) {
            ReaderOverlayReducer.reduce(&overlay, event: event, now: .now)
        }
        scheduleOverlayHide()
    }

    private func scheduleOverlayHide() {
        overlayHideTask?.cancel()
        guard let deadline = overlay.hideControlsAt else { return }
        overlayHideTask = Task { @MainActor in
            let delay = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            reduceOverlay(.timerFired)
        }
    }
}

enum ReaderPacingClock {
    static func elapsed(
        elapsedBeforeStart: TimeInterval,
        startedAt: Date?,
        now: Date
    ) -> TimeInterval {
        elapsedBeforeStart + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

private struct PacingPill: View {
    let elapsedBeforeStart: TimeInterval
    let startedAt: Date?
    let target: TimeInterval
    let progress: Double
    let foreground: Color

    private func label(elapsed: TimeInterval) -> String {
        let expected = target > 0 ? elapsed / target : 0
        if progress > expected + 0.04 { return "Ahead" }
        if progress + 0.04 < expected { return "Behind" }
        return "On pace"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = ReaderPacingClock.elapsed(
                elapsedBeforeStart: elapsedBeforeStart,
                startedAt: startedAt,
                now: context.date
            )
            let pace = label(elapsed: elapsed)
            HStack(spacing: 7) {
                Text(elapsed.compactDuration)
                Text(pace)
                    .foregroundStyle(foreground.opacity(pace == "On pace" ? 1 : 0.75))
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PhrasaDesign.elevated.opacity(0.92), in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                    .stroke(PhrasaDesign.border, lineWidth: 1)
            }
        }
    }
}

private struct ReaderShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(String, String)] = [
        ("Space", "Play or pause"),
        ("B", "Blackout"),
        ("↑ / ↓", "Slower / faster by 10 WPM"),
        ("← / →", "Nudge a step"),
        ("PgUp / PgDn", "Larger step back / forward"),
        ("Esc", "Close sheet or exit"),
        ("?", "This shortcuts list")
    ]

    /// Voice-follow spoken commands — always require the “phrasa” prefix.
    private let voiceRows: [(String, String)] = [
        ("phrasa previous paragraph", "Jump to the previous paragraph"),
        ("phrasa next paragraph", "Jump to the next paragraph"),
        ("phrasa current paragraph", "Restart the current paragraph"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Keyboard") {
                    ForEach(rows, id: \.0) { key, action in
                        shortcutRow(key: key, action: action, keyWidth: 90)
                    }
                }
                Section {
                    ForEach(voiceRows, id: \.0) { key, action in
                        shortcutRow(key: key, action: action, keyWidth: 168)
                    }
                } header: {
                    Text("Voice (while following)")
                } footer: {
                    Text(
                        "Say the full phrase including “phrasa”. Also accepted: last/prior/go back/back paragraph; following/forward paragraph; this/restart/repeat paragraph. Ordinary script text without the prefix never triggers a jump."
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(PhrasaDesign.canvas)
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func shortcutRow(key: String, action: String, keyWidth: CGFloat) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(PhrasaDesign.ink)
                .frame(width: keyWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(action)
                .foregroundStyle(PhrasaDesign.muted)
            Spacer(minLength: 0)
        }
        .listRowBackground(PhrasaDesign.elevated)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(action)")
    }
}
