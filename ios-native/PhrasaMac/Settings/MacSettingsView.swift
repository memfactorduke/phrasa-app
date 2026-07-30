import SwiftUI
import PhrasaDomain

struct MacSettingsView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacCloudAccountSyncRuntime.self) private var accountSync
    @State private var draft = ReaderSettings()
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TabView {
            Form {
                Section("Speed reader defaults") {
                    Picker("Scroll style", selection: $draft.scrollStyle) {
                        ForEach(ScrollStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Picker("Typeface", selection: $draft.font) {
                        ForEach(ReadingFont.allCases) { font in
                            Text(font.label).tag(font)
                        }
                    }
                    Slider(value: $draft.fontSize, in: 20...160, step: 1) {
                        Text("Font size")
                    } minimumValueLabel: {
                        Text("A").font(.caption)
                    } maximumValueLabel: {
                        Text("A").font(.title3)
                    }
                    Slider(value: $draft.lineHeight, in: 1...2.4, step: 0.05) {
                        Text("Line height")
                    }
                    Slider(value: $draft.horizontalMargin, in: 0...0.4, step: 0.01) {
                        Text("Side margin")
                    }
                    Slider(value: $draft.focusPosition, in: 0.15...0.85, step: 0.01) {
                        Text("Focus line")
                    }
                    Slider(value: $draft.speedWPM, in: 40...400, step: 5) {
                        Text("Speed \(Int(draft.speedWPM)) WPM")
                    }
                    Picker("Countdown", selection: $draft.speedCountdown) {
                        ForEach(SpeedCountdown.allCases) { countdown in
                            Text(countdown.shortLabel).tag(countdown)
                        }
                    }
                    .accessibilityValue(draft.speedCountdown.label)
                    Picker("Theme", selection: $draft.theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    Toggle("Mirror horizontal", isOn: $draft.mirrorHorizontal)
                        .onChange(of: draft.mirrorHorizontal) { _, isOn in
                            if isOn { draft.mirrorVertical = false }
                        }
                    Toggle("Mirror vertical", isOn: $draft.mirrorVertical)
                        .onChange(of: draft.mirrorVertical) { _, isOn in
                            if isOn { draft.mirrorHorizontal = false }
                        }
                    Toggle("Show pacing", isOn: $draft.showPacing)
                }

                Section("About") {
                    LabeledContent("Mode") {
                        Text("Speed-first (local-first)")
                            .foregroundStyle(MacDesign.muted)
                    }
                    LabeledContent("Voice following") {
                        Text("Not on Mac yet")
                            .foregroundStyle(MacDesign.muted)
                    }
                    Text("Voice ships on Mac only when the Speech adapter passes the same reliability gates as iOS. Speed prompting, import, export, backup, and optional cloud sync work offline-first.")
                        .font(.caption)
                        .foregroundStyle(MacDesign.muted)
                    Link(
                        "Open Source Code",
                        destination: URL(string: "https://github.com/memfactorduke/phrasa-app")!
                    )
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem {
                Label("Reader", systemImage: "text.alignleft")
            }

            NavigationStack {
                MacCloudAccountView(runtime: accountSync)
            }
            .tabItem {
                Label("Account & sync", systemImage: "person.crop.circle")
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .onAppear {
            draft = library.settings
        }
        .onChange(of: draft) { _, newValue in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                var normalized = newValue
                normalized.normalize()
                _ = await library.saveSettings(normalized)
            }
        }
    }
}
