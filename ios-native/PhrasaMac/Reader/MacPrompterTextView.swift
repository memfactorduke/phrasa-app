import AppKit
import SwiftUI
import PhrasaDomain

/// A single AppKit TextKit surface. Progress is applied from the presentation
/// session clock — this view never owns a display-link or timer.
struct MacPrompterTextView: NSViewRepresentable {
    let text: String
    let settings: ReaderSettings
    let progress: Double
    /// Controller may scrub; audience must pass `false`.
    var allowsScrubbing: Bool = true
    /// Controller scrubbing reports progress changes. Audience leaves this nil.
    var onProgressChange: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = PrompterNSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Teleprompter script")
        textView.setAccessibilityRole(.staticText)

        scrollView.documentView = textView
        context.coordinator.configure(scrollView: scrollView, textView: textView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PrompterNSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.configure(scrollView: scrollView, textView: textView, force: false)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MacPrompterTextView
        private weak var scrollView: NSScrollView?
        private weak var textView: PrompterNSTextView?
        private var renderedText: String?
        private var styleSignature: StyleSignature?
        private var userIsScrubbing = false
        private var virtualOffset = 0.0

        private struct StyleSignature: Equatable {
            let font: String
            let fontSize: Double
            let lineHeight: Double
            let alignment: String
            let theme: String
            let horizontalMargin: Double
        }

        init(_ parent: MacPrompterTextView) { self.parent = parent }

        func configure(scrollView: NSScrollView, textView: PrompterNSTextView, force: Bool) {
            self.scrollView = scrollView
            self.textView = textView
            textView.scrubDelegate = parent.allowsScrubbing ? self : nil

            let nextStyle = StyleSignature(
                font: parent.settings.font.rawValue,
                fontSize: parent.settings.fontSize,
                lineHeight: parent.settings.lineHeight,
                alignment: parent.settings.alignment.rawValue,
                theme: parent.settings.theme.rawValue,
                horizontalMargin: parent.settings.horizontalMargin
            )

            guard force || renderedText != parent.text || styleSignature != nextStyle else {
                applyInsets(scrollView: scrollView, textView: textView)
                applyMirror(to: textView)
                applyProgress(scrollView: scrollView)
                return
            }
            // Swift String is copy-on-write: retaining the value is cheap, while
            // rebuilding a delimiter-joined copy of a long script every progress
            // update is not.
            renderedText = parent.text
            styleSignature = nextStyle

            let font = parent.settings.font.nsFont(size: parent.settings.fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = parent.settings.alignment == .center ? .center : .left
            paragraph.minimumLineHeight = font.boundingRectForFont.height * parent.settings.lineHeight
            paragraph.maximumLineHeight = font.boundingRectForFont.height * parent.settings.lineHeight

            let attributed = NSAttributedString(
                string: parent.text,
                attributes: [
                    .font: font,
                    .foregroundColor: parent.settings.theme.nsForeground,
                    .paragraphStyle: paragraph
                ]
            )
            textView.textStorage?.setAttributedString(attributed)
            textView.backgroundColor = parent.settings.theme.nsBackground
            scrollView.backgroundColor = parent.settings.theme.nsBackground
            applyMirror(to: textView)

            DispatchQueue.main.async { [weak self, weak scrollView, weak textView] in
                guard let self, let scrollView, let textView else { return }
                self.applyInsets(scrollView: scrollView, textView: textView)
                self.applyProgress(scrollView: scrollView)
            }
        }

        func teardown() {
            textView?.scrubDelegate = nil
        }

        private func applyInsets(scrollView: NSScrollView, textView: PrompterNSTextView) {
            let bounds = scrollView.contentView.bounds
            let horizontal = bounds.width * parent.settings.horizontalMargin
            let focusY = MacPrompterGeometry.contentFocusY(
                height: bounds.height,
                focusPosition: parent.settings.focusPosition
            )
            textView.textContainerInset = NSSize(
                width: horizontal,
                height: 0
            )
            scrollView.contentView.contentInsets = NSEdgeInsets(
                top: focusY,
                left: 0,
                bottom: max(0, bounds.height - focusY),
                right: 0
            )
            textView.frame.size.width = bounds.width
        }

        private func applyMirror(to textView: PrompterNSTextView) {
            var transform = CGAffineTransform.identity
            if parent.settings.mirrorHorizontal {
                transform = transform.scaledBy(x: -1, y: 1)
            }
            if parent.settings.mirrorVertical {
                transform = transform.scaledBy(x: 1, y: -1)
            }
            textView.layer?.sublayerTransform = CATransform3DMakeAffineTransform(transform)
            textView.wantsLayer = true
            if parent.settings.mirrorHorizontal || parent.settings.mirrorVertical {
                textView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            }
        }

        private func maxOffset(in scrollView: NSScrollView) -> Double {
            guard let documentView = scrollView.documentView else { return 0 }
            let contentHeight = documentView.bounds.height
                + scrollView.contentView.contentInsets.top
                + scrollView.contentView.contentInsets.bottom
            return max(0, contentHeight - scrollView.contentView.bounds.height)
        }

        private func applyProgress(scrollView: NSScrollView) {
            guard !userIsScrubbing else { return }
            let maximum = maxOffset(in: scrollView)
            var desired = maximum * parent.progress.clamped(to: 0...1)

            // Line style snaps display offset only; canonical progress stays continuous.
            if parent.settings.scrollStyle == .line, maximum > 0 {
                let font = parent.settings.font.nsFont(size: parent.settings.fontSize)
                let lineHeight = max(1, font.boundingRectForFont.height * parent.settings.lineHeight)
                desired = min(maximum, floor(desired / lineHeight) * lineHeight)
            }

            virtualOffset = desired
            let current = scrollView.contentView.bounds.origin.y
            if abs(current - desired) > 0.5 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: desired))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        func userBeganScrubbing() {
            guard parent.allowsScrubbing else { return }
            userIsScrubbing = true
        }

        func userDidScroll(scrollView: NSScrollView) {
            guard parent.allowsScrubbing, userIsScrubbing else { return }
            let maximum = maxOffset(in: scrollView)
            guard maximum > 0 else { return }
            let y = scrollView.contentView.bounds.origin.y
            let next = (y / maximum).clamped(to: 0...1)
            virtualOffset = y
            parent.onProgressChange?(next)
        }

        func userEndedScrubbing() {
            userIsScrubbing = false
        }
    }
}

/// NSTextView subclass that reports scrub gestures to the coordinator.
final class PrompterNSTextView: NSTextView {
    weak var scrubDelegate: MacPrompterTextView.Coordinator?

    override func scrollWheel(with event: NSEvent) {
        scrubDelegate?.userBeganScrubbing()
        super.scrollWheel(with: event)
        if let scrollView = enclosingScrollView {
            scrubDelegate?.userDidScroll(scrollView: scrollView)
        }
        // End scrub shortly after momentum ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scrubDelegate?.userEndedScrubbing()
        }
    }
}
