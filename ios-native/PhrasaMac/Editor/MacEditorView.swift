import SwiftUI
import PhrasaDomain

enum MacEditorOpenDecision: Equatable {
    case proceed
    case stayOnCurrent(UUID?)
}

@MainActor
enum MacEditorOpenGate {
    static func resolve(
        currentScriptID: UUID?,
        flush: @MainActor () async -> Bool
    ) async -> MacEditorOpenDecision {
        await flush() ? .proceed : .stayOnCurrent(currentScriptID)
    }
}

struct MacEditorView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel
    let scriptID: UUID

    @State private var draft: ScriptDocument?
    @State private var autosave: MacEditorAutosaveController?
    @State private var editorOriginID = UUID()
    @State private var lastSeenRevision: UInt64 = 0
    @State private var tagsText = ""
    @State private var showOutline = false
    @State private var findQuery = ""
    @State private var findIsPresented = false
    @State private var findStatus: String?
    @State private var findFromOffset = 0
    @State private var highlightedRange: NSRange?

    var body: some View {
        Group {
            if let document = draft {
                VStack(spacing: 0) {
                    editorChrome(document: document)
                    if findIsPresented {
                        findBar(body: document.body)
                    }
                    Divider().background(MacDesign.border)
                    if showOutline {
                        outlineEditor(document: Binding(
                            get: { draft ?? document },
                            set: { applyDraft($0) }
                        ))
                    } else {
                        bodyEditor(document: Binding(
                            get: { draft ?? document },
                            set: { applyDraft($0) }
                        ))
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(MacDesign.canvas)
        .task(id: scriptID) {
            await openDocument()
        }
        .onDisappear {
            let closingScriptID = scriptID
            let closingAutosave = autosave
            Task {
                _ = await closingAutosave?.flush()
                appModel.unregisterEditorFlush(scriptID: closingScriptID)
            }
        }
        .onChange(of: library.editorDocumentChange(id: scriptID)?.revision) { _, _ in
            handleExternalChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macFindLineRequested)) { _ in
            findIsPresented = true
        }
    }

    private func findBar(body: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MacDesign.muted)
                .accessibilityHidden(true)
            TextField("Find a line…", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { performFind(in: body) }
                .accessibilityLabel("Find a line")
            Button("Find") { performFind(in: body) }
                .keyboardShortcut(.defaultAction)
            Button("Done") {
                findIsPresented = false
                findStatus = nil
                highlightedRange = nil
            }
            if let findStatus {
                Text(findStatus)
                    .font(.caption)
                    .foregroundStyle(MacDesign.muted)
            }
        }
        .padding(.horizontal, MacDesign.pagePadding)
        .padding(.vertical, 8)
        .background(MacDesign.elevated)
    }

    private func performFind(in body: String) {
        guard let range = MacFindLineService.firstMatchRange(
            in: body,
            query: findQuery,
            fromUTF16Offset: findFromOffset
        ) else {
            findStatus = "No match"
            highlightedRange = nil
            return
        }
        highlightedRange = range
        findFromOffset = range.location + max(1, range.length)
        let line = MacFindLineService.lineNumber(in: body, utf16Offset: range.location)
        findStatus = "Line \(line)"
    }

    @ViewBuilder
    private func editorChrome(document: ScriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Title", text: Binding(
                    get: { draft?.title ?? document.title },
                    set: { newValue in
                        var next = draft ?? document
                        next.title = newValue
                        applyDraft(next)
                    }
                ))
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .foregroundStyle(MacDesign.ink)
                .accessibilityLabel("Script title")

                Spacer()

                if let autosave {
                    Button {
                        if autosave.state == .failed {
                            autosave.retry()
                        }
                    } label: {
                        Text(autosave.state.label)
                            .font(.caption)
                            .foregroundStyle(
                                autosave.state == .failed ? MacDesign.danger : MacDesign.muted
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(autosave.state != .failed)
                    .accessibilityLabel(autosave.state.label)
                }

                if let document = draft, !document.outline.isEmpty {
                    Button {
                        Task {
                            await appModel.requestOutline(scriptID: scriptID)
                        }
                    } label: {
                        Label("Present Outline", systemImage: "list.bullet.rectangle")
                    }
                    .help("Open the outline presenter for this script")
                }

                Button {
                    Task {
                        await appModel.requestReader(scriptID: scriptID)
                    }
                } label: {
                    Label("Present", systemImage: "play.rectangle.fill")
                }
                .help("Open the speed reader for this script")
            }

            HStack(spacing: 16) {
                Text("\(document.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(MacDesign.muted)
                Text(durationLabel(for: document))
                    .font(.caption)
                    .foregroundStyle(MacDesign.muted)

                TextField("Tags (comma-separated)", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onChange(of: tagsText) { _, newValue in
                        var next = draft ?? document
                        next.tags = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        applyDraft(next)
                    }
                    .accessibilityLabel("Tags")

                Picker(MacEditorChromePresentation.folderPickerTitle, selection: Binding(
                    get: { draft?.folderID },
                    set: { newFolder in
                        Task {
                            let moved = await library.moveScript(scriptID, to: newFolder)
                            if moved, var next = draft {
                                next.folderID = newFolder
                                draft = next
                            }
                        }
                    }
                )) {
                    Text("No Folder").tag(Optional<UUID>.none)
                    ForEach(library.folders) { folder in
                        Text(folder.name).tag(Optional(folder.id))
                    }
                }
                .frame(maxWidth: 180)
                .accessibilityLabel(MacEditorChromePresentation.folderPickerAccessibilityLabel)

                // Segmented control already names its options (Script / Outline).
                // On macOS the Picker title otherwise becomes a squeezed side label
                // in the chrome HStack (~1180×740) — hide it and keep VoiceOver only.
                sectionModePicker
            }
        }
        .padding(MacDesign.pagePadding)
        .background(MacDesign.elevated)
    }

    @ViewBuilder
    private var sectionModePicker: some View {
        let picker = Picker(MacEditorChromePresentation.sectionPickerTitle, selection: $showOutline) {
            Text(MacEditorChromePresentation.sectionScriptOption).tag(false)
            Text(MacEditorChromePresentation.sectionOutlineOption).tag(true)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 180)
        .accessibilityLabel(MacEditorChromePresentation.sectionPickerAccessibilityLabel)

        // `labelsHidden()` has no Bool overload — gate the modifier with the policy flag.
        if MacEditorChromePresentation.sectionPickerHidesVisibleLabel {
            picker.labelsHidden()
        } else {
            picker
        }
    }

    private func bodyEditor(document: Binding<ScriptDocument>) -> some View {
        MacScriptBodyEditor(
            text: Binding(
                get: { document.wrappedValue.body },
                set: { newBody in
                    var next = document.wrappedValue
                    next.body = newBody
                    document.wrappedValue = next
                }
            ),
            highlightedRange: highlightedRange
        )
        .padding(MacDesign.pagePadding)
        .background(MacDesign.canvas)
        .accessibilityLabel("Script body")
    }

    private func outlineEditor(document: Binding<ScriptDocument>) -> some View {
        List {
            ForEach(Array(document.wrappedValue.outline.enumerated()), id: \.element.id) { index, _ in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Talking point", text: Binding(
                        get: {
                            guard document.wrappedValue.outline.indices.contains(index) else { return "" }
                            return document.wrappedValue.outline[index].text
                        },
                        set: { newValue in
                            var next = document.wrappedValue
                            guard next.outline.indices.contains(index) else { return }
                            next.outline[index].text = newValue
                            document.wrappedValue = next
                        }
                    ))
                    TextField("Note", text: Binding(
                        get: {
                            guard document.wrappedValue.outline.indices.contains(index) else { return "" }
                            return document.wrappedValue.outline[index].note
                        },
                        set: { newValue in
                            var next = document.wrappedValue
                            guard next.outline.indices.contains(index) else { return }
                            next.outline[index].note = newValue
                            document.wrappedValue = next
                        }
                    ))
                    .foregroundStyle(MacDesign.muted)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                var next = document.wrappedValue
                next.outline.remove(atOffsets: offsets)
                document.wrappedValue = next
            }
            .onMove { source, destination in
                var next = document.wrappedValue
                next.outline.move(fromOffsets: source, toOffset: destination)
                document.wrappedValue = next
            }

            Button("Add Talking Point") {
                var next = document.wrappedValue
                next.outline.append(OutlinePoint())
                document.wrappedValue = next
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(MacDesign.canvas)
    }

    private func openDocument() async {
        let requestedScriptID = scriptID
        if let autosave {
            switch await MacEditorOpenGate.resolve(
                currentScriptID: draft?.id,
                flush: { await autosave.flush() }
            ) {
            case .proceed:
                break
            case .stayOnCurrent(let currentScriptID):
                // Keep the failed draft and its Retry control visible. Also return
                // list selection to that document so chrome and editor identity agree.
                appModel.selectedScriptID = currentScriptID
                return
            }
        }
        guard !Task.isCancelled, requestedScriptID == scriptID else { return }
        guard let script = library.script(id: scriptID) else {
            draft = nil
            autosave = nil
            return
        }
        editorOriginID = UUID()
        draft = script
        tagsText = script.tags.joined(separator: ", ")
        lastSeenRevision = library.editorDocumentChange(id: scriptID)?.revision ?? 0
        installAutosave(for: script)
        _ = await library.markOpened(scriptID)
    }

    private func applyDraft(_ document: ScriptDocument) {
        draft = document
        _ = library.stageEditorDraft(document, editorOriginID: editorOriginID)
        autosave?.record(document)
    }

    private func handleExternalChange() {
        guard let change = library.editorDocumentChange(id: scriptID),
              change.revision != lastSeenRevision else { return }
        lastSeenRevision = change.revision
        switch MacEditorExternalChangePolicy.decision(for: change, editorOriginID: editorOriginID) {
        case .ignore:
            return
        case .replace(let document):
            autosave?.cancelPending()
            draft = document
            if let document {
                tagsText = document.tags.joined(separator: ", ")
                installAutosave(for: document)
            } else {
                autosave = nil
                appModel.unregisterEditorFlush(scriptID: scriptID)
            }
        case .rebase(let metadata):
            autosave?.rebase(metadata)
            if var current = draft {
                metadata.apply(to: &current)
                draft = current
            }
        }
    }

    private func durationLabel(for document: ScriptDocument) -> String {
        let seconds = Int(document.estimatedDuration.rounded())
        let minutes = seconds / 60
        let rem = seconds % 60
        if minutes == 0 { return "~\(rem)s at 150 WPM" }
        return "~\(minutes)m \(rem)s at 150 WPM"
    }

    private func installAutosave(for document: ScriptDocument) {
        let originID = editorOriginID
        let controller = MacEditorAutosaveController(initial: document) { updated in
            await library.update(updated, editorOriginID: originID)
        }
        autosave = controller
        appModel.registerEditorFlush(scriptID: document.id) {
            await controller.flush()
        }
    }
}

/// Stable chrome presentation rules for the selected-script Mac editor.
/// Keeps layout/accessibility decisions testable without mounting SwiftUI.
enum MacEditorChromePresentation {
    /// Menu folder picker keeps a short visible title on wide chrome rows.
    static let folderPickerTitle = "Folder"
    static let folderPickerShowsVisibleLabel = true
    static let folderPickerAccessibilityLabel = "Folder"

    /// Segmented Script/Outline switch: options are self-labeling; a visible
    /// Picker title stacks vertically in tight chrome and must stay hidden.
    static let sectionPickerTitle = "Editor section"
    static let sectionPickerHidesVisibleLabel = true
    static let sectionPickerAccessibilityLabel = "Editor section"
    static let sectionScriptOption = "Script"
    static let sectionOutlineOption = "Outline"
}
