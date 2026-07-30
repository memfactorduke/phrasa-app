import Foundation
import PhrasaDomain

/// A stable, process-independent signature used to avoid resuming at the wrong
/// location after a script has been edited.
enum MacReaderContentSignature {
    static func make(for body: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var byteCount = 0
        for byte in body.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
            byteCount += 1
        }
        return String(format: "%016llx:%d", hash, byteCount)
    }
}

/// Shipping Mac resume envelope. Carries domain ResumeBookmark context with
/// Codable migration for legacy scalar progress archives.
struct MacReaderBookmark: Codable, Equatable, Sendable {
    let scriptID: UUID
    let contentSignature: String
    var progress: Double
    var focusTokenIndex: Int
    var mode: ReaderMode
    var speedWPM: Double
    var domainContentSignature: String?
    var elapsedActiveTime: TimeInterval
    var activeRunCount: Int
    var updatedAt: Date

    init(
        scriptID: UUID,
        contentSignature: String,
        progress: Double,
        focusTokenIndex: Int = 0,
        mode: ReaderMode = .speed,
        speedWPM: Double = 140,
        domainContentSignature: String? = nil,
        elapsedActiveTime: TimeInterval,
        activeRunCount: Int = 0,
        updatedAt: Date
    ) {
        self.scriptID = scriptID
        self.contentSignature = contentSignature
        self.progress = progress.clamped(to: 0...1)
        self.focusTokenIndex = max(0, focusTokenIndex)
        self.mode = mode
        self.speedWPM = speedWPM.clamped(to: 40...400)
        self.domainContentSignature = domainContentSignature
        self.elapsedActiveTime = max(0, elapsedActiveTime)
        self.activeRunCount = max(0, activeRunCount)
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scriptID = try container.decode(UUID.self, forKey: .scriptID)
        contentSignature = try container.decode(String.self, forKey: .contentSignature)
        progress = (try container.decode(Double.self, forKey: .progress)).clamped(to: 0...1)
        focusTokenIndex = max(0, try container.decodeIfPresent(Int.self, forKey: .focusTokenIndex) ?? 0)
        mode = try container.decodeIfPresent(ReaderMode.self, forKey: .mode) ?? .speed
        speedWPM = (try container.decodeIfPresent(Double.self, forKey: .speedWPM) ?? 140)
            .clamped(to: 40...400)
        domainContentSignature = try container.decodeIfPresent(String.self, forKey: .domainContentSignature)
        elapsedActiveTime = max(0, try container.decode(TimeInterval.self, forKey: .elapsedActiveTime))
        activeRunCount = max(0, try container.decodeIfPresent(Int.self, forKey: .activeRunCount) ?? 0)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    static func make(
        script: ScriptDocument,
        progress: Double,
        focusTokenIndex: Int,
        mode: ReaderMode,
        speedWPM: Double,
        elapsedActiveTime: TimeInterval,
        activeRunCount: Int,
        updatedAt: Date
    ) -> MacReaderBookmark {
        MacReaderBookmark(
            scriptID: script.id,
            contentSignature: MacReaderContentSignature.make(for: script.body),
            progress: progress,
            focusTokenIndex: focusTokenIndex,
            mode: mode,
            speedWPM: speedWPM,
            domainContentSignature: ScriptContentSignature.make(script),
            elapsedActiveTime: elapsedActiveTime,
            activeRunCount: activeRunCount,
            updatedAt: updatedAt
        )
    }

    func domainResume(for script: ScriptDocument? = nil) -> ResumeBookmark {
        let signature = domainContentSignature
            ?? script.map { ScriptContentSignature.make($0) }
            ?? contentSignature
        return ResumeBookmark(
            scriptID: scriptID,
            focusTokenIndex: focusTokenIndex,
            speedProgress: progress,
            contentSignature: signature,
            savedAt: updatedAt,
            mode: mode,
            speedWPM: speedWPM
        )
    }

    func isResumeEligible(
        for body: String,
        minimumProgress: Double = 0.01,
        completionThreshold: Double = 0.999
    ) -> Bool {
        contentSignature == MacReaderContentSignature.make(for: body)
            && progress >= minimumProgress
            && progress < completionThreshold
    }

    func isResumeEligible(
        for script: ScriptDocument,
        minimumProgress: Double = 0.01,
        completionThreshold: Double = 0.999
    ) -> Bool {
        guard script.id == scriptID else { return false }
        if let domainContentSignature {
            guard domainContentSignature == ScriptContentSignature.make(script) else { return false }
        } else {
            guard contentSignature == MacReaderContentSignature.make(for: script.body) else { return false }
        }
        return progress >= minimumProgress && progress < completionThreshold
    }
}

struct MacReaderCompletionRecap: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let scriptID: UUID
    let completedAt: Date
    let activeTime: TimeInterval
    let wordCount: Int
    let averageWordsPerMinute: Double
    let targetDuration: TimeInterval?
    let targetDelta: TimeInterval?
    let activeRunCount: Int
    let wasResumed: Bool

