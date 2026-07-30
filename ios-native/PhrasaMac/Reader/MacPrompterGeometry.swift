import Foundation

enum MacPrompterGeometry {
    /// Stage height available for script text once bottom chrome is reserved in
    /// layout flow. Hidden chrome → full stage (matches iOS ``PrompterGeometry``).
    static func readableHeight(
        viewportHeight: CGFloat,
        bottomChromeHeight: CGFloat
    ) -> CGFloat {
        max(0, viewportHeight - max(0, bottomChromeHeight))
    }

    /// Content-space anchor used before any full-stage mirror transform.
    ///
    /// `height` must be the **readable** stage height (excludes visible bottom
    /// chrome). Speed scroll and focus share this coordinate space so alignment
    /// stays correct when chrome toggles.
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

    /// Points of scroll advance for one display frame at the given WPM.
    static func pointsPerSecond(
        wordCount: Int,
        speedWPM: Double,
        maximumOffset: Double
    ) -> Double {
        guard maximumOffset > 0, speedWPM > 0 else { return 0 }
        let words = max(1, wordCount)
        let duration = Double(words) / speedWPM * 60
        guard duration > 0 else { return 0 }
        return maximumOffset / duration
    }
}
