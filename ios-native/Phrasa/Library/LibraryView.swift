import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    enum SortOption: String, CaseIterable, Identifiable {
        case recentlyUpdated = "Recently updated"
        case recentlyOpened = "Recently opened"
        case title = "Title A–Z"
        case longest = "Longest first"
        var id: Self { self }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(CloudAccountSyncRuntime.self) private var accountSync
    @State private var query = ""
    @State private var selectedScriptID: UUID?
    @State private var deletionCandidate: ScriptDocument?
    @State private var showingImporter = false
    @State private var showingBackupImporter = false
    @State private var pendingBackup: LibrarySnapshot?
    @State private var showingRestoreConfirmation = false
    @State private var selectedFolderID: UUID?
    @State private var sortOption: SortOption = .recentlyUpdated
    @State private var showingFolderEditor = false
    @State private var editingFolder: ScriptFolder?
    @State private var folderDeletionCandidate: ScriptFolder?
    @State private var folderName = ""
    @State private var shareURL: URL?
    @State private var showingAccountSync = false

    private var selectedFolder: ScriptFolder? {
        guard let selectedFolderID else { return nil }
        return library.folders.first { $0.id == selectedFolderID }
    }

    private var selectedScript: ScriptDocument? {
        guard let selectedScriptID else { return nil }
        return library.scripts.first { $0.id == selectedScriptID }
    }

    private var filteredScripts: [ScriptDocument] {
        var results = selectedFolderID.map { id in library.scripts.filter { $0.folderID == id } } ?? library.scripts
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return sorted(results) }
        let term = query.lowercased()
        if term.hasPrefix("#") {
            let tag = String(term.dropFirst())
            results = results.filter { $0.tags.contains(where: { $0.lowercased().contains(tag) }) }
        } else {
            results = results.filter {
                $0.title.lowercased().contains(term)
                    || $0.preview.lowercased().contains(term)
                    || $0.tags.contains(where: { $0.lowercased().contains(term) })
            }
        }
        return sorted(results)
    }

    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching scripts" }
        if selectedFolder != nil { return "This folder is empty" }
        return "No scripts yet"
    }

    private var emptyDescription: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try another title, phrase, or #tag."
        }
        if let selectedFolder { return "Add a new script to \(selectedFolder.name), or move one here from its menu." }
        return "Create a script or import a file to begin."
    }

    private func sorted(_ scripts: [ScriptDocument]) -> [ScriptDocument] {
        scripts.sorted { lhs, rhs in
            switch sortOption {
            case .recentlyUpdated: lhs.updatedAt > rhs.updatedAt
            case .recentlyOpened: (lhs.lastOpenedAt ?? .distantPast) > (rhs.lastOpenedAt ?? .distantPast)
            case .title: lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .longest: lhs.wordCount > rhs.wordCount
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            libraryColumn
                .navigationTitle(selectedFolder?.name ?? "Scripts")
                .toolbar { libraryToolbar }
                .searchable(text: $query, prompt: "Search scripts or #tags")
                .accessibilityIdentifier(PhrasaA11y.Library.scriptsRoot)
                .navigationDestination(for: ScriptDocument.self) { script in
                    EditorView(scriptID: script.id)
                }
        } detail: {
            ZStack {
                PhrasaDesign.canvas.ignoresSafeArea()
                if let selectedScript {
                    EditorView(
                        scriptID: selectedScript.id,
                        requestSelection: { selectedScriptID = $0 }
                    )
                } else {
                    ContentUnavailableView(
                        "Select a script",
                        systemImage: "doc.plaintext",
                        description: Text("Choose a script from your library to edit or present it.")
                    )
                    .foregroundStyle(PhrasaDesign.muted)
                }
            }
        }
        .tint(PhrasaDesign.ink)
        .preferredColorScheme(.dark)
        .onChange(of: filteredScripts.map(\.id), initial: true) { _, ids in
            selectedScriptID = LibrarySelectionPolicy.retainedSelection(
                selectedScriptID,
                availableIDs: ids
            )
        }
        .onChange(of: library.folders.map(\.id), initial: true) { _, ids in
            selectedFolderID = LibrarySelectionPolicy.retainedSelection(
                selectedFolderID,
                availableIDs: ids
            )
        }
        .sheet(
            isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )
        ) {
            if let shareURL { ActivityShareSheet(items: [shareURL]) }
        }
        .alert(editingFolder == nil ? "New folder" : "Rename folder", isPresented: $showingFolderEditor) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { resetFolderEditor() }
            Button(editingFolder == nil ? "Create" : "Save") { commitFolderEditor() }
        } message: {
            Text(editingFolder == nil
                 ? "Folders keep larger libraries easy to scan."
                 : "Choose a short name that is easy to spot in your library.")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [
                .plainText,
                .pdf,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "markdown") ?? .plainText
            ]
        ) { result in
            do {
                let url = try result.get()
                var script = try ScriptImportService().importFile(at: url)
                script.folderID = selectedFolderID
                Task {
                    selectedScriptID = await library.addImported(script)?.id
                }
            } catch {
                library.report(error)
            }
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [.json]
        ) { result in
            do {
                pendingBackup = try LibraryBackupImportService().importFile(at: result.get())
                showingRestoreConfirmation = true
            } catch {
                library.report(error)
            }
        }
        .confirmationDialog(
            LibraryRestorePrompt.title,
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Merge with this library") { restoreBackup(.merge) }
            Button("Replace this library", role: .destructive) { restoreBackup(.replace) }
            Button("Cancel", role: .cancel) {
                showingRestoreConfirmation = false
                pendingBackup = nil
            }
        } message: {
            Text(LibraryRestorePrompt.message(for: pendingBackup))
        }
        .confirmationDialog(
            "Delete “\(deletionCandidate?.title ?? "script")”?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                guard let id = deletionCandidate?.id else { return }
                deletionCandidate = nil
                if selectedScriptID == id { selectedScriptID = nil }
                Task { await library.delete(id) }
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete folder “\(folderDeletionCandidate?.name ?? "folder")”?",
            isPresented: Binding(
                get: { folderDeletionCandidate != nil },
                set: { if !$0 { folderDeletionCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete folder", role: .destructive) {
                guard let folder = folderDeletionCandidate else { return }
                folderDeletionCandidate = nil
                if selectedFolderID == folder.id { selectedFolderID = nil }
                Task { await library.deleteFolder(folder.id) }
            }
            Button("Cancel", role: .cancel) { folderDeletionCandidate = nil }
        } message: {
            Text("The scripts will stay in your library and move to No folder.")
        }
        .sheet(isPresented: $showingAccountSync) {
            NavigationStack {
                CloudAccountView(runtime: accountSync)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingAccountSync = false }
                        }
                    }
            }
        }
    }

    private var libraryColumn: some View {
        ZStack {
            PhrasaDesign.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                if let selectedFolder {
                    ActiveFolderBanner(
                        name: selectedFolder.name,
                        scriptCount: library.scripts.lazy.filter { $0.folderID == selectedFolder.id }.count,
                        clear: { selectedFolderID = nil },
                        rename: { beginRenaming(selectedFolder) }
                    )
                }

                if filteredScripts.isEmpty {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: query.isEmpty ? "doc.plaintext" : "magnifyingglass",
                            description: Text(emptyDescription)
                        )
                        .foregroundStyle(PhrasaDesign.muted)
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                Task {
                                    selectedScriptID = await library.createScript(
                                        folderID: selectedFolderID
                                    )?.id
                                }
                            } label: {
                                Text("Create a script")
                                    .frame(maxWidth: 280)
                            }
                            .buttonStyle(PhrasaPrimaryButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(selection: $selectedScriptID) {
                        ForEach(filteredScripts) { script in
                            NavigationLink(value: script) {
                                ScriptRow(script: script)
                            }
                            .tag(script.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deletionCandidate = script } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { Task { await library.duplicate(script.id) } } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                .tint(PhrasaDesign.muted)
                            }
                            .contextMenu {
                                moveMenu(for: script)
                                Button { Task { await library.duplicate(script.id) } } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                Button(role: .destructive) { deletionCandidate = script } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Section("Library") {
                    Button { exportBackup() } label: {
                        Label("Export complete backup", systemImage: "square.and.arrow.up")
                    }
                    Button { showingBackupImporter = true } label: {
                        Label("Restore Phrasa backup", systemImage: "arrow.counterclockwise.icloud")
                    }
                    Button { showingAccountSync = true } label: {
                        Label("Account & sync", systemImage: "person.crop.circle")
                    }
                }
                Section("About") {
                    ForEach(LibraryOptionsLegalPresentation.destinations) { destination in
                        Link(destination: destination.url) {
                            Label(destination.title, systemImage: destination.systemImage)
                        }
                    }
                }
                Section("View") {
                    Button { selectedFolderID = nil } label: {
                        Label("All scripts", systemImage: selectedFolderID == nil ? "checkmark" : "tray.full")
                    }
                    ForEach(library.folders) { folder in
                        Button { selectedFolderID = folder.id } label: {
                            Label(folder.name, systemImage: selectedFolderID == folder.id ? "checkmark" : "folder")
                        }
                    }
                    Button { beginCreatingFolder() } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                }
                if let selectedFolder {
                    Section(selectedFolder.name) {
                        Button { beginRenaming(selectedFolder) } label: {
                            Label("Rename folder", systemImage: "pencil")
                        }
                        Button(role: .destructive) { folderDeletionCandidate = selectedFolder } label: {
                            Label("Delete folder", systemImage: "trash")
                        }
                    }
                }
                Section("Sort") {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            } label: {
                Label("Library options", systemImage: selectedFolder == nil ? "line.3.horizontal.decrease.circle" : "folder.fill")
            }
            .accessibilityLabel("Library options")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task {
                        selectedScriptID = await library.createScript(
                            folderID: selectedFolderID
                        )?.id
                    }
                } label: {
                    Label("Blank script", systemImage: "square.and.pencil")
                }
                Button { showingImporter = true } label: {
                    Label("Import from Files", systemImage: "doc.badge.plus")
                }
                Divider()
                Button { beginCreatingFolder() } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityLabel("Add script or folder")
        }
    }

    @ViewBuilder
    private func moveMenu(for script: ScriptDocument) -> some View {
        Menu {
            Button {
                Task { await library.moveScript(script.id, to: nil) }
            } label: {
                Label("No folder", systemImage: script.folderID == nil ? "checkmark" : "tray")
            }
            ForEach(library.folders) { folder in
                Button {
                    Task { await library.moveScript(script.id, to: folder.id) }
                } label: {
                    Label(folder.name, systemImage: script.folderID == folder.id ? "checkmark" : "folder")
                }
            }
        } label: {
            Label("Move to folder", systemImage: "folder")
        }
    }

    private func beginCreatingFolder() {
        editingFolder = nil
        folderName = ""
        showingFolderEditor = true
    }

    private func beginRenaming(_ folder: ScriptFolder) {
        editingFolder = folder
        folderName = folder.name
        showingFolderEditor = true
    }

    private func resetFolderEditor() {
        showingFolderEditor = false
        editingFolder = nil
        folderName = ""
    }

    private func commitFolderEditor() {
        let name = folderName
        let folder = editingFolder
        resetFolderEditor()
        Task {
            if let folder {
                await library.renameFolder(folder.id, to: name)
            } else if let created = await library.createFolder(name: name) {
                selectedFolderID = created.id
            }
        }
    }

    private func exportBackup() {
        do {
            let document = try ScriptExportService().libraryBackup(snapshot: library.exportSnapshot())
            shareURL = try document.temporaryURL()
        } catch {
            library.report(error)
        }
    }

    private func restoreBackup(_ mode: LibraryStore.RestoreMode) {
        guard let backup = pendingBackup else { return }
        showingRestoreConfirmation = false
        Task {
            if await library.restore(backup, mode: mode) {
                pendingBackup = nil
                selectedFolderID = nil
                selectedScriptID = nil
            } else {
                showingRestoreConfirmation = true
            }
        }
    }
}