    init(
        id: UUID = UUID(),
        scriptID: UUID,
        completedAt: Date,
        activeTime: TimeInterval,
        wordCount: Int,
        targetDuration: TimeInterval?,
        activeRunCount: Int,
        wasResumed: Bool
    ) {
        let safeTime = max(0, activeTime)
        let safeWordCount = max(0, wordCount)
        let safeTarget = targetDuration.flatMap { $0 > 0 ? $0 : nil }
        self.id = id
        self.scriptID = scriptID
        self.completedAt = completedAt
        self.activeTime = safeTime
        self.wordCount = safeWordCount
        self.averageWordsPerMinute = safeTime > 0
            ? Double(safeWordCount) / safeTime * 60
            : 0
        self.targetDuration = safeTarget
        self.targetDelta = safeTarget.map { safeTime - $0 }
        self.activeRunCount = max(0, activeRunCount)
        self.wasResumed = wasResumed
    }
}

enum MacReaderSessionInteractionGate {
    static func allowsPlayback(sessionIsReady: Bool, hasTracker: Bool) -> Bool {
        sessionIsReady && hasTracker
    }
}

enum MacReaderBookmarkPersistencePolicy {
    static func shouldSaveAfterPause(_ tracker: MacReaderSessionTracker) -> Bool {
        tracker.activeRunCount > 0
    }
}

/// Aligns `MacReaderSessionTracker` active time with presentation blackout.
/// Blackout suspends the tracker (no pause bookmark); reveal restarts only if playback resumes.
enum MacReaderBlackoutActiveTimeSync {
    /// Call when presentation blackout begins. Stops active-time accumulation only.
    static func suspendForBlackout(tracker: inout MacReaderSessionTracker, at date: Date) {
        guard tracker.isActive else { return }
        // Use pause to bank elapsed time; discard the bookmark — blackout is not a pause save.
        _ = tracker.pause(at: date)
    }

    /// Call when blackout is revealed. Restarts only if the presentation session resumed playback.
    static func resumeAfterBlackoutIfNeeded(
        tracker: inout MacReaderSessionTracker,
        playbackResumed: Bool,
        at date: Date
    ) {
        guard playbackResumed else { return }
        tracker.start(at: date)
    }
}

/// Pure session state. Callers inject timestamps for deterministic tests.
struct MacReaderSessionTracker: Sendable {
    let scriptID: UUID
    let contentSignature: String
    let wordCount: Int
    private(set) var focusTokenIndex: Int

    private(set) var progress: Double
    private(set) var elapsedActiveTime: TimeInterval
    private(set) var activeRunCount: Int
    private(set) var wasResumed: Bool
    private var activeSince: Date?

    init(scriptID: UUID, body: String, bookmark: MacReaderBookmark? = nil) {
        self.scriptID = scriptID
        contentSignature = MacReaderContentSignature.make(for: body)
        wordCount = TextMetrics.wordCount(body)

        if let bookmark,
           bookmark.scriptID == scriptID,
           bookmark.isResumeEligible(for: body) {
            progress = bookmark.progress
            elapsedActiveTime = bookmark.elapsedActiveTime
            activeRunCount = bookmark.activeRunCount
            focusTokenIndex = bookmark.focusTokenIndex
            wasResumed = true
        } else {
            progress = 0
            elapsedActiveTime = 0
            activeRunCount = 0
            focusTokenIndex = 0
            wasResumed = false
        }
    }

    var isActive: Bool { activeSince != nil }

