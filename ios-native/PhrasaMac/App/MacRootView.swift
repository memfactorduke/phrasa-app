import AppKit
import SwiftUI
import PhrasaDomain

struct MacRootView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var appModel = appModel
        Group {
            if library.isLoaded {
                MacWorkspaceView()
            } else if library.canStartFreshAfterCorruption {
                MacRecoveryView()
            } else if let error = library.errorMessage {
                MacLoadErrorView(message: error)
            } else {
                ProgressView("Opening library…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MacDesign.canvas)
                    .foregroundStyle(MacDesign.ink)
            }
        }
        .preferredColorScheme(.dark)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { library.errorMessage != nil && library.isLoaded },
                set: { if !$0 { library.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { library.clearError() }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .sheet(isPresented: $appModel.showShortcutsHelp) {
            MacShortcutsHelpView()
        }
        .onChange(of: appModel.readerRequest?.id) { _, newValue in
            if newValue != nil {
                openWindow(id: MacWindowID.reader)
            }
        }
        .onChange(of: appModel.outlineRequest?.id) { _, newValue in
            if newValue != nil {
                openWindow(id: MacWindowID.outline)
            }
        }
        .overlay(alignment: .bottom) {
            if let status = appModel.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(MacDesign.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(MacDesign.elevated, in: RoundedRectangle(cornerRadius: MacDesign.controlRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: MacDesign.controlRadius)
                            .stroke(MacDesign.border, lineWidth: 1)
                    }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(2.5))
                            withAnimation(MacDesign.motion(reduceMotion: reduceMotion)) {
                                appModel.statusMessage = nil
                            }
                        }
                    }
            }
        }
        .animation(MacDesign.motion(reduceMotion: reduceMotion), value: appModel.statusMessage)
    }
}

struct MacWorkspaceView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationSplitView {
            MacSidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 280)
        } content: {
            MacScriptListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            if let id = appModel.selectedScriptID,
               let script = library.script(id: id) {
                MacEditorView(scriptID: script.id)
            } else {
                MacEmptyDetailView()
            }
        }
        .background(MacDesign.canvas)
        .tint(MacDesign.ink)
    }
}

struct MacSidebarView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        List(selection: $appModel.selectedFolderID) {
            Section("Library") {
                Label("All Scripts", systemImage: "tray.full")
                    .tag(Optional<UUID>.none)
                    .accessibilityLabel("All scripts")
            }
            Section("Folders") {
                ForEach(library.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .tag(Optional(folder.id))
                        .contextMenu {
                            Button("Rename…") {
                                renameFolder(folder)
                            }
                            Button("Delete Folder", role: .destructive) {
                                Task { await library.deleteFolder(folder.id) }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Phrasa")
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        _ = await library.createFolder(name: "Untitled folder")
                    }
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("Create a new folder")
            }
        }
    }

    private func renameFolder(_ folder: ScriptFolder) {
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        alert.informativeText = "Enter a new name for this folder."
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                _ = await library.renameFolder(folder.id, to: field.stringValue)
            }
        }
    }
}