enum LibrarySelectionPolicy {
    static func retainedSelection(
        _ selectedID: UUID?,
        availableIDs: [UUID]
    ) -> UUID? {
        guard let selectedID, availableIDs.contains(selectedID) else { return nil }
        return selectedID
    }
}

enum LibraryRestorePrompt {
    static let title = "Restore backup?"

    static func message(for backup: LibrarySnapshot?) -> String {
        let scriptCount = backup?.scripts.count ?? 0
        let folderCount = backup?.folders.count ?? 0
        let scripts = "\(scriptCount) \(scriptCount == 1 ? "script" : "scripts")"
        let folders = "\(folderCount) \(folderCount == 1 ? "folder" : "folders")"
        return "This backup contains \(scripts) and \(folders). Merge keeps your current library and adds newer backup copies. Replace removes the current library first."
    }
}

private struct ActiveFolderBanner: View {
    let name: String
    let scriptCount: Int
    let clear: () -> Void
    let rename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(PhrasaDesign.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhrasaDesign.ink)
                    .lineLimit(1)
                Text("\(scriptCount) \(scriptCount == 1 ? "script" : "scripts")")
                    .font(.caption)
                    .foregroundStyle(PhrasaDesign.muted)
            }
            Spacer()
            Button("Rename", action: rename)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PhrasaDesign.ink)
                .frame(minHeight: PhrasaDesign.minTouchTarget)
            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PhrasaDesign.muted)
                    .phrasaTouchTarget()
            }
            .accessibilityLabel("Show all scripts")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PhrasaDesign.elevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PhrasaDesign.divider).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ScriptRow: View {
    let script: ScriptDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(script.title)
                    .font(.headline)
                    .foregroundStyle(PhrasaDesign.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !script.outline.isEmpty {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(PhrasaDesign.muted)
                        .accessibilityLabel("Has outline")
                }
            }
            Text(script.preview.isEmpty ? "No text yet" : script.preview)
                .font(.subheadline)
                .foregroundStyle(PhrasaDesign.muted)
                .lineLimit(2)
            HStack(spacing: 10) {
                MetricLabel(words: script.wordCount, duration: script.estimatedDuration)
                Spacer()
                if let first = script.tags.first {
                    Text("#\(first)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PhrasaDesign.muted)
                        .lineLimit(1)
                }
                Text(script.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(PhrasaDesign.muted)
            }
        }
        .padding(14)
        .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
                .stroke(PhrasaDesign.border, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
