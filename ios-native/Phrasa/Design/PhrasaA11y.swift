import Foundation

/// Stable, production-safe accessibility identifiers for UI automation.
/// Safe to ship in Release (no DEBUG diagnostics, no transcript/script text).
enum PhrasaA11y {
    enum Reader {
        static let progress = "phrasa.reader.progress"
        static let mode = "phrasa.reader.mode"
        static let playPause = "phrasa.reader.playPause"
        static let voiceStatus = "phrasa.reader.voiceStatus"
    }

    enum Editor {
        static let openPrompter = "phrasa.editor.openPrompter"
    }

    enum Library {
        static let scriptsRoot = "phrasa.library.scripts"
    }
}
