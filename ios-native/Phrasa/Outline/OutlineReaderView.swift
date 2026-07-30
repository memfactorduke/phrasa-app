import SwiftUI
import UIKit
import PhrasaCore

struct OutlineReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LibraryStore.self) private var library
    let script: ScriptDocument

    @State private var engine: OutlineCoverageEngine
    @State private var speech = SpeechRecognitionService()
    @State private var isListening = false
    @State private var resumeListeningWhenActive = false
    @State private var lastProcessedTail: String?
    @ScaledMetric(relativeTo: .largeTitle) private var pointFontSize: CGFloat = 48
    @FocusState private var stageFocused: Bool

    init(script: ScriptDocument) {
        self.script = script
        _engine = State(initialValue: OutlineCoverageEngine(outline: script.outline))
    }

    private var points: [OutlinePointModel] { engine.points }

    /// Stage is driven only by the engine's confirmed index — never coverage or candidates.
    private var stage: OutlineStagePresentation? {
        OutlineStagePresentation.make(from: engine)
    }

    var body: some View {
        ZStack {
            PhrasaDesign.canvas.ignoresSafeArea()
            if points.isEmpty {
                emptyState
            } else if engine.isComplete {
                completionState
            } else if let stage {
                pointReader(stage: stage)
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled(true)
        .focusable()
        .focused($stageFocused)
        .onAppear {
            stageFocused = true
            startListeningIfNeeded()
        }
        .onDisappear {
            speech.stop()
            isListening = false
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .onChange(of: engine.index) { _, _ in announceCurrentPoint() }
        .onChange(of: engine.isComplete) { _, complete in
            if complete {
                speech.stop()
                isListening = false
                resumeListeningWhenActive = false
                UIAccessibility.post(notification: .announcement, argument: "Outline complete")
            }
        }
        .onChange(of: library.settings.recognitionLanguage) { _, _ in
            if isListening {
                startListeningIfNeeded(forceRestart: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if resumeListeningWhenActive, !engine.isComplete {
                    resumeListeningWhenActive = false
                    startListeningIfNeeded(forceRestart: true)
                }
            } else {
                resumeListeningWhenActive = isListening && !engine.isComplete
                speech.stop()
                isListening = false
            }
        }
        // Animate only when the confirmed engine index / completion flips.
        .animation(PhrasaDesign.motion(reduceMotion: reduceMotion), value: engine.index)
        .animation(PhrasaDesign.motion(reduceMotion: reduceMotion), value: engine.isComplete)
    }

    // MARK: - Chrome

    private var closeButton: some View {
        Button {
            speech.stop()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: PhrasaDesign.minTouchTarget, height: PhrasaDesign.minTouchTarget)
        }
        .foregroundStyle(PhrasaDesign.ink)
        .background(PhrasaDesign.surfaceSecondary, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                .stroke(PhrasaDesign.border, lineWidth: 1)
        }
        .accessibilityLabel("Close outline")
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                closeButton
            }
            ContentUnavailableView(
                "No outline yet",
                systemImage: "list.bullet.rectangle",
                description: Text("Add talking points in the editor, then return here to present them.")
            )
            .foregroundStyle(PhrasaDesign.muted)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Stage

    /// Stable three-slot stage: previous / current / next always occupy rows.
    /// Content crossfades inside fixed role slots when `engine.index` changes.
    private func pointReader(stage: OutlineStagePresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(stage.compactProgressLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .tracking(1.4)
                    .foregroundStyle(PhrasaDesign.muted)
                    .accessibilityLabel(stage.progressLabel)
                Spacer(minLength: 8)
                // Chrome only — kept small so it never competes with the stage.
                listeningChip
                closeButton
            }

            voiceAccessBanner

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(stage.slots) { slot in
                        stageSlot(slot)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Outline stage")

            HStack(spacing: 12) {
                Button { apply(engine.goPrevious(reason: .manual)) } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: PhrasaDesign.minTouchTarget)
                }
                .buttonStyle(PhrasaSecondaryButtonStyle())
                .disabled(engine.index == 0 && !engine.isComplete)

                Button { apply(engine.goNext(reason: .manual)) } label: {
                    Label(
                        engine.index == points.count - 1 ? "Finish" : "Next",
                        systemImage: engine.index == points.count - 1 ? "checkmark" : "chevron.right"
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: PhrasaDesign.minTouchTarget)
                }
                .buttonStyle(PhrasaPrimaryButtonStyle())
            }
            .font(.headline)

            // Secondary chrome: wake-word hint stays below the stage and controls.
            Text(OutlineSpeechCommandParser.userFacingHint)
                .font(.caption2)
                .foregroundStyle(PhrasaDesign.muted.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(OutlineSpeechCommandParser.userFacingHint)
                .accessibilityHint(
                    "\(OutlineSpeechCommandParser.userFacingPrevious). \(OutlineSpeechCommandParser.userFacingNext)."
                )
        }
        .padding(24)
    }

    /// Fixed-role stage row. Identity is the role so content swaps do not remove the row.
    @ViewBuilder
    private func stageSlot(_ slot: OutlineStagePresentation.Slot) -> some View {
        ZStack(alignment: .topLeading) {
            // Geometry reserve for empty boundary slots (first/last).
            if slot.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: reservedHeight(for: slot.role), alignment: .topLeading)
                    .accessibilityHidden(true)
            } else if let primary = slot.primary {
                slotContent(
                    role: slot.role,
                    primary: primary,
                    note: slot.note
                )
                // Content identity only — container stays mounted via ForEach(role).
                .id(slot.pointID)
                .transition(slotContentTransition)
            }
        }
        .frame(maxWidth: .infinity, minHeight: reservedHeight(for: slot.role), alignment: .topLeading)
        .animation(PhrasaDesign.motion(reduceMotion: reduceMotion), value: slot.pointID)
        .accessibilityElement(children: slot.isEmpty ? .ignore : .combine)
        .accessibilityHidden(slot.isEmpty)
        .accessibilityLabel(slot.accessibilityLabel ?? "")
        .accessibilityAddTraits(slot.role == .current && !slot.isEmpty ? .isHeader : [])
    }

    /// Crossfade (and mild slide when motion is allowed). Never forced under Reduce Motion.
    private var slotContentTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .move(edge: .top))
        )
    }

    /// Role-based minimum heights keep first/last boundary geometry stable.
    private func reservedHeight(for role: OutlineStagePresentation.Role) -> CGFloat {
        switch role {
        case .previous: return 44
        case .current: return max(pointFontSize * 1.6, 72)
        case .next: return 64
        }
    }

    @ViewBuilder
    private func slotContent(
        role: OutlineStagePresentation.Role,
        primary: String,
        note: String?
    ) -> some View {
        switch role {
        case .previous:
            VStack(alignment: .leading, spacing: 6) {
                Text(role.eyebrow.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(PhrasaDesign.muted.opacity(0.85))
                Text(primary)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(PhrasaDesign.ink.opacity(0.42))
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .current:
            VStack(alignment: .leading, spacing: 14) {
                PhrasaEyebrow(text: role.eyebrow)
                Text(primary)
                    .font(.system(size: pointFontSize, weight: .semibold, design: .default))
                    .foregroundStyle(PhrasaDesign.ink)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.title3)
                        .foregroundStyle(PhrasaDesign.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .next:
            VStack(alignment: .leading, spacing: 6) {
                Text(role.eyebrow.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(PhrasaDesign.muted)
                Text(primary)
                    .font(.headline)
                    .foregroundStyle(PhrasaDesign.ink.opacity(0.72))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                // Subdued secondary cue — note vocabulary can drive auto-advance.
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(PhrasaDesign.muted.opacity(0.85))
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                    .stroke(PhrasaDesign.border, lineWidth: 1)
            }
        }
    }

    private var listeningChip: some View {
        let label: String = {
            switch speech.status {
            case .listening, .starting, .requestingPermission:
                return speech.status == .listening ? "Listening" : speech.status.label
            case .denied:
                return "Voice blocked"
            case .unavailable:
                return "Voice off"
            case .idle:
                return isListening ? "Listening" : "Voice off"
            }
        }()

        return Text(label.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(PhrasaDesign.muted.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(PhrasaDesign.surfaceSecondary, in: Capsule())
            .overlay {
                Capsule().stroke(PhrasaDesign.border, lineWidth: 1)
            }
            .accessibilityLabel(label)
            .accessibilityHint(OutlineSpeechCommandParser.userFacingHint)
    }

    /// Unmistakable denial/unavailable banner — not a silent chip-only failure.
    @ViewBuilder
    private var voiceAccessBanner: some View {
        switch speech.status {
        case .denied, .unavailable:
            let trust = VoiceTrustPresentation.resolve(
                status: speech.status,
                health: speech.health,
                isPlaying: isListening,
                recentlyAccepted: false,
                secondsSinceAcceptance: 100,
                missStreak: 0,
                hasProvisional: false,
                permissionFailure: speech.lastPermissionFailure
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(trust.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhrasaDesign.ink)
                if let detail = trust.actionableDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PhrasaDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    if trust.offersOpenSettings {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                    Button("Try again") {
                        startListeningIfNeeded(forceRestart: true)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                    .stroke(PhrasaDesign.border, lineWidth: 1)
            }
            // Keep both recovery buttons individually reachable by VoiceOver.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(PhrasaA11y.Reader.voiceStatus)
            .accessibilityValue(
                VoiceTrustPresentation.accessibilityDiagnosticValue(
                    permissionFailure: speech.lastPermissionFailure,
                    status: speech.status
                )
            )
        default:
            EmptyView()
        }
    }

    private var completionState: some View {
        VStack(spacing: 22) {
            HStack {
                Spacer()
                closeButton
            }
            Spacer(minLength: 12)
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(PhrasaDesign.ink)
                .frame(width: 72, height: 72)
                .background(PhrasaDesign.surfaceSecondary, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                        .stroke(PhrasaDesign.border, lineWidth: 1)
                }
                .accessibilityHidden(true)
            PhrasaEyebrow(text: "Complete")
            Text("Outline complete")
                .font(.system(.largeTitle, design: .default, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(PhrasaDesign.ink)
            Text("You made it through all \(points.count) talking points.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(PhrasaDesign.muted)
            Spacer()
            VStack(spacing: 12) {
                Button("Done") {
                    speech.stop()
                    dismiss()
                }
                .buttonStyle(PhrasaPrimaryButtonStyle())
                Button {
                    PhrasaMotion.withAnimationIfAllowed(reduceMotion: reduceMotion) {
                        engine.restart()
                    }
                    startListeningIfNeeded()
                } label: {
                    Label("Start again", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: PhrasaDesign.minTouchTarget)
                }
                .buttonStyle(PhrasaSecondaryButtonStyle())
            }
            .frame(maxWidth: 520)
        }
        .padding(24)
    }

    // MARK: - Actions

    /// Consumes a session action after the engine has already mutated.
    /// Transitions animate via value-keyed animation on `engine.index` / `isComplete`.
    private func apply(_ action: OutlineSessionAction) {
        switch action {
        case .none, .stayed, .boundary, .advanced, .completed, .retreated:
            break
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .escape:
            speech.stop()
            dismiss()
            return .handled
        case .leftArrow, .pageUp, .upArrow:
            guard !points.isEmpty else { return .handled }
            apply(engine.goPrevious(reason: .manual))
            return .handled
        case .rightArrow, .pageDown, .downArrow, .space:
            guard !points.isEmpty else { return .handled }
            if engine.isComplete {
                speech.stop()
                dismiss()
            } else {
                apply(engine.goNext(reason: .manual))
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func announceCurrentPoint() {
        guard let current = engine.currentPoint else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: "Point \(engine.index + 1) of \(points.count). \(current.spokenText)"
        )
    }

    // MARK: - Speech

    private func startListeningIfNeeded(forceRestart: Bool = false) {
        guard !points.isEmpty else { return }
        // Skip only while a live start is already owned. forceRestart covers
        // language changes and the denial banner's Try again (no stacked prompts:
        // SpeechRecognitionService.start always stop()s prior generation first).
        if isListening, !forceRestart { return }
        isListening = true
        lastProcessedTail = nil
        Task {
            await speech.start(
                language: library.settings.recognitionLanguage,
                scriptText: engine.recognitionContextText
            ) { event in
                handleSpeechEvent(event)
            }
        }
    }

    private func handleSpeechEvent(_ event: SpeechPipelineEvent) {
        // Dedup empty/unchanged tails so health-only ticks cannot re-fire commands.
        let key = VoiceFollowBinding.alignmentTailKey(event.tail)
        if key == nil {
            // Silence: still tick the engine so coverage holds without advancing.
            _ = engine.observeSpeech(normalizedWords: [])
            return
        }
        guard VoiceFollowBinding.shouldProcessAlignmentTail(
            tail: event.tail,
            lastAlignedNonemptyTail: lastProcessedTail
        ) else { return }

        lastProcessedTail = key
        let action = engine.observeSpeech(utterance: event.tail)
        apply(action)
    }
}

// MARK: - Content helpers (shared with tests / coverage model)

enum OutlineReaderContent {
    private static let trimmingCharacters = CharacterSet.whitespacesAndNewlines

    static func meaningfulPoints(from outline: [OutlinePoint]) -> [OutlinePoint] {
        outline.filter {
            !$0.text.trimmingCharacters(in: trimmingCharacters).isEmpty
                || !$0.note.trimmingCharacters(in: trimmingCharacters).isEmpty
        }
    }

    static func primaryText(for point: OutlinePoint) -> String {
        let heading = point.text.trimmingCharacters(in: trimmingCharacters)
        if !heading.isEmpty { return heading }
        return point.note.trimmingCharacters(in: trimmingCharacters)
    }

    static func supportingNote(for point: OutlinePoint) -> String? {
        let heading = point.text.trimmingCharacters(in: trimmingCharacters)
        let note = point.note.trimmingCharacters(in: trimmingCharacters)
        guard !heading.isEmpty, !note.isEmpty else { return nil }
        return note
    }

    static func spokenText(for point: OutlinePoint) -> String {
        let primary = primaryText(for: point)
        guard let note = supportingNote(for: point) else { return primary }
        return "\(primary). \(note)"
    }
}
