import SwiftUI
import UIKit

/// One-shot request to select a UTF-16 range and scroll it into view.
/// A new `id` is required for every find so repeating the same match still jumps.
struct FindLineJumpRequest: Equatable, Sendable {
    let id: UUID
    let range: NSRange

    static func make(range: NSRange, id: UUID = UUID()) -> FindLineJumpRequest {
        FindLineJumpRequest(id: id, range: range)
    }
}

/// Pure selection/jump helpers shared by the TextKit editor and unit tests.
enum ScriptBodySelectionPolicy {
    /// Returns `range` when it lies fully inside a body of `utf16Length`, else nil.
    static func clampedSelection(_ range: NSRange, utf16Length: Int) -> NSRange? {
        guard range.location != NSNotFound else { return nil }
        guard range.location >= 0, range.length >= 0, utf16Length >= 0 else { return nil }
        guard NSMaxRange(range) <= utf16Length else { return nil }
        return range
    }

    /// Restores a prior selection after an external body replace, clamped to the new length.
    static func restoredSelection(
        previous: NSRange,
        utf16Length: Int
    ) -> NSRange {
        let location = min(max(0, previous.location), utf16Length)
        let length = min(max(0, previous.length), max(0, utf16Length - location))
        return NSRange(location: location, length: length)
    }
}

/// Find-line status, wrap offset, announcement, and optional editor jump.
enum FindLineJumpPresentation {
    struct Outcome: Equatable, Sendable {
        var fromOffset: Int
        var status: String
        var announcement: String
        var jump: FindLineJumpRequest?
    }

    static func perform(
        body: String,
        query: String,
        fromUTF16Offset: Int
    ) -> Outcome {
        guard let range = FindLineMatching.firstMatchRange(
            in: body,
            query: query,
            fromUTF16Offset: fromUTF16Offset
        ) else {
            return Outcome(
                fromOffset: fromUTF16Offset,
                status: "No match",
                announcement: "No match",
                jump: nil
            )
        }
        let line = FindLineMatching.lineNumber(in: body, utf16Offset: range.location)
        return Outcome(
            fromOffset: range.location + max(1, range.length),
            status: "Line \(line)",
            announcement: "Found on line \(line)",
            jump: .make(range: range)
        )
    }
}

/// TextKit body surface so find-a-line can select a match and scroll it on-screen.
/// Keeps a plain-text binding for autosave; no attributed-storage complexity.
struct ScriptBodyTextEditor: UIViewRepresentable {
    @Binding var text: String
    var jumpRequest: FindLineJumpRequest?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = UIColor(hex: 0x000000)
        textView.textColor = UIColor(hex: 0xFFFFFF)
        textView.tintColor = UIColor(hex: 0xFFFFFF)
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.dataDetectorTypes = []
        textView.accessibilityLabel = "Script text"
        textView.text = text
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if !context.coordinator.isEditingFromUI,
           textView.text != text {
            let previous = textView.selectedRange
            textView.text = text
            textView.selectedRange = ScriptBodySelectionPolicy.restoredSelection(
                previous: previous,
                utf16Length: (text as NSString).length
            )
        }

        applyJumpIfNeeded(on: textView, coordinator: context.coordinator)
    }

    private func applyJumpIfNeeded(on textView: UITextView, coordinator: Coordinator) {
        guard let jumpRequest,
              jumpRequest.id != coordinator.lastAppliedJumpID,
              let range = ScriptBodySelectionPolicy.clampedSelection(
                jumpRequest.range,
                utf16Length: (textView.text as NSString).length
              ) else {
            return
        }
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
        // Selection is only visibly emphasized while first responder on iOS.
        if !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        coordinator.lastAppliedJumpID = jumpRequest.id
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ScriptBodyTextEditor
        weak var textView: UITextView?
        var isEditingFromUI = false
        var lastAppliedJumpID: UUID?

        init(_ parent: ScriptBodyTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            isEditingFromUI = true
            parent.text = textView.text ?? ""
            isEditingFromUI = false
        }
    }
}
