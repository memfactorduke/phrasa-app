import SwiftUI
import UIKit
import Observation

enum EditorSaveState: Equatable {
    case saved
    case saving
    case failed

    var label: String {
        switch self {
        case .saved: "Saved"
        case .saving: "Saving…"
        case .failed: "Save failed — retry"
        }
    }
}

/// A dirty-driven, single-writer save queue for the editor.
///
/// Opening a document never writes it: only user-editable fields participate in
/// the dirty check. While a save is in flight, newer edits replace the queued
/// value and are written immediately afterward, so repository writes can never
/// overlap or land out of order. `flush()` cancels the debounce and drains the
/// queue, which lets navigation and app-lifecycle exits make a final save attempt.
@MainActor
@Observable
final class EditorAutosaveController {
    typealias SaveAction = @MainActor (ScriptDocument) async -> Bool

    private(set) var state: EditorSaveState = .saved

    private var persistedContent: EditableScriptContent
    private struct PendingDraft {
        var document: ScriptDocument
        var metadataRevision: UInt64
    }

    private var pending: PendingDraft?
    private var metadataRevision: UInt64 = 0
    private var rebasedFolderID: FolderRebase = .none
    private var debounceTask: Task<Void, Never>?
    private var saveLoop: Task<Void, Never>?
    private let debounceDelay: Duration
    private let saveAction: SaveAction

    private enum FolderRebase {
        case none
        case value(UUID?)
    }

    init(
        initial: ScriptDocument,
        debounceDelay: Duration = .milliseconds(600),
        saveAction: @escaping SaveAction
    ) {
        persistedContent = EditableScriptContent(initial)
        self.debounceDelay = debounceDelay
        self.saveAction = saveAction
    }

    func record(_ document: ScriptDocument) {
        let content = EditableScriptContent(document)
        guard content != persistedContent else {
            debounceTask?.cancel()
            debounceTask = nil
            if saveLoop == nil {
                pending = nil
                state = .saved
            } else {
                // A write of an older edit is already in flight. Queue the
                // reverted value so it becomes the final persisted document.
                pending = PendingDraft(
                    document: document,
                    metadataRevision: metadataRevision
                )
                state = .saving
            }
            return
        }

        pending = PendingDraft(
            document: document,
            metadataRevision: metadataRevision
        )
        state = .saving
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceDelay] in
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    @discardableResult
    func flush() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil

        if saveLoop == nil, pending != nil { startSaveLoop() }
        while let loop = saveLoop {
            await loop.value
            if saveLoop == nil, pending != nil, state != .failed {
                startSaveLoop()
            }
        }
        return pending == nil && state == .saved
    }

    func retry() {
        guard pending != nil else { return }
        state = .saving
        if saveLoop == nil { startSaveLoop() }
    }

    /// An external durable replacement (for example, a completed cloud sync)
    /// establishes a new editor baseline. Cancel both the debounce and any
    /// queued save so the old whole-document draft cannot overwrite it later.
    func cancelPending() {
        debounceTask?.cancel()
        debounceTask = nil
        saveLoop?.cancel()
        saveLoop = nil
        pending = nil
        state = .saved
    }

    /// Applies durable metadata without treating the editor's pending title or
    /// body as saved. Folder changes are folded into both the known baseline
    /// and any queued draft, while open-time metadata rides on the document
    /// that LibraryStore ultimately persists.
    func rebase(_ metadata: LibraryEditorDocumentMetadataChange) {
        if case .folderID(let folderID) = metadata {
            metadataRevision &+= 1
            rebasedFolderID = .value(folderID)
        }
        persistedContent.apply(metadata)
        if var pending {
            metadata.apply(to: &pending.document)
            pending.metadataRevision = metadataRevision
            self.pending = pending
        }
    }

    private func startSaveLoop() {
        guard saveLoop == nil else { return }
        saveLoop = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            state = .saving
            let next = request.document
            let succeeded = await saveAction(next)
            if succeeded {
                persistedContent = EditableScriptContent(next)
                if request.metadataRevision < metadataRevision,
                   case .value(let folderID) = rebasedFolderID {
                    persistedContent.folderID = folderID
                }
                if pending.map({ EditableScriptContent($0.document) }) == persistedContent {
                    pending = nil
                }
                state = pending == nil ? .saved : .saving
            } else {
                // Keep the newest value if the user typed during the failed write;
                // otherwise retain the failed value so Retry or an exit flush can
                // make another attempt without losing the draft.
                if pending == nil { pending = request }
                state = .failed
                break
            }
        }
        saveLoop = nil
    }
}

