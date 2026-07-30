import Foundation
import Observation
import PhrasaDomain

enum MacEditorSaveState: Equatable {
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

/// Dirty-driven single-writer save queue for the Mac editor.
@MainActor
@Observable
final class MacEditorAutosaveController {
    typealias SaveAction = @MainActor (ScriptDocument) async -> Bool

    private(set) var state: MacEditorSaveState = .saved

    private var persistedContent: MacEditableScriptContent
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
        persistedContent = MacEditableScriptContent(initial)
        self.debounceDelay = debounceDelay
        self.saveAction = saveAction
    }

    func record(_ document: ScriptDocument) {
        let content = MacEditableScriptContent(document)
        guard content != persistedContent else {
            debounceTask?.cancel()
            debounceTask = nil
            if saveLoop == nil {
                pending = nil
                state = .saved
            } else {
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

    func cancelPending() {
        debounceTask?.cancel()
        debounceTask = nil
        saveLoop?.cancel()
        saveLoop = nil
        pending = nil
        state = .saved
    }

    func rebase(_ metadata: MacLibraryEditorDocumentMetadataChange) {
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
                persistedContent = MacEditableScriptContent(next)
                if request.metadataRevision < metadataRevision,
                   case .value(let folderID) = rebasedFolderID {
                    persistedContent.folderID = folderID
                }
                if pending.map({ MacEditableScriptContent($0.document) }) == persistedContent {
                    pending = nil
                }
                state = pending == nil ? .saved : .saving
            } else {
                if pending == nil { pending = request }
                state = .failed
                break
            }
        }
        saveLoop = nil
    }
}

private struct MacEditableScriptContent: Equatable {
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

    mutating func apply(_ metadata: MacLibraryEditorDocumentMetadataChange) {
        if case .folderID(let folderID) = metadata {
            self.folderID = folderID
        }
    }
}

enum MacEditorExternalChangeDecision: Equatable {
    case ignore
    case replace(ScriptDocument?)
    case rebase(MacLibraryEditorDocumentMetadataChange)
}

enum MacEditorExternalChangePolicy {
    static func decision(
        for change: MacLibraryEditorDocumentChange,
        editorOriginID: UUID
    ) -> MacEditorExternalChangeDecision {
        guard change.editorOriginID != editorOriginID else { return .ignore }
        switch change.scope {
        case .replacement:
            return .replace(change.document)
        case .metadata(let metadata):
            return .rebase(metadata)
        }
    }
}