    mutating func start(at date: Date) {
        guard activeSince == nil else { return }
        activeSince = date
        activeRunCount += 1
    }

    mutating func update(progress newProgress: Double, focusTokenIndex newToken: Int? = nil) {
        progress = newProgress.clamped(to: 0...1)
        if let newToken {
            focusTokenIndex = max(0, newToken)
        }
    }

    @discardableResult
    mutating func pause(
        at date: Date,
        script: ScriptDocument? = nil,
        mode: ReaderMode = .speed,
        speedWPM: Double = 140,
        focusTokenIndex: Int? = nil
    ) -> MacReaderBookmark {
        if let activeSince {
            elapsedActiveTime += max(0, date.timeIntervalSince(activeSince))
            self.activeSince = nil
        }
        if let focusTokenIndex {
            self.focusTokenIndex = max(0, focusTokenIndex)
        }
        return bookmark(at: date, script: script, mode: mode, speedWPM: speedWPM)
    }

    func bookmark(
        at date: Date,
        script: ScriptDocument? = nil,
        mode: ReaderMode = .speed,
        speedWPM: Double = 140
    ) -> MacReaderBookmark {
        let runningTime = activeSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        if let script {
            return MacReaderBookmark.make(
                script: script,
                progress: progress,
                focusTokenIndex: focusTokenIndex,
                mode: mode,
                speedWPM: speedWPM,
                elapsedActiveTime: elapsedActiveTime + runningTime,
                activeRunCount: activeRunCount,
                updatedAt: date
            )
        }
        return MacReaderBookmark(
            scriptID: scriptID,
            contentSignature: contentSignature,
            progress: progress,
            focusTokenIndex: focusTokenIndex,
            mode: mode,
            speedWPM: speedWPM,
            domainContentSignature: nil,
            elapsedActiveTime: elapsedActiveTime + runningTime,
            activeRunCount: activeRunCount,
            updatedAt: date
        )
    }

    mutating func complete(
        at date: Date,
        targetDuration: TimeInterval?,
        recapID: UUID = UUID()
    ) -> MacReaderCompletionRecap {
        _ = pause(at: date)
        progress = 1
        return MacReaderCompletionRecap(
            id: recapID,
            scriptID: scriptID,
            completedAt: date,
            activeTime: elapsedActiveTime,
            wordCount: wordCount,
            targetDuration: targetDuration,
            activeRunCount: activeRunCount,
            wasResumed: wasResumed
        )
    }
}

struct MacReaderOverlayState: Equatable, Sendable {
    var controlsVisible = true
    var isPlaying = false
    var isBlackout = false
    var hideControlsAt: Date?
}

enum MacReaderOverlayEvent: Equatable, Sendable {
    case stageTapped
    case playbackStarted
    case playbackPaused
    case toggleBlackout
    case timerFired
    case appBecameInactive
}

enum MacReaderOverlayReducer {
    static func reduce(
        _ state: inout MacReaderOverlayState,
        event: MacReaderOverlayEvent,
        now: Date,
        autoHideDelay: TimeInterval = 2.5
    ) {
        switch event {
        case .stageTapped:
            if state.isBlackout {
                state.isBlackout = false
                state.controlsVisible = true
            } else {
                state.controlsVisible.toggle()
            }
            state.hideControlsAt = state.controlsVisible && state.isPlaying
                ? now.addingTimeInterval(max(0, autoHideDelay))
                : nil

        case .playbackStarted:
            state.isPlaying = true
            state.isBlackout = false
            state.hideControlsAt = now.addingTimeInterval(max(0, autoHideDelay))

        case .playbackPaused:
            state.isPlaying = false
            state.controlsVisible = true
            state.hideControlsAt = nil

        case .toggleBlackout:
            state.isBlackout.toggle()
            state.controlsVisible = !state.isBlackout
            state.hideControlsAt = nil

        case .timerFired:
            guard state.isPlaying,
                  let deadline = state.hideControlsAt,
                  now >= deadline else { return }
            state.controlsVisible = false
            state.hideControlsAt = nil

        case .appBecameInactive:
            state.isPlaying = false
            state.isBlackout = false
            state.controlsVisible = true
            state.hideControlsAt = nil
        }
    }
}