private struct EditableScriptContent: Equatable {
    let title: String
    let body: String
    let source: ScriptSource
    var folderID: UUID?
    let tags: [String]
    let outline: [OutlinePoint]

    init(_ document: ScriptDocument) {
        title = document.title
        body = document.body
        source = document.source
        folderID = document.folderID
        tags = document.tags
        outline = document.outline
    }

    mutating func apply(_ metadata: LibraryEditorDocumentMetadataChange) {
        if case .folderID(let folderID) = metadata {
            self.folderID = folderID
        }
    }
}

enum EditorExternalChangeDecision: Equatable {
    case ignore
    case replace(ScriptDocument?)
    case rebase(LibraryEditorDocumentMetadataChange)
}

enum EditorExternalChangePolicy {
    static func decision(
        for change: LibraryEditorDocumentChange,
        editorOriginID: UUID
    ) -> EditorExternalChangeDecision {
        guard change.editorOriginID != editorOriginID else { return .ignore }
        switch change.scope {
        case .replacement:
            return .replace(change.document)
        case .metadata(let metadata):
            return .rebase(metadata)
        }
    }
}

enum EditorDraftObservationPolicy {
    static func shouldStage(suppressNextChange: inout Bool) -> Bool {
        guard suppressNextChange else { return true }
        suppressNextChange = false
        return false
    }
}

struct EditorOpenTransitionState: Equatable {
    private(set) var deferredScriptID: UUID?

    func shouldAttemptOpen(currentScriptID: UUID?, requestedScriptID: UUID) -> Bool {
        currentScriptID != requestedScriptID
    }

    mutating func registerFailedFlush(
        currentScriptID: UUID?,
        requestedScriptID: UUID
    ) -> UUID? {
        guard let currentScriptID, currentScriptID != requestedScriptID else {
            return nil
        }
        deferredScriptID = requestedScriptID
        return currentScriptID
    }

    mutating func consumeDeferredOpenAfterSuccessfulRetry() -> UUID? {
        defer { deferredScriptID = nil }
        return deferredScriptID
    }

    mutating func completedOpen() {
        deferredScriptID = nil
    }
}

