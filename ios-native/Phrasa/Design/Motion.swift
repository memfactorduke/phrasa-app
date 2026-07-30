import SwiftUI

/// Shared reduced-motion helpers for product chrome.
enum PhrasaMotion {
    static func withAnimationIfAllowed<Result>(
        reduceMotion: Bool,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if reduceMotion {
            return try body()
        }
        return try withAnimation(PhrasaDesign.motion, body)
    }
}