/// Keyboard, menu, and clicker command mapping for the Mac reader stage.
enum MacReaderCommand: Equatable, Sendable, CaseIterable {
    case playPause
    case blackout
    case slower
    case faster
    case nudgeBackward
    case nudgeForward
    case stepBackward
    case stepForward
    case exit
    case shortcutsHelp

    /// Default small arrow nudge (fraction of script length).
    static let defaultNudgeStep = 0.02
    /// Page Up / Page Down / clicker remote step — larger than arrow nudge.
    static let defaultRemoteStep = 0.04

    /// Maps key equivalents and character input for menus and KeyPress handlers.
    static func resolve(keyEquivalent: String?, characters: String) -> MacReaderCommand? {
        if let keyEquivalent {
            switch keyEquivalent {
            case " ": return .playPause
            case "\u{F700}", UIKeyUp: return .slower
            case "\u{F701}", UIKeyDown: return .faster
            case "\u{F702}", UIKeyLeft: return .nudgeBackward
            case "\u{F703}", UIKeyRight: return .nudgeForward
            case "\u{F72C}", "\u{21DE}": return .stepBackward // Page Up
            case "\u{F72D}", "\u{21DF}": return .stepForward // Page Down
            case "\u{1B}": return .exit
            default: break
            }
        }
        switch characters.lowercased() {
        case "b": return .blackout
        case "?": return .shortcutsHelp
        case " ": return .playPause
        default: return nil
        }
    }

    /// SwiftUI KeyEquivalent mapping used by the reader stage.
    static func resolve(characters: String) -> MacReaderCommand? {
        switch characters {
        case " ": return .playPause
        case "b", "B": return .blackout
        case "?": return .shortcutsHelp
        case "\u{1B}": return .exit
        default: return nil
        }
    }

    /// Applies a pure command to mutable reader chrome/speed/progress state.
    static func apply(
        _ command: MacReaderCommand,
        isPlaying: inout Bool,
        isBlackout: inout Bool,
        speedWPM: inout Double,
        progress: inout Double,
        nudgeStep: Double = MacReaderCommand.defaultNudgeStep,
        remoteStep: Double = MacReaderCommand.defaultRemoteStep
    ) -> MacReaderCommandEffect {
        switch command {
        case .playPause:
            if isBlackout {
                isBlackout = false
                return .revealChrome
            }
            isPlaying.toggle()
            return isPlaying ? .startedPlayback : .pausedPlayback
        case .blackout:
            isBlackout.toggle()
            if isBlackout { isPlaying = false }
            return .toggledBlackout
        case .slower:
            speedWPM = (speedWPM - 10).clamped(to: 40...400)
            return .speedChanged
        case .faster:
            speedWPM = (speedWPM + 10).clamped(to: 40...400)
            return .speedChanged
        case .nudgeBackward:
            progress = (progress - nudgeStep).clamped(to: 0...1)
            return .nudged
        case .nudgeForward:
            progress = (progress + nudgeStep).clamped(to: 0...1)
            return .nudged
        case .stepBackward:
            progress = (progress - remoteStep).clamped(to: 0...1)
            return .nudged
        case .stepForward:
            progress = (progress + remoteStep).clamped(to: 0...1)
            return .nudged
        case .exit:
            isPlaying = false
            isBlackout = false
            return .exit
        case .shortcutsHelp:
            return .showShortcuts
        }
    }

    var menuTitle: String {
        switch self {
        case .playPause: "Play/Pause"
        case .blackout: "Blackout"
        case .slower: "Decrease Speed"
        case .faster: "Increase Speed"
        case .nudgeBackward: "Nudge Backward"
        case .nudgeForward: "Nudge Forward"
        case .stepBackward: "Step Backward"
        case .stepForward: "Step Forward"
        case .exit: "Exit Reader"
        case .shortcutsHelp: "Keyboard Shortcuts"
        }
    }

    /// Documented clicker / keyboard mapping for help UI and tests.
    static let documentedMappings: [(command: MacReaderCommand, keys: String, note: String)] = [
        (.playPause, "Space", "Play or pause speed prompting"),
        (.blackout, "B", "Toggle full blackout; any key or click reveals"),
        (.slower, "↑", "Decrease speed by 10 WPM"),
        (.faster, "↓", "Increase speed by 10 WPM"),
        (.nudgeBackward, "←", "Nudge text backward"),
        (.nudgeForward, "→", "Nudge text forward"),
        (.stepBackward, "Page Up", "Clicker / remote previous step"),
        (.stepForward, "Page Down", "Clicker / remote next step"),
        (.exit, "Escape", "Close the reader window"),
        (.shortcutsHelp, "?", "Show keyboard and clicker shortcuts"),
    ]
}

