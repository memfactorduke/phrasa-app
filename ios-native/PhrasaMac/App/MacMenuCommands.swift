import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PhrasaDomain

struct MacMenuCommands: Commands {
    @Bindable var library: MacLibraryStore
    @Bindable var appModel: MacAppModel

    private var selectedScriptHasOutline: Bool {
        guard let id = appModel.selectedScriptID,
              let script = library.script(id: id) else { return false }
        return script.outline.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
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

            Button("New Folder…") {
                Task {
                    _ = await library.createFolder(name: "Untitled folder")
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Import…") {
                presentImportPanel()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandGroup(after: .importExport) {
            Button("Export Script as Text…") {
                exportSelectedScript(asJSON: false)
            }
            .disabled(appModel.selectedScriptID == nil)

            Button("Export Script as JSON…") {
                exportSelectedScript(asJSON: true)
            }
            .disabled(appModel.selectedScriptID == nil)

            Divider()

            Button("Back Up Library…") {
                exportLibraryBackup()
            }

            Button("Restore Library…") {
                presentRestorePanel()
            }
        }

        CommandGroup(after: .textEditing) {
            Button("Find Line…") {
                NotificationCenter.default.post(name: .macFindLineRequested, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(appModel.selectedScriptID == nil)

            // Spec input contract: bare `/` also opens find-a-line when a menu
            // accelerator can fire (text fields still consume the character).
            Button("Find Line (/)") {
                NotificationCenter.default.post(name: .macFindLineRequested, object: nil)
            }
            .keyboardShortcut("/", modifiers: [])
            .disabled(appModel.selectedScriptID == nil)
        }

        CommandMenu("Present") {
            Button("Present Script") {
                if let id = appModel.selectedScriptID {
                    Task { await appModel.requestReader(scriptID: id) }
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(appModel.selectedScriptID == nil)

            Button("Present Outline") {
                if let id = appModel.selectedScriptID {
                    Task { await appModel.requestOutline(scriptID: id) }
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(appModel.selectedScriptID == nil || !selectedScriptHasOutline)

            Divider()

            ForEach(MacReaderCommand.documentedMappings, id: \.command) { mapping in
                Text("\(mapping.keys) — \(mapping.note)")
            }
        }

        CommandGroup(replacing: .help) {
            Button("Phrasa Keyboard Shortcuts") {
                appModel.showShortcutsHelp = true
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])

            Button("Phrasa Support") {
                if let url = URL(string: "https://phrasa.app/support") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Phrasa Open Source Code") {
                if let url = URL(string: "https://github.com/memfactorduke/phrasa-app") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .plainText,
            .utf8PlainText,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            .pdf
        ]
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                let importer = MacScriptImportService()
                for url in panel.urls {
                    do {
                        let document = try importer.importFile(at: url)
                        if let saved = await library.addImported(document) {
                            appModel.selectedScriptID = saved.id
                            appModel.statusMessage = "Imported “\(saved.title)”."
                        }
                    } catch {
                        library.report(error)
                    }
                }
            }
        }
    }

    private func exportSelectedScript(asJSON: Bool) {
        guard let id = appModel.selectedScriptID,
              let script = library.script(id: id) else { return }
        let exporter = MacScriptExportService()
        do {
            let exported = asJSON
                ? try exporter.scriptJSON(script: script)
                : exporter.plainText(script: script)
            presentSavePanel(for: exported)
        } catch {
            library.report(error)
        }
    }

    private func exportLibraryBackup() {
        let exporter = MacScriptExportService()
        do {
            let exported = try exporter.libraryBackup(snapshot: library.exportSnapshot())
            presentSavePanel(for: exported)
        } catch {
            library.report(error)
        }
    }

    private func presentRestorePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let snapshot = try MacLibraryBackupImportService().importFile(at: url)
                    let alert = NSAlert()
                    alert.messageText = "Restore library backup?"
                    alert.informativeText = "Merge keeps existing scripts and adds newer ones. Replace discards the current library after the backup is verified."
                    alert.addButton(withTitle: "Merge")
                    alert.addButton(withTitle: "Replace")
                    alert.addButton(withTitle: "Cancel")
                    let choice = alert.runModal()
                    let mode: MacLibraryStore.RestoreMode
                    switch choice {
                    case .alertFirstButtonReturn: mode = .merge
                    case .alertSecondButtonReturn: mode = .replace
                    default: return
                    }
                    if await library.restore(snapshot, mode: mode) {
                        appModel.statusMessage = mode == .merge
                            ? "Library backup merged."
                            : "Library restored from backup."
                    }
                } catch {
                    library.report(error)
                }
            }
        }
    }

    private func presentSavePanel(for document: MacExportedDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try document.data.write(to: url, options: .atomic)
                Task { @MainActor in
                    appModel.statusMessage = "Saved \(document.suggestedFilename)."
                }
            } catch {
                Task { @MainActor in
                    library.report(error)
                }
            }
        }
    }
}
