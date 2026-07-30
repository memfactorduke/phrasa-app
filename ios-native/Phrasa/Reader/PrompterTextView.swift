import SwiftUI
import UIKit
import PhrasaCore

enum PrompterGeometry {
    /// Baseline exponential smoothing factor for near-target voice chase.
    /// Lower = snappier. Paired with ``adaptiveVoiceSmoothingFactor(distance:)``
    /// so large lags catch up without hard jumps or oscillation.
    static let voiceSmoothingFactor: CGFloat = 4

    /// Settle residual below this delta (points) by snapping — stops perpetual
    /// micro-chase without UIView animation.
    static let voiceSettleEpsilon: CGFloat = 0.75

    /// Distance bands (points) for adaptive catch-up. Large errors use a lower
    /// factor so spoken text does not lag offscreen after reanchors / paragraph
    /// jumps; near-target uses the baseline for stability.
    static let voiceFarDistance: CGFloat = 240
    static let voiceMidDistance: CGFloat = 80
    static let voiceFarSmoothingFactor: CGFloat = 2.2
    static let voiceMidSmoothingFactor: CGFloat = 3.0

    /// Stage height available for script text once bottom chrome is reserved in
    /// layout flow (or measured as an obstruction). Hidden chrome → full stage.
    static func readableHeight(
        viewportHeight: CGFloat,
        bottomChromeHeight: CGFloat
    ) -> CGFloat {
        max(0, viewportHeight - max(0, bottomChromeHeight))
    }

    /// Content-space anchor used before any full-stage mirror transform.
    ///
    /// `height` must be the **readable** stage height (excludes visible bottom
    /// chrome). Voice pin, speed scroll, and the SwiftUI focus band all share
    /// this coordinate space so alignment stays correct when chrome toggles.
    static func contentFocusY(height: CGFloat, focusPosition: Double) -> CGFloat {
        let ratio = CGFloat(focusPosition.clamped(to: 0...1))
        return max(0, height) * ratio
    }

    static func displayedY(
        forContentY contentY: CGFloat,
        height: CGFloat,
        mirrorVertical: Bool
    ) -> CGFloat {
        mirrorVertical ? max(0, height) - contentY : contentY
    }

    /// On-screen position shared by the transformed text anchor and guide line.
    static func visibleFocusY(
        height: CGFloat,
        focusPosition: Double,
        mirrorVertical: Bool
    ) -> CGFloat {
        displayedY(
            forContentY: contentFocusY(height: height, focusPosition: focusPosition),
            height: height,
            mirrorVertical: mirrorVertical
        )
    }

    /// Text container insets for a prompter whose bounds are the readable stage.
    /// Top inset parks the first line on the focus band; bottom inset lets the
    /// last line reach focus without scrolling into reserved chrome.
    static func textContainerInsets(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        focusPosition: Double,
        horizontalMargin: Double
    ) -> UIEdgeInsets {
        let height = max(0, viewportHeight)
        let focusY = contentFocusY(
            height: height,
            focusPosition: focusPosition
        )
        let horizontal = max(0, viewportWidth) * CGFloat(horizontalMargin.clamped(to: 0...0.5))
        return UIEdgeInsets(
            top: focusY,
            left: horizontal,
            bottom: max(0, height - focusY),
            right: horizontal
        )
    }

    /// Focus line must sit inside the readable stage — never under bottom chrome.
    static func focusLineIsReadable(
        readableHeight: CGFloat,
        focusPosition: Double,
        mirrorVertical: Bool
    ) -> Bool {
        let height = max(0, readableHeight)
        guard height > 0 else { return false }
        let focusY = visibleFocusY(
            height: height,
            focusPosition: focusPosition,
            mirrorVertical: mirrorVertical
        )
        return focusY >= 0 && focusY <= height + 0.001
    }

