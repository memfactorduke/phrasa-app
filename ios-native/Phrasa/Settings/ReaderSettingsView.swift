import SwiftUI

/// Stable section order for reader settings. Keep mirror/flip first so prompter
/// hardware setup is the first control users see.
enum ReaderSettingsPresentation {
    enum Section: String, CaseIterable, Equatable {
        case display
        case looks
        case theme
        case typography
        case layout
        case playback
        case voice
        case pacing
        case reset
    }

    /// Canonical top-to-bottom order. Display (mirror / flip) is first.
    static let sectionOrder: [Section] = Section.allCases

    static var leadingSection: Section { sectionOrder[0] }
}

/// Complete, presentation-first controls for the native teleprompter.
///
/// Changes are written through the binding immediately. The presenting reader
/// can persist them on change or when this sheet is dismissed.
struct ReaderSettingsView: View {
    @Binding var settings: ReaderSettings

    @Environment(\.dismiss) private var dismiss
    @State private var customPresets = ReaderAppearancePresetStore.load()
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var showingResetConfirmation = false

    private let themeColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private let languages: [(code: String, name: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("en-AU", "English (Australia)"),
        ("es-ES", "Spanish (Spain)"),
        ("es-MX", "Spanish (Latin America)"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("nl-NL", "Dutch"),
        ("pl-PL", "Polish"),
        ("sv-SE", "Swedish"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("zh-CN", "Chinese (Mandarin)"),
        ("hi-IN", "Hindi")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(ReaderSettingsPresentation.sectionOrder, id: \.self) { section in
                        sectionContent(section)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(PhrasaDesign.canvas.ignoresSafeArea())
            .navigationTitle("Reader settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(PhrasaDesign.ember)
        .alert("Save current look", isPresented: $namingPreset) {
            TextField("Look name", text: $presetName)
            Button("Cancel", role: .cancel) { presetName = "" }
            Button("Save") { saveCurrentLook() }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This saves the current theme, type, margins, alignment, mirrors, and focus line.")
        }
        .confirmationDialog(
            "Reset reader settings?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset to defaults", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settings = ReaderSettings()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets appearance, playback, voice, display, and pacing settings. Your saved looks stay available.")
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: ReaderSettingsPresentation.Section) -> some View {
        switch section {
        case .display: displaySection
        case .looks: looksSection
        case .theme: themeSection
        case .typography: typographySection
        case .layout: layoutSection
        case .playback: playbackSection
        case .voice: voiceSection
        case .pacing: pacingSection
        case .reset: resetSection
        }
    }

    private var looksSection: some View {
        ReaderSettingsSection(
            "Looks",
            footer: "Looks change presentation only. Speed, voice language, and playback behavior stay as they are."
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderAppearancePreset.builtIns + customPresets) { preset in
                        ReaderPresetChip(
                            preset: preset,
                            isSelected: preset.appearance == ReaderAppearance(settings: settings),
                            apply: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    settings = preset.appearance.applying(to: settings)
                                }
                            },
                            delete: preset.isBuiltIn ? nil : { deletePreset(preset.id) }
                        )
                    }

                    Button {
                        presetName = ""
                        namingPreset = true
                    } label: {
                        Label("Save current", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PhrasaDesign.muted)
                            .padding(.horizontal, 13)
                            .frame(minHeight: 44)
                            .background(PhrasaDesign.surfaceSecondary)
                            .clipShape(Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(PhrasaDesign.border, style: StrokeStyle(lineWidth: 1, dash: [4]))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Saves the current appearance as a reusable look")
                }
                .padding(16)
            }
        }
    }

    private var themeSection: some View {
        ReaderSettingsSection("Theme") {
            LazyVGrid(columns: themeColumns, spacing: 10) {
                ForEach(ReaderTheme.allCases) { theme in
                    ReaderThemeTile(
                        theme: theme,
                        isSelected: settings.theme == theme,
                        action: { settings.theme = theme }
                    )
                }
            }
            .padding(14)
        }
    }

    private var typographySection: some View {
        ReaderSettingsSection("Typography") {
            LazyVGrid(columns: themeColumns, spacing: 8) {
                ForEach(ReadingFont.allCases) { readingFont in
                    ReaderFontTile(
                        readingFont: readingFont,
                        isSelected: settings.font == readingFont,
                        action: { settings.font = readingFont }
                    )
                }
            }
            .padding(10)

            Divider().overlay(PhrasaDesign.border)

            ReaderSettingsSlider(
                title: "Font size",
                valueText: "\(Int(settings.fontSize.rounded())) pt",
                accessibilityValue: "\(Int(settings.fontSize.rounded())) points",
                range: 20...160,
                step: 2,
                value: normalizedBinding(\.fontSize)
            )

            Divider().overlay(PhrasaDesign.border)

            ReaderSettingsSlider(
                title: "Line height",
                valueText: settings.lineHeight.formatted(.number.precision(.fractionLength(2))),
                accessibilityValue: settings.lineHeight.formatted(.number.precision(.fractionLength(2))),
                range: 1...2.4,
                step: 0.05,
                value: normalizedBinding(\.lineHeight)
            )
        }
    }

    private var layoutSection: some View {
        ReaderSettingsSection(
            "Layout",
            footer: "Reading width leaves equal margins on both sides. Focus line sets where the active words sit on screen."
        ) {
            Picker("Alignment", selection: normalizedBinding(\.alignment)) {
                ForEach(ReadingAlignment.allCases) { alignment in
                    Text(alignment.label).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            .padding(16)

            Divider().overlay(PhrasaDesign.border)

            ReaderSettingsSlider(
                title: "Reading width",
                valueText: "\(readingWidthPercent)%",
                accessibilityValue: "\(readingWidthPercent) percent",
                range: 0...0.4,
                step: 0.01,
                value: normalizedBinding(\.horizontalMargin)
            )

            Divider().overlay(PhrasaDesign.border)

            ReaderSettingsSlider(
                title: "Focus line",
                valueText: "\(Int((settings.focusPosition * 100).rounded()))%",
                accessibilityValue: "\(Int((settings.focusPosition * 100).rounded())) percent from the top",
                range: 0.15...0.85,
                step: 0.01,
                value: normalizedBinding(\.focusPosition)
            )
        }
    }

    private var playbackSection: some View {
        ReaderSettingsSection(
            "Playback",
            footer: "Countdown runs only when Speed mode starts from the beginning. Voice mode and mid-script resume start immediately."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode")
                    .font(.subheadline)
                    .foregroundStyle(PhrasaDesign.muted)
                Picker("Mode", selection: normalizedBinding(\.mode)) {
                    ForEach(ReaderMode.allCases) { mode in
                        Label(mode.label, systemImage: mode == .speed ? "gauge.with.dots.needle.67percent" : "mic")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(16)

            Divider().overlay(PhrasaDesign.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scroll style")
                    .font(.subheadline)
                    .foregroundStyle(PhrasaDesign.muted)
                Picker("Scroll style", selection: normalizedBinding(\.scrollStyle)) {
                    Text("Smooth").tag(ScrollStyle.continuous)
                    Text("Line by line").tag(ScrollStyle.line)
                }
                .pickerStyle(.segmented)
            }
            .padding(16)

            Divider().overlay(PhrasaDesign.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("Countdown")
                    .font(.subheadline)
                    .foregroundStyle(PhrasaDesign.muted)
                Picker("Countdown", selection: normalizedBinding(\.speedCountdown)) {
                    ForEach(SpeedCountdown.allCases) { countdown in
                        Text(countdown.shortLabel).tag(countdown)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityValue(settings.speedCountdown.label)
            }
            .padding(16)

            Divider().overlay(PhrasaDesign.border)

            ReaderSettingsSlider(
                title: "Speed",
                valueText: "\(Int(settings.speedWPM.rounded())) wpm",
                accessibilityValue: "\(Int(settings.speedWPM.rounded())) words per minute",
                range: 40...400,
                step: 5,
                value: normalizedBinding(\.speedWPM)
            )
        }
    }

    private var voiceSection: some View {
        ReaderSettingsSection(
            "Voice",
            footer: "Used by voice-following and automatic outline advance. Audio is never sent to Phrasa's servers."
        ) {
            Picker("Recognition language", selection: normalizedBinding(\.recognitionLanguage)) {
                ForEach(languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .accessibilityValue(languageName)
        }
    }

    private var displaySection: some View {
        ReaderSettingsSection(
            "Display",
            footer: "Horizontal mirror is for beam-splitter glass. Vertical flip is for inverted monitor rigs. Only one can be active."
        ) {
            Toggle("Mirror horizontally", isOn: mirrorHorizontalBinding)
                .accessibilityHint("Flips the prompter left to right for beam-splitter glass")
                .padding(.horizontal, 16)
                .frame(minHeight: 54)

            Divider().overlay(PhrasaDesign.border)

            Toggle("Flip vertically", isOn: mirrorVerticalBinding)
                .accessibilityHint("Flips the prompter top to bottom and turns off horizontal mirroring")
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
        }
    }

    private var pacingSection: some View {
        ReaderSettingsSection(
            "Pacing",
            footer: "Without a target, Phrasa uses the script's estimated reading time."
        ) {
            Toggle("Show pacing timer", isOn: normalizedBinding(\.showPacing))
                .padding(.horizontal, 16)
                .frame(minHeight: 54)

            Divider().overlay(PhrasaDesign.border)

            Toggle("Use a target time", isOn: targetEnabledBinding)
                .disabled(!settings.showPacing)
                .padding(.horizontal, 16)
                .frame(minHeight: 54)

            if settings.showPacing, settings.targetDuration != nil {
                Divider().overlay(PhrasaDesign.border)

                Stepper(
                    value: targetDurationBinding,
                    in: 15...14_400,
                    step: 15
                ) {
                    HStack {
                        Text("Target time")
                        Spacer()
                        Text((settings.targetDuration ?? 300).compactDuration)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(PhrasaDesign.muted)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .accessibilityValue((settings.targetDuration ?? 300).compactDuration)
            }
        }
    }

    private var resetSection: some View {
        Button(role: .destructive) {
            showingResetConfirmation = true
        } label: {
            Label("Reset reader settings", systemImage: "arrow.counterclockwise")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(PhrasaDesign.ember)
        .accessibilityHint("Restores every reader setting to its original value")
    }

    private var readingWidthPercent: Int {
        Int(((1 - settings.horizontalMargin * 2) * 100).rounded())
    }

    private var languageName: String {
        languages.first(where: { $0.code == settings.recognitionLanguage })?.name
            ?? settings.recognitionLanguage
    }

    private var mirrorHorizontalBinding: Binding<Bool> {
        Binding(
            get: { settings.mirrorHorizontal },
            set: { enabled in
                settings.mirrorHorizontal = enabled
                if enabled { settings.mirrorVertical = false }
                settings.normalize()
            }
        )
    }

    private var mirrorVerticalBinding: Binding<Bool> {
        Binding(
            get: { settings.mirrorVertical },
            set: { enabled in
                settings.mirrorVertical = enabled
                if enabled { settings.mirrorHorizontal = false }
                settings.normalize()
            }
        )
    }

    private var targetEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.targetDuration != nil },
            set: { enabled in
                settings.targetDuration = enabled ? (settings.targetDuration ?? 300) : nil
                settings.normalize()
            }
        )
    }

    private var targetDurationBinding: Binding<Double> {
        Binding(
            get: { settings.targetDuration ?? 300 },
            set: { value in
                settings.targetDuration = value.clamped(to: 15...14_400)
                settings.normalize()
            }
        )
    }

    private func normalizedBinding<Value>(_ keyPath: WritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                settings.normalize()
            }
        )
    }

    private func saveCurrentLook() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = ReaderAppearancePreset(
            id: "custom:\(UUID().uuidString.lowercased())",
            name: String(name.prefix(40)),
            appearance: ReaderAppearance(settings: settings),
            isBuiltIn: false
        )
        customPresets.append(preset)
        ReaderAppearancePresetStore.save(customPresets)
        presetName = ""
    }

    private func deletePreset(_ id: String) {
        customPresets.removeAll { $0.id == id }
        ReaderAppearancePresetStore.save(customPresets)
    }
}

#Preview {
    @Previewable @State var settings = ReaderSettings()
    ReaderSettingsView(settings: $settings)
}