enum MacReaderCommandEffect: Equatable, Sendable {
    case startedPlayback
    case pausedPlayback
    case toggledBlackout
    case revealChrome
    case speedChanged
    case nudged
    case exit
    case showShortcuts
}

// Private markers so arrow-key string constants stay local to this file.
private let UIKeyUp = "↑"
private let UIKeyDown = "↓"
private let UIKeyLeft = "←"
private let UIKeyRight = "→"

enum MacReaderSettingsPersistencePolicy {
    static func shouldFlush(for isActive: Bool) -> Bool {
        !isActive
    }
}

actor MacReaderSessionStore {
    enum StoreError: LocalizedError, Equatable {
        case unreadableData
        case unreadableDataResetFailed
        case unreadableDataWithoutRecovery

        var errorDescription: String? {
            switch self {
            case .unreadableData:
                "Phrasa could not read saved reader progress. A recovery copy was preserved, and reader progress was safely reset. Your script library is unchanged."
            case .unreadableDataResetFailed:
                "Phrasa preserved a recovery copy of unreadable reader progress but could not reset that progress file. Your script library is unchanged."
            case .unreadableDataWithoutRecovery:
                "Phrasa could not read saved reader progress or create a recovery copy. Your script library is unchanged."
            }
        }
    }

    private struct Archive: Codable, Sendable {
        var bookmarks: [MacReaderBookmark] = []
        var recaps: [MacReaderCompletionRecap] = []
    }

    private let fileURL: URL
    private var cachedArchive: Archive?

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = fileURL ?? base.appendingPathComponent("PhrasaMac", isDirectory: true)
            .appendingPathComponent("reader-sessions.json")
    }

    func bookmark(for scriptID: UUID, matchingBody body: String) throws -> MacReaderBookmark? {
        let candidate = try archive().bookmarks.first { $0.scriptID == scriptID }
        return candidate?.isResumeEligible(for: body) == true ? candidate : nil
    }

    func bookmark(for script: ScriptDocument) throws -> MacReaderBookmark? {
        let candidate = try archive().bookmarks.first { $0.scriptID == script.id }
        return candidate?.isResumeEligible(for: script) == true ? candidate : nil
    }

    func save(bookmark: MacReaderBookmark) throws {
        var value = try archive()
        value.bookmarks.removeAll { $0.scriptID == bookmark.scriptID }
        value.bookmarks.append(bookmark)
        try persist(value)
    }

    func clearBookmark(for scriptID: UUID) throws {
        var value = try archive()
        value.bookmarks.removeAll { $0.scriptID == scriptID }
        try persist(value)
    }

    func save(recap: MacReaderCompletionRecap) throws {
        var value = try archive()
        value.recaps.insert(recap, at: 0)
        if value.recaps.count > 50 {
            value.recaps = Array(value.recaps.prefix(50))
        }
        try persist(value)
    }

    func latestRecap(for scriptID: UUID) throws -> MacReaderCompletionRecap? {
        try archive().recaps.first { $0.scriptID == scriptID }
    }

    private func archive() throws -> Archive {
        if let cachedArchive { return cachedArchive }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Archive()
            cachedArchive = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(Archive.self, from: data)
            cachedArchive = decoded
            return decoded
        } catch {
            try recoverUnreadableArchive()
            throw StoreError.unreadableData
        }
    }

    private func persist(_ value: Archive) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
        cachedArchive = value
    }

    private func recoverUnreadableArchive() throws {
        let directory = fileURL.deletingLastPathComponent()
        let recovery = directory.appendingPathComponent(
            "reader-sessions-recovery-\(Int(Date.now.timeIntervalSince1970)).json"
        )
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.moveItem(at: fileURL, to: recovery)
            }
            cachedArchive = Archive()
            try persist(Archive())
        } catch {
            throw StoreError.unreadableDataResetFailed
        }
    }
}