struct EditorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case script = "Script"
        case outline = "Outline"
        var id: Self { self }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    let scriptID: UUID
    let requestSelection: (UUID) -> Void
    @State private var draft: ScriptDocument?
    @State private var autosave: EditorAutosaveController?
    @State private var tab: Tab = .script
    @State private var shareURL: URL?
    @State private var showingFindReplace = false
    @State private var showingInsights = false
    @State private var findLinePresented = false
    @State private var findLineQuery = ""
    @State private var findLineStatus: String?
    @State private var findLineFromOffset = 0
    @State private var findLineJump: FindLineJumpRequest?
    @FocusState private var findLineFieldFocused: Bool
    @State private var editorOriginID = UUID()
    @State private var suppressNextDraftChange = false
    @State private var openGeneration = UUID()
    @State private var openTransition = EditorOpenTransitionState()
    @State private var readerRequest: EditorPresentationRequest?
    @State private var outlineRequest: EditorPresentationRequest?

    init(
        scriptID: UUID,
        requestSelection: @escaping (UUID) -> Void = { _ in }
    ) {
        self.scriptID = scriptID
        self.requestSelection = requestSelection
    }

    var body: some View {
        Group {
            if let draftBinding = Binding($draft) {
                editor(draftBinding)
            } else {
                ContentUnavailableView("Script not found", systemImage: "exclamationmark.document")
            }
        }
        .background(PhrasaDesign.canvas)
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scriptID) {
            guard openTransition.shouldAttemptOpen(
                currentScriptID: draft?.id,
                requestedScriptID: scriptID
            ) else { return }
            let generation = UUID()
            openGeneration = generation
            // NavigationSplitView can reuse this view while the selection changes.
            // Finish the previous document before replacing its draft/controller.
            // A failed flush deliberately leaves the old draft and Retry control
            // visible instead of silently throwing those edits away.
            if let autosave {
                let didFlush = await autosave.flush()
                guard !Task.isCancelled, openGeneration == generation else { return }
                if !didFlush {
                    if let recoveryID = openTransition.registerFailedFlush(
                        currentScriptID: draft?.id,
                        requestedScriptID: scriptID
                    ) {
                        requestSelection(recoveryID)
                    }
                    return
                }
            }
            guard !Task.isCancelled, openGeneration == generation else { return }
            // Capture the persisted open timestamp in the editor baseline so a
            // later content save cannot accidentally restore the older value.
            await library.markOpened(scriptID)
            guard !Task.isCancelled, openGeneration == generation else { return }
            let loaded = library.script(id: scriptID)
            replaceEditorDocument(with: loaded, cancelPending: false)
            openTransition.completedOpen()
        }
        .onChange(of: draft) { _, updated in
            guard EditorDraftObservationPolicy.shouldStage(
                suppressNextChange: &suppressNextDraftChange
            ) else { return }
            guard let updated else { return }
            library.stageEditorDraft(updated, editorOriginID: editorOriginID)
            autosave?.record(updated)
        }
        .onChange(of: library.editorDocumentChange(id: scriptID)) { _, change in
            guard let change else { return }
            applyEditorDocumentChange(change)
        }
        .onDisappear { flushPendingEdits() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPendingEdits() }
        }
        .fullScreenCover(item: $readerRequest) { request in
            ReaderView(script: request.script)
                .id(request.id)
                .interactiveDismissDisabled(true)
        }
        .fullScreenCover(item: $outlineRequest) { request in
            OutlineReaderView(script: request.script)
                .id(request.id)
                .interactiveDismissDisabled(true)
        }
        .sheet(
            isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )
        ) {
            if let shareURL { ActivityShareSheet(items: [shareURL]) }
        }
    }

    @ViewBuilder
    private func editor(_ draft: Binding<ScriptDocument>) -> some View {
        VStack(spacing: 0) {
            Picker("Editor section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if findLinePresented {
                findLineBar(body: draft.wrappedValue.body)
            }

            if tab == .script {
                ScriptEditor(
                    draft: draft,
                    findLineJump: findLineJump,
                    saveState: autosave?.state ?? .saved,
                    onRetrySave: retrySave
                )
            } else {
                OutlineEditor(points: draft.outline)
            }
        }
        .navigationTitle(draft.wrappedValue.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Quiet Saved/Saving lives with the script name field. Keep a
                // failed retry in the toolbar so Outline tab still offers it.
                if autosave?.state == .failed, tab != .script {
                    Button(autosave?.state.label ?? "Retry save") {
                        retrySave()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PhrasaDesign.danger)
                    .accessibilityHint("Attempts to save the latest edits again")
                }
                if !draft.wrappedValue.outline.isEmpty {
                    Button { presentAfterSaving(.outline) } label: {
                        Label("Present outline", systemImage: "list.bullet.rectangle")
                    }
                }
                Button { presentAfterSaving(.reader) } label: {
                    Label("Open prompter", systemImage: "play.fill")
                }
                .accessibilityIdentifier(PhrasaA11y.Editor.openPrompter)
                .disabled(draft.wrappedValue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu {
                    Button { openFindLine() } label: {
                        Label("Find a line", systemImage: "text.magnifyingglass")
                    }
                    // A bare slash belongs to the script while a text editor is
                    // focused. Command-/ remains a fast, non-destructive shortcut.
                    .keyboardShortcut("/", modifiers: [.command])
                    Button { showingFindReplace = true } label: {
                        Label("Find & replace", systemImage: "text.magnifyingglass")
                    }
                    Button { showingInsights = true } label: {
                        Label("Document insights", systemImage: "chart.bar.doc.horizontal")
                    }
                    Divider()
                    Button { export(draft.wrappedValue, asJSON: false) } label: {
                        Label("Share as text", systemImage: "doc.plaintext")
                    }
                    Button { export(draft.wrappedValue, asJSON: true) } label: {
                        Label("Share as Phrasa JSON", systemImage: "curlybraces")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingFindReplace) {
            FindReplaceSheet(text: draft.body)
        }
        .sheet(isPresented: $showingInsights) {
            DocumentInsightsSheet(
                text: draft.wrappedValue.body,
                wordsPerMinute: library.settings.speedWPM
            )
        }
    }

    private func findLineBar(body: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PhrasaDesign.muted)
                .accessibilityHidden(true)
            TextField("Find a line…", text: $findLineQuery)
                .textFieldStyle(.plain)
                .foregroundStyle(PhrasaDesign.ink)
                .focused($findLineFieldFocused)
                .submitLabel(.search)
                .onSubmit { performFindLine(in: body) }
                .accessibilityLabel("Find a line")
                .accessibilityHint("Search the script for a line of text")
            Button("Find") { performFindLine(in: body) }
                .buttonStyle(PhrasaSecondaryButtonStyle())
                .frame(maxWidth: 100)
                .accessibilityLabel("Find next match")
            Button("Done") {
                findLinePresented = false
                findLineStatus = nil
                findLineQuery = ""
                findLineFromOffset = 0
                findLineJump = nil
            }
            .foregroundStyle(PhrasaDesign.ink)
            .accessibilityLabel("Close find a line")
            if let findLineStatus {
                Text(findLineStatus)
                    .font(.caption)
                    .foregroundStyle(PhrasaDesign.muted)
                    .accessibilityLabel(findLineStatus)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: PhrasaDesign.minTouchTarget)
        .background(PhrasaDesign.elevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PhrasaDesign.border).frame(height: 1)
        }
        .onAppear { findLineFieldFocused = true }
    }

    private func openFindLine() {
        findLinePresented = true
        findLineStatus = nil
        findLineFieldFocused = true
    }

    private func performFindLine(in body: String) {
        let outcome = FindLineJumpPresentation.perform(
            body: body,
            query: findLineQuery,
            fromUTF16Offset: findLineFromOffset
        )
        findLineFromOffset = outcome.fromOffset
        findLineStatus = outcome.status
        findLineJump = outcome.jump
        UIAccessibility.post(notification: .announcement, argument: outcome.announcement)
    }

    private enum PresentationDestination { case reader, outline }

    private struct EditorPresentationRequest: Identifiable {
        let id = UUID()
        let script: ScriptDocument
    }

    private func makeAutosave(initial: ScriptDocument) -> EditorAutosaveController {
        let originID = editorOriginID
        return EditorAutosaveController(initial: initial) { document in
            await library.update(document, editorOriginID: originID)
        }
    }

    private func applyEditorDocumentChange(_ change: LibraryEditorDocumentChange) {
        switch EditorExternalChangePolicy.decision(
            for: change,
            editorOriginID: editorOriginID
        ) {
        case .ignore:
            return
        case .replace(let replacement):
            replaceEditorDocument(with: replacement, cancelPending: true)
        case .rebase(let metadata):
            autosave?.rebase(metadata)
            guard var revised = draft else { return }
            metadata.apply(to: &revised)
            guard revised != draft else { return }
            suppressNextDraftChange = true
            draft = revised
        }
    }

    private func replaceEditorDocument(
        with replacement: ScriptDocument?,
        cancelPending: Bool
    ) {
        if cancelPending { autosave?.cancelPending() }
        if draft != replacement {
            suppressNextDraftChange = true
            draft = replacement
        }
        autosave = replacement.map { makeAutosave(initial: $0) }
    }

    private func presentAfterSaving(_ destination: PresentationDestination) {
        Task { @MainActor in
            if let autosave, !(await autosave.flush()) {
                // The save-status control remains actionable; presenting a stale
                // durable copy would make the editor look as if the edit succeeded.
                return
            }
            guard let snapshot = draft else { return }
            switch destination {
            case .reader:
                readerRequest = EditorPresentationRequest(script: snapshot)
            case .outline:
                outlineRequest = EditorPresentationRequest(script: snapshot)
            }
        }
    }

    private func retrySave() {
        guard let autosave else { return }
        autosave.retry()
        Task { @MainActor in
            guard await autosave.flush(), self.autosave === autosave else { return }
            if let deferredID = openTransition.consumeDeferredOpenAfterSuccessfulRetry() {
                requestSelection(deferredID)
            }
        }
    }

    private func flushPendingEdits() {
        guard let autosave else { return }
        Task { @MainActor in _ = await autosave.flush() }
    }

    private func export(_ script: ScriptDocument, asJSON: Bool) {
        do {
            let service = ScriptExportService()
            let document: ExportedDocument
            if asJSON {
                document = try service.scriptJSON(script: script)
            } else {
                document = service.plainText(script: script)
            }
            shareURL = try document.temporaryURL()
        } catch {
            library.report(error)
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        // iPad regular size class: never rely on a missing popover sourceView.
        // FormSheet is valid without an anchor; popover without source can no-op/crash.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIView()
            popover.permittedArrowDirections = []
        }
        controller.modalPresentationStyle = .formSheet
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Stable chrome rules for the iOS script editor name row.
/// Keeps title + save-status placement testable without mounting SwiftUI.
enum EditorChromePresentation {
    /// Save status sits on the same row as the editable script name, trailing.
    static let saveStatusBesideTitle = true
    /// Idle "Saved" is quiet caption text; failed is a tappable retry control.
    static let saveStatusUsesQuietCaption = true
    static let titleAccessibilityLabel = "Script title"
}

private struct ScriptEditor: View {
    @Environment(LibraryStore.self) private var library
    @Binding var draft: ScriptDocument
    var findLineJump: FindLineJumpRequest?
    var saveState: EditorSaveState = .saved
    var onRetrySave: (() -> Void)?
    @State private var newTag = ""

    private var folderName: String {
        guard let folderID = draft.folderID,
              let folder = library.folders.first(where: { $0.id == folderID }) else {
            return "No folder"
        }
        return folder.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Untitled script", text: $draft.title)
                    .font(.system(.title, design: .default, weight: .semibold))
                    .foregroundStyle(PhrasaDesign.ink)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(EditorChromePresentation.titleAccessibilityLabel)

                saveStatusControl
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            HStack(spacing: 12) {
                MetricLabel(words: draft.wordCount, duration: draft.estimatedDuration)
                Spacer()
                Menu {
                    Button {
                        draft.folderID = nil
                    } label: {
                        Label("No folder", systemImage: draft.folderID == nil ? "checkmark" : "tray")
                    }
                    ForEach(library.folders) { folder in
                        Button {
                            draft.folderID = folder.id
                        } label: {
                            Label(folder.name, systemImage: draft.folderID == folder.id ? "checkmark" : "folder")
                        }
                    }
                } label: {
                    Label(folderName, systemImage: draft.folderID == nil ? "tray" : "folder")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PhrasaDesign.muted)
                        .lineLimit(1)
                        .frame(minHeight: 32)
                }
                .accessibilityLabel("Folder, \(folderName)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(draft.tags, id: \.self) { tag in
                        Button {
                            draft.tags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: 4) {
                                Text("#\(tag)")
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PhrasaDesign.ink)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(PhrasaDesign.surfaceSecondary, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
                            .overlay {
                                RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                                    .stroke(PhrasaDesign.border, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                    if draft.tags.count < 12 {
                        TextField("Add tag", text: $newTag)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .frame(width: 110, height: 32)
                            .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
                            .overlay {
                                RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                                    .stroke(PhrasaDesign.border, lineWidth: 1)
                            }
                            .submitLabel(.done)
                            .onSubmit(addTag)
                            .accessibilityHint("Press return to add this tag")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            Rectangle().fill(PhrasaDesign.divider).frame(height: 1)
            ScriptBodyTextEditor(text: $draft.body, jumpRequest: findLineJump)
                .padding(.horizontal, 14)
        }
        .background(PhrasaDesign.canvas)
    }

    @ViewBuilder
    private var saveStatusControl: some View {
        if saveState == .failed {
            Button(saveState.label) {
                onRetrySave?()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PhrasaDesign.danger)
            .accessibilityLabel(saveState.label)
            .accessibilityHint("Attempts to save the latest edits again")
        } else {
            Text(saveState.label)
                .font(.caption)
                .foregroundStyle(PhrasaDesign.muted)
                .accessibilityLabel(saveState.label)
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
        guard !tag.isEmpty, !draft.tags.contains(tag), draft.tags.count < 12 else { return }
        draft.tags.append(tag)
        newTag = ""
    }
}
