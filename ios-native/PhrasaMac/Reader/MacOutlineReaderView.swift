import AppKit
import SwiftUI
import PhrasaDomain

/// Full-stage outline presentation for Mac. Talking points advance with
/// keyboard, clicker, and on-screen controls — not edit-only data.
struct MacOutlineReaderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let script: ScriptDocument
    let onClose: () -> Void

    @State private var index = 0
    @State private var isComplete = false
    @FocusState private var stageFocused: Bool

    private var points: [OutlinePoint] {
        MacOutlineReaderContent.meaningfulPoints(from: script.outline)
    }

    var body: some View {
        ZStack {
            MacDesign.canvas.ignoresSafeArea()
            if points.isEmpty {
                emptyState
            } else if isComplete {
                completionState
            } else {
                pointStage
            }
        }
        .preferredColorScheme(.dark)
        .focusable()
        .focused($stageFocused)
        .onAppear { stageFocused = true }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outline presenter")
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
                description: Text("Add talking points in the editor, then present them here.")
            )
            .foregroundStyle(MacDesign.muted)
            Spacer()
        }
        .padding(MacDesign.pagePadding)
    }

    private var pointStage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("POINT \(index + 1) OF \(points.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .tracking(1.4)
                    .foregroundStyle(MacDesign.muted)
                    .accessibilityLabel("Point \(index + 1) of \(points.count)")
                Spacer()
                closeButton
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("NOW")
                        .font(.caption.weight(.semibold))
                        .tracking(1.6)
                        .foregroundStyle(MacDesign.muted)
                    let point = points[index]
                    Text(MacOutlineReaderContent.primaryText(for: point))
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(MacDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let note = MacOutlineReaderContent.supportingNote(for: point) {
                        Text(note)
                            .font(.title3)
                            .foregroundStyle(MacDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            }

            if index + 1 < points.count {
                VStack(alignment: .leading, spacing: 6) {
                    Text("UP NEXT")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(MacDesign.muted)
                    Text(MacOutlineReaderContent.primaryText(for: points[index + 1]))
                        .font(.headline)
                        .foregroundStyle(MacDesign.ink.opacity(0.72))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(MacDesign.elevated, in: RoundedRectangle(cornerRadius: MacDesign.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: MacDesign.controlRadius)
                        .stroke(MacDesign.border, lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Up next, \(MacOutlineReaderContent.spokenText(for: points[index + 1]))"
                )
            }

            HStack(spacing: 12) {
                Button { goPrevious() } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(index == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button { goNext() } label: {
                    Label(
                        index == points.count - 1 ? "Finish" : "Next",
                        systemImage: index == points.count - 1 ? "checkmark" : "chevron.right"
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(MacDesign.ink)
                .foregroundStyle(MacDesign.canvas)
            }
            .font(.headline)
        }
        .padding(MacDesign.pagePadding)
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
                .foregroundStyle(MacDesign.ink)
                .frame(width: 72, height: 72)
                .background(MacDesign.surfaceSecondary, in: RoundedRectangle(cornerRadius: MacDesign.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: MacDesign.controlRadius)
                        .stroke(MacDesign.border, lineWidth: 1)
                }
                .accessibilityHidden(true)
            Text("Outline complete")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(MacDesign.ink)
            Text("You made it through all \(points.count) talking points.")
                .font(.title3)
                .foregroundStyle(MacDesign.muted)
            Spacer()
            HStack(spacing: 12) {
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(MacDesign.ink)
                    .foregroundStyle(MacDesign.canvas)
                    .keyboardShortcut(.defaultAction)
                Button("Start again") {
                    index = 0
                    withAnimation(MacDesign.motion(reduceMotion: reduceMotion)) {
                        isComplete = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(MacDesign.pagePadding)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(MacDesign.ink)
        .help("Close outline presenter")
        .accessibilityLabel("Close outline")
        .keyboardShortcut(.escape, modifiers: [])
    }

    private func goPrevious() {
        index = max(0, index - 1)
    }

    private func goNext() {
        if index == points.count - 1 {
            withAnimation(MacDesign.motion(reduceMotion: reduceMotion)) {
                isComplete = true
            }
        } else {
            index += 1
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch MacOutlineReaderCommand.resolve(keyPress: keyPress) {
        case .exit:
            onClose()
            return .handled
        case .previous:
            guard !points.isEmpty, !isComplete else { return .handled }
            goPrevious()
            return .handled
        case .next:
            guard !points.isEmpty else { return .handled }
            if isComplete {
                onClose()
            } else {
                goNext()
            }
            return .handled
        case .none:
            return .ignored
        }
    }
}

enum MacOutlineReaderCommand: Equatable, Sendable {
    case previous
    case next
    case exit

    static func resolve(keyPress: KeyPress) -> MacOutlineReaderCommand? {
        switch keyPress.key {
        case .escape: return .exit
        case .leftArrow, .pageUp, .upArrow: return .previous
        case .rightArrow, .pageDown, .downArrow, .space: return .next
        default: return nil
        }
    }
}

/// Pure outline content helpers (testable without UI).
enum MacOutlineReaderContent {
    static func meaningfulPoints(from points: [OutlinePoint]) -> [OutlinePoint] {
        points.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func primaryText(for point: OutlinePoint) -> String {
        let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return point.note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func supportingNote(for point: OutlinePoint) -> String? {
        let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = point.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !note.isEmpty else { return nil }
        return note
    }

    static func spokenText(for point: OutlinePoint) -> String {
        let primary = primaryText(for: point)
        if let note = supportingNote(for: point) {
            return "\(primary). \(note)"
        }
        return primary
    }
}

struct MacOutlineWindowHost: View {
    @Environment(MacLibraryStore.self) private var library
    @Environment(MacAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MacPresentationSnapshot?

    var body: some View {
        Group {
            if let request = appModel.outlineRequest,
               let snapshot,
               snapshot.requestID == request.id {
                MacOutlineReaderView(script: snapshot.script) {
                    appModel.closeOutline()
                    dismiss()
                }
                .id(request.id)
            } else {
                ProgressView("Opening outline…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MacDesign.canvas)
            }
        }
        .background(MacDesign.canvas)
        .task(id: appModel.outlineRequest?.id) {
            guard let request = appModel.outlineRequest,
                  let script = library.script(id: request.scriptID) else {
                snapshot = nil
                return
            }
            snapshot = MacPresentationSnapshot(
                requestID: request.id,
                script: script
            )
        }
        .onDisappear {
            appModel.closeOutline()
        }
    }
}
