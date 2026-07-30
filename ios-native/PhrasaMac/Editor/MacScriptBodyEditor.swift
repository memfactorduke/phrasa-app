import AppKit
import SwiftUI

/// AppKit text editor so find-a-line can select and scroll to a match.
struct MacScriptBodyEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightedRange: NSRange?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .white
        textView.backgroundColor = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)
        textView.insertionPointColor = .white
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("Script body")
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let maxLen = (text as NSString).length
            let location = min(selected.location, maxLen)
            let length = min(selected.length, max(0, maxLen - location))
            textView.setSelectedRange(NSRange(location: location, length: length))
        }
        if let highlightedRange,
           highlightedRange.location != NSNotFound,
           NSMaxRange(highlightedRange) <= (textView.string as NSString).length {
            textView.setSelectedRange(highlightedRange)
            textView.scrollRangeToVisible(highlightedRange)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacScriptBodyEditor
        weak var textView: NSTextView?

        init(_ parent: MacScriptBodyEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }
    }
}

extension Notification.Name {
    static let macFindLineRequested = Notification.Name("phrasa.mac.findLineRequested")
}