struct MacScriptListView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel

    private var scripts: [ScriptDocument] {
        library.filteredScripts(
            search: appModel.searchText,
            folderFilter: appModel.selectedFolderID
        )
    }

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MacDesign.muted)
                    .accessibilityHidden(true)
                TextField("Search scripts or #tag", text: $appModel.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search scripts")
            }
            .padding(10)
            .background(MacDesign.elevated)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MacDesign.border).frame(height: 1)
            }

            List(selection: $appModel.selectedScriptID) {
                ForEach(scripts) { script in
                    MacScriptRow(script: script)
                        .tag(script.id)
                        .contextMenu {
                            Button("Present") {
                                Task { await appModel.requestReader(scriptID: script.id) }
                            }
                            Button("Duplicate") {
                                Task {
                                    if let copy = await library.duplicate(script.id) {
                                        appModel.selectedScriptID = copy.id
                                    }
                                }
                            }
                            Menu("Move to Folder") {
                                Button("No Folder") {
                                    Task { _ = await library.moveScript(script.id, to: nil) }
                                }
                                ForEach(library.folders) { folder in
                                    Button(folder.name) {
                                        Task { _ = await library.moveScript(script.id, to: folder.id) }
                                    }
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                confirmDelete(script)
                            }
                        }
                }
            }
            .listStyle(.inset)
            .onChange(of: scripts.map(\.id), initial: true) { _, visibleIDs in
                if let selected = appModel.selectedScriptID,
                   !visibleIDs.contains(selected) {
                    appModel.selectedScriptID = nil
                }
            }
        }
        .navigationTitle(folderTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task {
                        if let created = await library.createScript(
                            folderID: appModel.selectedFolderID
                        ) {
                            appModel.selectedScriptID = created.id
                        }
                    }
                } label: {
                    Label("New Script", systemImage: "square.and.pencil")
                }
                .help("Create a new script")

                if let id = appModel.selectedScriptID {
                    Button {
                        Task { await appModel.requestReader(scriptID: id) }
                    } label: {
                        Label("Present", systemImage: "play.rectangle")
                    }
                    .help("Open full-screen speed reader")
                }
            }
        }
    }

    private var folderTitle: String {
        if let id = appModel.selectedFolderID,
           let folder = library.folders.first(where: { $0.id == id }) {
            return folder.name
        }
        return "Scripts"
    }

    private func confirmDelete(_ script: ScriptDocument) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(script.title)”?"
        alert.informativeText = "This removes the script from your offline library. You can restore it later from a backup."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await library.delete(script.id)
                if appModel.selectedScriptID == script.id {
                    appModel.selectedScriptID = nil
                }
            }
        }
    }
}

struct MacScriptRow: View {
    let script: ScriptDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(script.title)
                .font(.body.weight(.medium))
                .foregroundStyle(MacDesign.ink)
                .lineLimit(1)
            Text(script.preview)
                .font(.caption)
                .foregroundStyle(MacDesign.muted)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("\(script.wordCount) words")
                if !script.tags.isEmpty {
                    Text(script.tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                }
            }
            .font(.caption2)
            .foregroundStyle(MacDesign.muted)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(script.title), \(script.wordCount) words")
    }
}

struct MacEmptyDetailView: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel

    var body: some View {
        ContentUnavailableView {
            Label("No Script Selected", systemImage: "doc.text")
        } description: {
            Text("Choose a script from the list, or create a new one. Everything stays offline on this Mac.")
        } actions: {
            Button("New Script") {
                Task {
                    if let created = await library.createScript(
                        folderID: appModel.selectedFolderID
                    ) {
                        appModel.selectedScriptID = created.id
                    }
                }
            }
            .keyboardShortcut("n", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacDesign.canvas)
        .foregroundStyle(MacDesign.ink)
    }
}

struct MacLoadErrorView: View {
    @Environment(MacLibraryStore.self) private var library
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Library Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await library.load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacDesign.canvas)
    }
}

struct MacRecoveryView: View {
    @Environment(MacLibraryStore.self) private var library

    var body: some View {
        ContentUnavailableView {
            Label("Library Needs Recovery", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(library.errorMessage ?? "Phrasa found a damaged offline library. You can preserve the damaged files and start a fresh library.")
        } actions: {
            Button("Start Fresh Library") {
                Task { _ = await library.startFreshAfterCorruption() }
            }
            .buttonStyle(.borderedProminent)
            Button("Show Error Again") {
                library.redisplayRecoverableLoadError()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacDesign.canvas)
    }
}

struct MacShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard & Clicker")
                .font(.title2.weight(.semibold))
                .foregroundStyle(MacDesign.ink)
            Text("Speed prompting is the reliable Mac mode. Voice following ships later when the speech adapter meets the same reliability gates as iOS.")
                .font(.callout)
                .foregroundStyle(MacDesign.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(MacReaderCommand.documentedMappings, id: \.command) { mapping in
                    HStack {
                        Text(mapping.keys)
                            .font(.body.monospaced())
                            .frame(width: 72, alignment: .leading)
                            .foregroundStyle(MacDesign.ink)
                        Text(mapping.note)
                            .foregroundStyle(MacDesign.muted)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(mapping.keys): \(mapping.note)")
                }
            }
            .padding(12)
            .background(MacDesign.elevated, in: RoundedRectangle(cornerRadius: MacDesign.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: MacDesign.cardRadius)
                    .stroke(MacDesign.border, lineWidth: 1)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(MacDesign.canvas)
    }
}