    /// Content offset that pins a token line's center to the focus line.
    /// Never derived from token-index / document-height percentage.
    static func offsetPinningLineCenter(
        lineCenterY: CGFloat,
        focusYInViewport: CGFloat,
        maxOffset: CGFloat
    ) -> CGFloat {
        let raw = lineCenterY - focusYInViewport
        guard maxOffset > 0 else { return 0 }
        return min(max(0, raw), maxOffset)
    }

    /// Adaptive factor: catch up when far, ease when close. Monotonic approach
    /// (never overshoots), so CADisplayLink ticks cannot oscillate.
    static func adaptiveVoiceSmoothingFactor(distance: CGFloat) -> CGFloat {
        let absDistance = abs(distance)
        if absDistance >= voiceFarDistance { return voiceFarSmoothingFactor }
        if absDistance >= voiceMidDistance { return voiceMidSmoothingFactor }
        return voiceSmoothingFactor
    }

    /// Smooth toward target; Reduced Motion snaps.
    ///
    /// When `factor` is the default baseline, distance-adaptive catch-up applies.
    /// Explicit non-default factors (tests / callers) are honored as-is.
    static func smoothedOffset(
        current: CGFloat,
        target: CGFloat,
        factor: CGFloat = voiceSmoothingFactor,
        reduceMotion: Bool
    ) -> CGFloat {
        if reduceMotion { return target }
        let delta = target - current
        if abs(delta) <= voiceSettleEpsilon { return target }
        let effective: CGFloat
        if factor == voiceSmoothingFactor {
            effective = adaptiveVoiceSmoothingFactor(distance: delta)
        } else {
            effective = factor
        }
        guard effective > 0 else { return target }
        // Asymptotic step — no overshoot, no UIView.animate re-entrancy.
        return current + delta / effective
    }

    /// Character ranges for each display token, in `ReaderTokenizer` order.
    /// Pure string walk — no TextKit. Used by the UITextView path and tests.
    static func tokenNSRanges(in text: String) -> [NSRange] {
        let tokens = ReaderTokenizer.tokenize(text)
        guard !tokens.isEmpty else { return [] }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(tokens.count)
        var searchStart = text.startIndex

        for token in tokens {
            if let range = text.range(of: token.raw, range: searchStart..<text.endIndex) {
                ranges.append(NSRange(range, in: text))
                searchStart = range.upperBound
            } else {
                // Fallback: empty range at current search cursor (keeps indices aligned).
                let location = text.utf16.distance(from: text.startIndex, to: searchStart)
                ranges.append(NSRange(location: location, length: 0))
            }
        }
        return ranges
    }

