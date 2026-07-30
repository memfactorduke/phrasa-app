import SwiftUI
import PhrasaDomain

@main
struct PhrasaMacApp: App {
    @State private var library = MacLibraryStore()
    @State private var appModel = MacAppModel()
    @State private var accountSync = MacCloudAccountSyncRuntime.live()

    var body: some Scene {
        WindowGroup("Phrasa") {
            MacRootView()
                .environment(library)
                .environment(appModel)
                .environment(accountSync)
                .task {
                    // Local library load is always first and never waits on network.
                    await library.load()
                    accountSync.attach(library: library)
                    accountSync.start()
                    accountSync.handleLaunch()
                }
                .onOpenURL { url in
                    Task { await accountSync.handleOpenURL(url) }
                }
                .frame(minWidth: 880, minHeight: 560)
                .background(MacDesign.canvas)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            MacMenuCommands(library: library, appModel: appModel)
        }

        Window("Reader", id: MacWindowID.reader) {
            MacReaderWindowHost()
                .environment(library)
                .environment(appModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 720)
        .commandsRemoved()

        Window("Outline", id: MacWindowID.outline) {
            MacOutlineWindowHost()
                .environment(library)
                .environment(appModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 680)
        .commandsRemoved()

        Settings {
            MacSettingsView()
                .environment(library)
                .environment(accountSync)
                .frame(minWidth: 460, minHeight: 560)
        }
    }
}

enum MacWindowID {
    static let reader = "phrasa.reader"
    static let outline = "phrasa.outline"
}

/// Cross-window presentation and action routing for the Mac app.
@MainActor
@Observable
final class MacAppModel {
    var selectedScriptID: UUID?
    var selectedFolderID: UUID?
    var searchText = ""
    private(set) var readerRequest: MacPresentationRequest?
    private(set) var outlineRequest: MacPresentationRequest?
    var showShortcutsHelp = false
    var pendingImportURLs: [URL] = []
    var statusMessage: String?
    var confirmDeleteScriptID: UUID?
    @ObservationIgnored private var activeEditorScriptID: UUID?
    @ObservationIgnored private var activeEditorFlush: (@MainActor () async -> Bool)?

    var readerScriptID: UUID? { readerRequest?.scriptID }
    var outlineScriptID: UUID? { outlineRequest?.scriptID }

    func registerEditorFlush(
        scriptID: UUID,
        flush: @escaping @MainActor () async -> Bool
    ) {
        activeEditorScriptID = scriptID
        activeEditorFlush = flush
    }

    func unregisterEditorFlush(scriptID: UUID) {
        guard activeEditorScriptID == scriptID else { return }
        activeEditorScriptID = nil
        activeEditorFlush = nil
    }

    @discardableResult
    func requestReader(scriptID: UUID) async -> Bool {
        guard await flushActiveEditorIfNeeded() else { return false }
        readerRequest = MacPresentationRequest(scriptID: scriptID)
        return true
    }

    func closeReader() {
        readerRequest = nil
    }

    @discardableResult
    func requestOutline(scriptID: UUID) async -> Bool {
        guard await flushActiveEditorIfNeeded() else { return false }
        outlineRequest = MacPresentationRequest(scriptID: scriptID)
        return true
    }

    func closeOutline() {
        outlineRequest = nil
    }

    private func flushActiveEditorIfNeeded() async -> Bool {
        guard let activeEditorFlush else { return true }
        guard await activeEditorFlush() else {
            statusMessage = "Save failed. Retry the save before presenting."
            return false
        }
        return true
    }
}

struct MacPresentationRequest: Identifiable, Equatable {
    let id = UUID()
    let scriptID: UUID
}
