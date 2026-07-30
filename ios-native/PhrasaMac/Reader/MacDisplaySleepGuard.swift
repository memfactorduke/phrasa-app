import Foundation

/// Prevents display sleep while the Mac reader is actively presenting.
/// Uses ProcessInfo activity tokens so the assertion is released on explicit end.
@MainActor
final class MacDisplaySleepGuard {
    private var activity: NSObjectProtocol?
    private(set) var isPreventingSleep = false

    func begin(reason: String = "Phrasa is presenting a script") {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: reason
        )
        isPreventingSleep = true
    }

    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        isPreventingSleep = false
    }
}

/// Pure policy for when display-sleep prevention should engage.
enum MacDisplaySleepPolicy {
    /// - No audience: prevent sleep only while playing.
    /// - Resolved visible audience: prevent sleep for the live presentation,
    ///   including pause and blackout. Release on disable/disconnect/teardown.
    static func shouldPreventSleep(
        isPresenting: Bool,
        isPlaying: Bool,
        hasVisibleAudienceOutput: Bool = false
    ) -> Bool {
        guard isPresenting else { return false }
        if hasVisibleAudienceOutput {
            return true
        }
        return isPlaying
    }
}