    /// Nearest token whose line-center is closest to the focus content Y.
    static func nearestTokenIndex(
        focusContentY: CGFloat,
        tokenLineCenters: [CGFloat]
    ) -> Int? {
        guard !tokenLineCenters.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = abs(tokenLineCenters[0] - focusContentY)
        for index in tokenLineCenters.indices.dropFirst() {
            let distance = abs(tokenLineCenters[index] - focusContentY)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Line center Y in content coordinates from a line-fragment rect + top inset.
    static func lineCenterY(fragmentRect: CGRect, textContainerInsetTop: CGFloat) -> CGFloat {
        fragmentRect.midY + textContainerInsetTop
    }

    /// Content Y of the focus line for a given scroll offset (inverse of pin).
    static func focusContentY(contentOffsetY: CGFloat, focusYInViewport: CGFloat) -> CGFloat {
        contentOffsetY + focusYInViewport
    }
}

/// A single TextKit surface driven by CADisplayLink. This keeps long scripts
/// smooth without creating a SwiftUI view and layout callback for every word.
///
/// **Speed mode:** progress is a document-height ratio advanced by WPM.
/// **Voice mode:** a target display-token index is pinned via TextKit line
/// geometry; content offset is chased each display-link tick with adaptive
/// exponential smoothing (baseline ~4, faster when far). Never maps a
/// voice token ratio directly to document-height percentage. Never uses
/// `setContentOffset(animated: true)` — avoids reanimation and oscillation.
struct PrompterTextView: UIViewRepresentable {
    let text: String
    let settings: ReaderSettings
    /// Speed auto-scroll and voice chase both use the display link when true.
    let isPlaying: Bool
    @Binding var progress: Double
    /// When non-nil and mode is voice, pin this display token to the focus line.
    var voiceTargetTokenIndex: Int? = nil
    var reduceMotion: Bool = false
    /// Scrub end: nearest display token at the focus line (authoritative reseat).
    var onScrubEndedNearToken: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.backgroundColor = settings.theme.uiBackground
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityLabel = "Teleprompter script"
        view.accessibilityTraits = [.staticText]
        context.coordinator.configure(view, force: true)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configure(view, force: false)
        context.coordinator.setPlaying(isPlaying, in: view)
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PrompterTextView
        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var signature = ""
        private var frameCounter = 0
        private var userIsScrubbing = false
        private var virtualOffset = 0.0
        /// Voice: last computed pin target (content offset).
        private var voiceTargetOffset = 0.0
        private var tokenRanges: [NSRange] = []
        private var tokenRangesSignature = ""
        private var cachedWordCount = 0
        private var lastAppliedInsets: UIEdgeInsets?
        private var lastAppliedBoundsSize: CGSize?
        private var voiceTargetCache: VoiceTargetCache?

        private struct VoiceTargetCache: Equatable {
            let tokenIndex: Int
            let boundsSize: CGSize
            let contentSize: CGSize
            let insets: UIEdgeInsets
        }

        init(_ parent: PrompterTextView) { self.parent = parent }

        func configure(_ view: UITextView, force: Bool) {
            textView = view
            let nextSignature = [
                parent.text,
                parent.settings.font.rawValue,
                String(parent.settings.fontSize),
                String(parent.settings.lineHeight),
                parent.settings.alignment.rawValue,
                parent.settings.theme.rawValue,
                String(parent.settings.horizontalMargin)
            ].joined(separator: "|")
            guard force || signature != nextSignature else {
                applyInsets(to: view)
                applyMirror(to: view)
                if isVoiceMode {
                    refreshVoiceTarget(in: view)
                    if parent.reduceMotion || !parent.isPlaying {
                        applyVoiceOffset(to: view, smooth: false)
                    }
                } else {
                    applyProgress(to: view)
                }
                return
            }
            signature = nextSignature
            tokenRangesSignature = ""
            tokenRanges = []
            cachedWordCount = TextMetrics.wordCount(parent.text)
            voiceTargetCache = nil

            let font = parent.settings.font.uiFont(size: parent.settings.fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = parent.settings.alignment == .center ? .center : .left
            paragraph.minimumLineHeight = font.lineHeight * parent.settings.lineHeight
            paragraph.maximumLineHeight = font.lineHeight * parent.settings.lineHeight
            view.attributedText = NSAttributedString(
                string: parent.text,
                attributes: [
                    .font: font,
                    .foregroundColor: parent.settings.theme.uiForeground,
                    .paragraphStyle: paragraph
                ]
            )
            view.backgroundColor = parent.settings.theme.uiBackground
            applyMirror(to: view)
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.applyInsets(to: view)
                if self.isVoiceMode {
                    self.refreshVoiceTarget(in: view)
                    self.applyVoiceOffset(to: view, smooth: false)
                } else {
                    self.applyProgress(to: view)
                }
            }
        }

        func teardown() {
            displayLink?.invalidate()
            displayLink = nil
            textView?.delegate = nil
        }

        private var isVoiceMode: Bool {
            parent.settings.mode == .voice && parent.voiceTargetTokenIndex != nil
        }

        private func applyInsets(to view: UITextView) {
            // Bounds are the readable stage (ReaderView reserves bottom chrome in
            // layout flow). Insets + focus share that height so spoken text never
            // pins under visible controls.
            let next = PrompterGeometry.textContainerInsets(
                viewportWidth: view.bounds.width,
                viewportHeight: view.bounds.height,
                focusPosition: parent.settings.focusPosition,
                horizontalMargin: parent.settings.horizontalMargin
            )
            guard lastAppliedInsets != next || lastAppliedBoundsSize != view.bounds.size else {
                return
            }
            lastAppliedInsets = next
            lastAppliedBoundsSize = view.bounds.size
            voiceTargetCache = nil
            view.textContainerInset = next
            view.layoutIfNeeded()
        }

        private func applyMirror(to view: UITextView) {
            view.transform = CGAffineTransform(
                scaleX: parent.settings.mirrorHorizontal ? -1 : 1,
                y: parent.settings.mirrorVertical ? -1 : 1
            )
        }

        func setPlaying(_ playing: Bool, in view: UITextView) {
            if playing {
                guard displayLink == nil else { return }
                virtualOffset = view.contentOffset.y
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else {
                displayLink?.invalidate()
                displayLink = nil
                // Snap voice target when pausing so the committed token stays pinned.
                if isVoiceMode {
                    refreshVoiceTarget(in: view)
                    applyVoiceOffset(to: view, smooth: false)
                }
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let view = textView, !userIsScrubbing else { return }
            // This call is intentionally cheap on steady-state frames: layout is
            // performed only when geometry or inset settings actually changed.
            applyInsets(to: view)

            if isVoiceMode {
                // TextKit line geometry is stable until the target or layout
                // changes; avoid forcing a full layout on every 120 Hz tick.
                refreshVoiceTarget(in: view)
                applyVoiceOffset(to: view, smooth: true)
                return
            }

            let maximum = maxOffset(in: view)
            guard maximum > 0 else { return }
            let duration = max(
                1,
                Double(cachedWordCount) / parent.settings.speedWPM * 60
            )
            let pointsPerSecond = maximum / duration
            let delta = pointsPerSecond * max(0, link.targetTimestamp - link.timestamp)
            virtualOffset = min(maximum, virtualOffset + delta)
            let next: Double
            if virtualOffset >= maximum {
                next = maximum
            } else if parent.settings.scrollStyle == .line {
                let font = parent.settings.font.uiFont(size: parent.settings.fontSize)
                let lineHeight = max(1, font.lineHeight * parent.settings.lineHeight)
                next = min(maximum, floor(virtualOffset / lineHeight) * lineHeight)
            } else {
                next = virtualOffset
            }
            view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            frameCounter += 1
            if frameCounter.isMultiple(of: 8) {
                parent.progress = next / maximum
            }
        }

        private func maxOffset(in view: UITextView) -> Double {
            max(0, view.contentSize.height - view.bounds.height)
        }

        private func applyProgress(to view: UITextView) {
            guard !userIsScrubbing else { return }
            let maximum = maxOffset(in: view)
            let desired = maximum * parent.progress.clamped(to: 0...1)
            virtualOffset = desired
            if abs(view.contentOffset.y - desired) > 2 {
                view.setContentOffset(CGPoint(x: 0, y: desired), animated: false)
            }
        }

        // MARK: - Voice token pin

        private func ensureTokenRanges() {
            if tokenRangesSignature != parent.text {
                tokenRangesSignature = parent.text
                tokenRanges = PrompterGeometry.tokenNSRanges(in: parent.text)
            }
        }

        /// TextKit: token → character range → glyph range → line fragment → pin offset.
        private func refreshVoiceTarget(in view: UITextView) {
            ensureTokenRanges()
            guard let tokenIndex = parent.voiceTargetTokenIndex,
                  tokenRanges.indices.contains(tokenIndex) else {
                return
            }
            let cache = VoiceTargetCache(
                tokenIndex: tokenIndex,
                boundsSize: view.bounds.size,
                contentSize: view.contentSize,
                insets: view.textContainerInset
            )
            guard voiceTargetCache != cache else { return }
            let range = tokenRanges[tokenIndex]
            guard range.location != NSNotFound else { return }

            view.layoutManager.ensureLayout(for: view.textContainer)
            let glyphRange = view.layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            var fragment = CGRect.null
            view.layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, stop in
                fragment = rect
                stop.pointee = true
            }
            if fragment.isNull {
                // Empty / unlaid glyph — fall back to used rect of the character range.
                fragment = view.layoutManager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: view.textContainer
                )
            }

            let lineCenter = PrompterGeometry.lineCenterY(
                fragmentRect: fragment,
                textContainerInsetTop: view.textContainerInset.top
            )
            let focusY = PrompterGeometry.contentFocusY(
                height: view.bounds.height,
                focusPosition: parent.settings.focusPosition
            )
            let maximum = CGFloat(maxOffset(in: view))
            voiceTargetOffset = Double(
                PrompterGeometry.offsetPinningLineCenter(
                    lineCenterY: lineCenter,
                    focusYInViewport: focusY,
                    maxOffset: maximum
                )
            )
            voiceTargetCache = cache
        }

        private func applyVoiceOffset(to view: UITextView, smooth: Bool) {
            guard !userIsScrubbing else { return }
            // Keep virtualOffset authoritative so display-link chase and scrub
            // handoff never fight UIKit's animated contentOffset path.
            let next: Double
            if smooth && !parent.reduceMotion {
                next = Double(
                    PrompterGeometry.smoothedOffset(
                        current: CGFloat(virtualOffset),
                        target: CGFloat(voiceTargetOffset),
                        reduceMotion: false
                    )
                )
            } else {
                next = voiceTargetOffset
            }
            virtualOffset = next
            // animated: false only — UIView animation would re-trigger and oscillate.
            if abs(view.contentOffset.y - next) > 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
        }

        /// Line centers for every token (content coordinates) — scrub end lookup.
        private func tokenLineCenters(in view: UITextView) -> [CGFloat] {
            ensureTokenRanges()
            view.layoutManager.ensureLayout(for: view.textContainer)
            let insetTop = view.textContainerInset.top
            return tokenRanges.map { range in
                guard range.location != NSNotFound, range.length >= 0 else { return insetTop }
                let glyphRange = view.layoutManager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                var fragment = CGRect.null
                view.layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, stop in
                    fragment = rect
                    stop.pointee = true
                }
                if fragment.isNull {
                    fragment = view.layoutManager.boundingRect(
                        forGlyphRange: glyphRange,
                        in: view.textContainer
                    )
                }
                return PrompterGeometry.lineCenterY(
                    fragmentRect: fragment,
                    textContainerInsetTop: insetTop
                )
            }
        }

        private func reportNearestFocusToken(from scrollView: UIScrollView) {
            guard let view = textView, let handler = parent.onScrubEndedNearToken else { return }
            let focusY = PrompterGeometry.contentFocusY(
                height: view.bounds.height,
                focusPosition: parent.settings.focusPosition
            )
            let focusContentY = PrompterGeometry.focusContentY(
                contentOffsetY: scrollView.contentOffset.y,
                focusYInViewport: focusY
            )
            let centers = tokenLineCenters(in: view)
            if let index = PrompterGeometry.nearestTokenIndex(
                focusContentY: focusContentY,
                tokenLineCenters: centers
            ) {
                handler(index)
            }
        }

        // MARK: - Scrub

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userIsScrubbing = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard userIsScrubbing else { return }
            let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            guard maximum > 0 else { return }
            // Live scrub still publishes ratio for chrome; end event reseats by token.
            parent.progress = (scrollView.contentOffset.y / maximum).clamped(to: 0...1)
            virtualOffset = scrollView.contentOffset.y
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                userIsScrubbing = false
                finishScrub(scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            userIsScrubbing = false
            finishScrub(scrollView)
        }

        private func finishScrub(_ scrollView: UIScrollView) {
            if isVoiceMode || parent.onScrubEndedNearToken != nil {
                reportNearestFocusToken(from: scrollView)
            }
        }
    }
}
