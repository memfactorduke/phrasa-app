import AppKit
import SwiftUI
import PhrasaDomain

/// Host for the dedicated reader window.
struct MacReaderWindowHost: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MacReaderRequestSnapshot?

    var body: some View {
        Group {
            if let request = appModel.readerRequest,
               let snapshot,
               snapshot.requestID == request.id {
                MacReaderView(script: snapshot.script) {
                    appModel.closeReader()
                    dismiss()
                }
                // The dedicated Window is reused. Force presentation/session
                // state to belong to exactly one script when its identity changes.
                .id(request.id)
            } else if appModel.readerRequest != nil {
                ProgressView("Opening reader…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MacDesign.canvas)
            } else {
                ContentUnavailableView(
                    "No Script",
                    systemImage: "play.rectangle",
                    description: Text("Select a script in the library and choose Present.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MacDesign.canvas)
                .onAppear {
                    // Close empty reader windows opened without a script.
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: appModel.readerRequest?.id) {
            guard let request = appModel.readerRequest,
                  let script = library.script(id: request.scriptID) else {
                snapshot = nil
                return
            }
            // Freeze content for this active run. Cloud/editor replacement of
            // the same row must not mutate tokenizer/session state mid-speech.
            snapshot = MacReaderRequestSnapshot(
                requestID: request.id,
                script: script
            )
        }
        .onDisappear {
            // Covers the window's red close button, not only Phrasa's own Exit.
            appModel.closeReader()
        }
    }
}

private struct MacReaderRequestSnapshot {
    let requestID: UUID
    let script: ScriptDocument
}

enum MacPacingPresentation {
    static func remainingLabel(
        wordCount: Int,
        progress: Double,
        speedWPM: Double
    ) -> String {
        let remaining = max(0, 1 - progress)
        let remainingWords = Double(wordCount) * remaining
        guard speedWPM > 0 else { return "" }
        let seconds = Int((remainingWords / speedWPM * 60).rounded())
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "~\(minutes)m \(remainder)s left" : "~\(remainder)s left"
    }
}

struct MacReaderView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let script: ScriptDocument
    let onClose: () -> Void

    @State private var appearance = MacReaderAppearanceState()
    @State private var session = MacPresentationSession()
    @State private var audience = MacAudienceOutputCoordinator()
    @State private var overlay = MacReaderOverlayState()
    @State private var showingShortcuts = false
    @State private var showingSettings = false
    @State private var sessionStore = MacReaderSessionStore()
    @State private var sessionTracker: MacReaderSessionTracker?
    @State private var sessionIsReady = false
    @State private var completionRecap: MacReaderCompletionRecap?
    @State private var sleepGuard = MacDisplaySleepGuard()
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var sessionError: String?
    @State private var didEnterFullScreen = false
    @FocusState private var stageFocused: Bool

    private var settings: ReaderSettings {
        appearance.settings
    }

    /// Bottom chrome participates in layout when visible so the prompter's
    /// bounds are the readable stage only (matches iOS ReaderView). Overlaying
    /// controls on a full-bleed text surface left live script under the panel.
    private var showChrome: Bool {
        overlay.controlsVisible && !(overlay.isBlackout || session.isBlackout)
    }

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    MacPrompterTextView(
                        text: script.body,
                        settings: settings,
                        progress: session.progress,
                        allowsScrubbing: true,
                        onProgressChange: { value in
                            session.setProgress(value)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(overlay.isBlackout || session.isBlackout ? 0 : 1)
                    .allowsHitTesting(!(overlay.isBlackout || session.isBlackout))
                    .accessibilityHidden(overlay.isBlackout || session.isBlackout)

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

            if overlay.isBlackout || session.isBlackout {
                Color.black.ignoresSafeArea()
                    .onTapGesture { handleCommand(.blackout) }
                    .accessibilityLabel("Blackout. Click or press B to reveal.")
                    .accessibilityAddTraits(.isButton)
            }

            if let preRoll = session.preRoll {
                Text("\(preRoll)")
                    .font(.system(size: 96, weight: .semibold, design: .rounded))
                    .foregroundStyle(settings.theme.foreground)
                    .transition(.opacity)
                    .accessibilityLabel("Starting in \(preRoll)")
            }

            if let recap = completionRecap {
                MacReaderRecapOverlay(recap: recap) {
                    completionRecap = nil
                    onClose()
                } onRestart: {
                    completionRecap = nil
                    session.setProgress(0)
                    sessionTracker = MacReaderSessionTracker(scriptID: script.id, body: script.body)
                    wireSessionCallbacks()
                }
            }
        }
        .focusable()
        .focused($stageFocused)
        .onKeyPress { keyPress in
            if keyPress.key == .upArrow {
                handleCommand(.slower)
                return .handled
            }
            if keyPress.key == .downArrow {
                handleCommand(.faster)
                return .handled
            }
            if keyPress.key == .leftArrow {
                handleCommand(.nudgeBackward)
                return .handled
            }
            if keyPress.key == .rightArrow {
                handleCommand(.nudgeForward)
                return .handled
            }
            if keyPress.key == .pageUp {
                handleCommand(.stepBackward)
                return .handled
            }
            if keyPress.key == .pageDown {
                handleCommand(.stepForward)
                return .handled
            }
            if keyPress.key == .escape {
                handleCommand(.exit)
                return .handled
            }
            if keyPress.key == .space {
                handleCommand(.playPause)
                return .handled
            }
            if let command = MacReaderCommand.resolve(characters: keyPress.characters) {
                handleCommand(command)
                return .handled
            }
            return .ignored
        }
        .onTapGesture {
            var next = overlay
            MacReaderOverlayReducer.reduce(&next, event: .stageTapped, now: .now)
            // Stage tap reveal should also clear session blackout.
            if session.isBlackout {
                session.exitBlackout()
                next.isBlackout = false
                next.controlsVisible = true
            }
            overlay = next
            scheduleOverlayHide()
        }
        .onChange(of: session.progress) { _, newValue in
            guard var tracker = sessionTracker else { return }
            tracker.update(progress: newValue)
            sessionTracker = tracker
        }
        .onChange(of: session.isPlaying) { _, playing in
            updateSleepGuard()
            var next = overlay
            MacReaderOverlayReducer.reduce(
                &next,
                event: playing ? .playbackStarted : .playbackPaused,
                now: .now
            )
            next.isBlackout = session.isBlackout
            overlay = next
            scheduleOverlayHide()
            if !playing, !session.isBlackout {
                persistBookmarkIfNeeded()
            }
        }
        .onChange(of: session.isBlackout) { _, blackout in
            var next = overlay
            next.isBlackout = blackout
            if blackout {
                next.controlsVisible = false
                next.isPlaying = false
            } else {
                next.controlsVisible = true
            }
            overlay = next
            // Suspend/resume tracker with blackout; never bookmark merely for blackout.
            syncSessionTrackerForBlackout(entered: blackout)
            updateSleepGuard()
        }
        .onChange(of: audience.hasVisibleAudienceOutput) { _, _ in
            updateSleepGuard()
        }
        .onChange(of: audience.isEnabled) { _, _ in
            updateSleepGuard()
        }
        .onAppear {
            var loaded = library.settings
            loaded.mode = .speed
            loaded.normalize()
            appearance.settings = loaded
            session.configure(
                scriptBody: script.body,
                speedWPM: loaded.speedWPM,
                speedCountdown: loaded.speedCountdown
            )
            wireSessionCallbacks()
            stageFocused = true
            Task { await prepareSession() }
        }
        .background {
            // Resolve the actual host NSWindow — never NSApp.keyWindow / windows scan.
            MacControllerWindowAccessor { window in
                guard let window else { return }
                audience.bindControllerWindow(window)
                if !didEnterFullScreen, !window.styleMask.contains(.fullScreen) {
                    didEnterFullScreen = true
                    window.toggleFullScreen(nil)
                }
            }
        }
        .onDisappear {
            teardownPresentation()
            Task { _ = await library.saveSettings(appearance.settings) }
        }
        .sheet(isPresented: $showingShortcuts) {
            MacShortcutsHelpView()
        }
        .sheet(isPresented: $showingSettings) {
            MacReaderSettingsSheet(settings: Binding(
                get: { appearance.settings },
                set: { newValue in
                    appearance.settings = newValue
                    session.speedWPM = newValue.speedWPM
                    session.speedCountdown = newValue.speedCountdown
                }
            ))
        }
        .alert(
            "Reader",
            isPresented: Binding(
                get: { sessionError != nil },
                set: { if !$0 { sessionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { sessionError = nil }
        } message: {
            Text(sessionError ?? "")
        }
    }

    private var topChrome: some View {
        HStack {
            Button {
                handleCommand(.exit)
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .help("Exit reader (Escape)")

            Spacer()

            Text(script.title)
                .font(.headline)
                .foregroundStyle(settings.theme.foreground)
                .lineLimit(1)

            Spacer()

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .help("Reader settings")

            Button {
                showingShortcuts = true
            } label: {
                Label("Shortcuts", systemImage: "questionmark.circle")
            }
            .help("Keyboard shortcuts")
        }
        .padding(16)
        .background(.black.opacity(0.55))
        .foregroundStyle(settings.theme.foreground)
    }

    private var bottomChrome: some View {
        VStack(spacing: 10) {
            ProgressView(value: session.progress)
                .tint(settings.theme.foreground)
                .accessibilityLabel("Reading progress")
                .accessibilityValue("\(Int(session.progress * 100)) percent")

            HStack(spacing: 20) {
                Button {
                    handleCommand(.slower)
                } label: {
                    Label("Slower", systemImage: "tortoise")
                }
                .help("Decrease speed by 10 WPM")

                Button {
                    handleCommand(.playPause)
                } label: {
                    Label(
                        session.isPlaying ? "Pause" : "Play",
                        systemImage: session.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .help("Play or pause (Space)")
                .disabled(!MacReaderSessionInteractionGate.allowsPlayback(
                    sessionIsReady: sessionIsReady,
                    hasTracker: sessionTracker != nil
                ))

                Button {
                    handleCommand(.faster)
                } label: {
                    Label("Faster", systemImage: "hare")
                }
                .help("Increase speed by 10 WPM")

                Text("\(Int(session.speedWPM)) WPM")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 72)

                Button {
                    handleCommand(.blackout)
                } label: {
                    Label("Blackout", systemImage: "rectangle.inset.filled")
                }
                .help("Blackout (B)")

                if settings.showPacing {
                    Text(pacingLabel)
                        .font(.caption)
                        .foregroundStyle(settings.theme.foreground.opacity(0.8))
                }
            }

            audienceChrome
        }
        .padding(16)
        .background(.black.opacity(0.55))
        .foregroundStyle(settings.theme.foreground)
    }

    private var audienceChrome: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("Audience output", isOn: Binding(
                    get: { audience.isEnabled },
                    set: { enabled in
                        audience.setEnabled(enabled) { [session, appearance] in
                            MacAudienceStageHosting.makeView(
                                session: session,
                                appearance: appearance,
                                text: script.body
                            )
                        }
                        updateSleepGuard()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Audience output")

                Text("Audience")
                    .font(.caption)

                Picker("Display", selection: Binding(
                    get: { audience.selectedDisplayID },
                    set: { id in
                        audience.selectDisplay(id: id)
                        updateSleepGuard()
                    }
                )) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(audience.availableDisplays) { display in
                        Text(displayLabel(display)).tag(Optional(display.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(audience.availableDisplays.isEmpty)
            }

            if let status = audience.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(settings.theme.foreground.opacity(0.7))
                    .accessibilityLabel(status)
            }
        }
        .onAppear {
            audience.refreshDisplays()
            audience.setContentFactory { [session, appearance] in
                MacAudienceStageHosting.makeView(
                    session: session,
                    appearance: appearance,
                    text: script.body
                )
            }
        }
    }

    private func displayLabel(_ display: MacDisplayDescriptor) -> String {
        if display.isMain {
            return "\(display.name) (This Mac)"
        }
        return display.name
    }

    private var pacingLabel: String {
        MacPacingPresentation.remainingLabel(
            wordCount: session.wordCount,
            progress: session.progress,
            speedWPM: session.speedWPM
        )
    }

    private func wireSessionCallbacks() {
        session.onBeganActiveRun = {
            guard var tracker = sessionTracker else { return }
            tracker.start(at: .now)
            sessionTracker = tracker
        }
        session.onCompleted = {
            finishSession()
        }
        session.onPlaybackStateChanged = {
            updateSleepGuard()
        }
    }

    private func prepareSession() async {
        sessionIsReady = false
        do {
            let bookmark: MacReaderBookmark?
            if let domainMatch = try await sessionStore.bookmark(for: script) {
                bookmark = domainMatch
            } else {
                bookmark = try await sessionStore.bookmark(
                    for: script.id,
                    matchingBody: script.body
                )
            }
            sessionTracker = MacReaderSessionTracker(
                scriptID: script.id,
                body: script.body,
                bookmark: bookmark
            )
            if let bookmark, bookmark.isResumeEligible(for: script) || bookmark.isResumeEligible(for: script.body) {
                let domain = bookmark.domainResume(for: script)
                if let speedWPM = domain.speedWPM {
                    session.speedWPM = speedWPM
                    var next = appearance.settings
                    next.speedWPM = speedWPM
                    next.normalize()
                    appearance.settings = next
                }
                var progress = domain.effectiveSpeedProgress(
                    tokenCount: max(1, TextMetrics.wordCount(script.body))
                )
                if progress <= 0 {
                    progress = bookmark.progress
                }
                session.setProgress(progress, notify: false)
            }
        } catch {
            sessionError = error.localizedDescription
            sessionTracker = MacReaderSessionTracker(scriptID: script.id, body: script.body)
        }
        wireSessionCallbacks()
        sessionIsReady = true
    }

    private func handleCommand(_ command: MacReaderCommand) {
        // Play/pause must honor active pre-roll (cancel, not restart). Route
        // through the session command so Space never restarts the countdown.
        if command == .playPause {
            handlePlayPauseCommand()
            return
        }

        var playing = session.isPlaying
        var blackout = session.isBlackout
        var speed = session.speedWPM
        var nextProgress = session.progress

        let effect = MacReaderCommand.apply(
            command,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &nextProgress
        )

        switch effect {
        case .startedPlayback, .pausedPlayback:
            // Play/pause is handled above; pure apply path should not reach here.
            break
        case .toggledBlackout:
            session.toggleBlackout()
        case .revealChrome:
            session.exitBlackout()
            var next = overlay
            next.isBlackout = false
            next.controlsVisible = true
            overlay = next
        case .speedChanged:
            session.speedWPM = speed
            var next = appearance.settings
            next.speedWPM = speed
            next.normalize()
            appearance.settings = next
        case .nudged:
            session.setProgress(nextProgress)
            sessionTracker?.update(progress: nextProgress)
        case .exit:
            teardownPresentation()
            onClose()
        case .showShortcuts:
            showingShortcuts = true
        }
    }

    /// Space / chrome Play: cancel pre-roll when active; otherwise start or pause.
    private func handlePlayPauseCommand() {
        if session.isBlackout {
            session.exitBlackout()
            var next = overlay
            next.isBlackout = false
            next.controlsVisible = true
            overlay = next
            return
        }
        if session.isPlaying || session.preRoll != nil {
            session.pause()
            return
        }
        beginPlayback()
    }

    private func beginPlayback() {
        guard MacReaderSessionInteractionGate.allowsPlayback(
            sessionIsReady: sessionIsReady,
            hasTracker: sessionTracker != nil
        ) else { return }
        session.speedCountdown = appearance.settings.speedCountdown
        session.play(withPreRoll: true)
    }

    private func finishSession() {
        guard var tracker = sessionTracker else { return }
        let recap = tracker.complete(
            at: .now,
            targetDuration: appearance.settings.targetDuration
        )
        sessionTracker = tracker
        completionRecap = recap
        Task {
            do {
                try await sessionStore.save(recap: recap)
                try await sessionStore.clearBookmark(for: script.id)
            } catch {
                sessionError = error.localizedDescription
            }
        }
        updateSleepGuard()
    }

    /// Blackout freezes presentation clock; mirror that in the session tracker without a bookmark.
    private func syncSessionTrackerForBlackout(entered: Bool) {
        guard var tracker = sessionTracker else { return }
        if entered {
            MacReaderBlackoutActiveTimeSync.suspendForBlackout(tracker: &tracker, at: .now)
        } else {
            MacReaderBlackoutActiveTimeSync.resumeAfterBlackoutIfNeeded(
                tracker: &tracker,
                playbackResumed: session.isPlaying,
                at: .now
            )
        }
        sessionTracker = tracker
    }

    private func persistBookmarkIfNeeded() {
        guard var tracker = sessionTracker else { return }
        let progress = session.progress
        let wordCount = max(1, TextMetrics.wordCount(script.body))
        let token = wordCount > 1
            ? Int((progress * Double(wordCount - 1)).rounded())
            : 0
        tracker.update(progress: progress, focusTokenIndex: token)
        guard MacReaderBookmarkPersistencePolicy.shouldSaveAfterPause(tracker) else { return }
        let bookmark = tracker.pause(
            at: .now,
            script: script,
            mode: .speed,
            speedWPM: session.speedWPM,
            focusTokenIndex: token
        )
        sessionTracker = tracker
        Task {
            do {
                try await sessionStore.save(bookmark: bookmark)
            } catch {
                sessionError = error.localizedDescription
            }
        }
    }

    private func updateSleepGuard() {
        if MacDisplaySleepPolicy.shouldPreventSleep(
            isPresenting: true,
            isPlaying: session.isPlaying,
            hasVisibleAudienceOutput: audience.hasVisibleAudienceOutput
        ) {
            sleepGuard.begin()
        } else {
            sleepGuard.end()
        }
    }

    private func teardownPresentation() {
        persistBookmarkIfNeeded()
        session.teardown()
        audience.teardown()
        sleepGuard.end()
        overlayHideTask?.cancel()
    }

    private func scheduleOverlayHide() {
        overlayHideTask?.cancel()
        guard let deadline = overlay.hideControlsAt else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        overlayHideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            var next = overlay
            MacReaderOverlayReducer.reduce(&next, event: .timerFired, now: .now)
            overlay = next
        }
    }
}

struct MacReaderRecapOverlay: View {
    let recap: MacReaderCompletionRecap
    let onDone: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Session complete")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Active time: \(formatTime(recap.activeTime))")
                Text("Average pace: \(Int(recap.averageWordsPerMinute.rounded())) WPM")
                Text("Words: \(recap.wordCount)")
                if recap.wasResumed {
                    Text("Resumed from a previous run")
                        .foregroundStyle(MacDesign.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Close", action: onDone)
                Button("Present again", action: onRestart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(MacDesign.elevated, in: RoundedRectangle(cornerRadius: MacDesign.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MacDesign.cardRadius)
                .stroke(MacDesign.border, lineWidth: 1)
        }
        .foregroundStyle(MacDesign.ink)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct MacReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Typeface", selection: $settings.font) {
                    ForEach(ReadingFont.allCases) { font in
                        Text(font.label).tag(font)
                    }
                }
                Slider(value: $settings.fontSize, in: 20...160, step: 1) {
                    Text("Size \(Int(settings.fontSize))")
                }
                Slider(value: $settings.speedWPM, in: 40...400, step: 5) {
                    Text("Speed \(Int(settings.speedWPM)) WPM")
                }
                Picker("Countdown", selection: $settings.speedCountdown) {
                    ForEach(SpeedCountdown.allCases) { countdown in
                        Text(countdown.shortLabel).tag(countdown)
                    }
                }
                .accessibilityValue(settings.speedCountdown.label)
                Picker("Theme", selection: $settings.theme) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                Picker("Scroll", selection: $settings.scrollStyle) {
                    ForEach(ScrollStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Mirror horizontal", isOn: $settings.mirrorHorizontal)
                Toggle("Mirror vertical", isOn: $settings.mirrorVertical)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 360, height: 460)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    settings.normalize()
                    dismiss()
                }
            }
        }
        .onChange(of: settings.mirrorHorizontal) { _, isOn in
            if isOn { settings.mirrorVertical = false }
        }
        .onChange(of: settings.mirrorVertical) { _, isOn in
            if isOn { settings.mirrorHorizontal = false }
        }
    }
}
