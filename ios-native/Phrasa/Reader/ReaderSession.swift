import Foundation

/// A stable, process-independent signature used to avoid resuming at the wrong
/// location after a script has been edited.
enum ReaderContentSignature {
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

/// Shipping reader resume envelope. Embeds the domain `ResumeBookmark` context
/// (token index, speed progress, mode, speed) while remaining Codable-compatible
/// with legacy v1 archives that only stored scalar progress + body hash.
struct ReaderBookmark: Codable, Equatable, Sendable {
    let scriptID: UUID
    /// Legacy body-only hash retained for v1 archive compatibility.
    let contentSignature: String
    var progress: Double
    /// Voice/speed focus token index from domain resume context.
    var focusTokenIndex: Int
    var mode: ReaderMode
    var speedWPM: Double
    /// Domain title+body signature when available (v2+).
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
        // Derive a token index from scalar progress when upgrading a v1 archive.
        if focusTokenIndex == 0, progress > 0, !container.contains(.focusTokenIndex) {
            // Leave 0; callers with token counts refine via domainResume(tokenCount:).
        }
    }

    /// Builds a shipping bookmark that carries full domain resume context.
    static func make(
        script: ScriptDocument,
        progress: Double,
        focusTokenIndex: Int,
        mode: ReaderMode,
        speedWPM: Double,
        elapsedActiveTime: TimeInterval,
        activeRunCount: Int,
        updatedAt: Date
    ) -> ReaderBookmark {
        ReaderBookmark(
            scriptID: script.id,
            contentSignature: ReaderContentSignature.make(for: script.body),
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

    /// Domain resume context used for validation and cross-layer resume.
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
        contentSignature == ReaderContentSignature.make(for: body)
            && progress >= minimumProgress
            && progress < completionThreshold
    }

    /// Prefer domain title+body signature when present; fall back to body hash.
    func isResumeEligible(
        for script: ScriptDocument,
        minimumProgress: Double = 0.01,
        completionThreshold: Double = 0.999
    ) -> Bool {
        guard script.id == scriptID else { return false }
        if let domainContentSignature {
            guard domainContentSignature == ScriptContentSignature.make(script) else { return false }
        } else {
            guard contentSignature == ReaderContentSignature.make(for: script.body) else { return false }
        }
        return progress >= minimumProgress && progress < completionThreshold
    }
}

struct ReaderCompletionRecap: Identifiable, Codable, Equatable, Sendable {
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

struct ReaderHistoryStatistics: Equatable, Sendable {
    let completedSessions: Int
    let totalActiveTime: TimeInterval
    let totalWordsPresented: Int
    let averageWordsPerMinute: Double

    static func summarize(_ recaps: [ReaderCompletionRecap]) -> Self {
        let totalTime = recaps.reduce(0) { $0 + $1.activeTime }
        let totalWords = recaps.reduce(0) { $0 + $1.wordCount }
        return Self(
            completedSessions: recaps.count,
            totalActiveTime: totalTime,
            totalWordsPresented: totalWords,
            averageWordsPerMinute: totalTime > 0 ? Double(totalWords) / totalTime * 60 : 0
        )
    }
}

enum ReaderSessionInteractionGate {
    static func allowsPlayback(sessionIsReady: Bool, hasTracker: Bool) -> Bool {
        sessionIsReady && hasTracker
    }
}

enum ReaderBookmarkPersistencePolicy {
    static func shouldSaveAfterPause(_ tracker: ReaderSessionTracker) -> Bool {
        tracker.activeRunCount > 0
    }
}

/// Pure session state. Callers inject timestamps, keeping elapsed-time and
/// recap calculations deterministic and straightforward to test.
struct ReaderSessionTracker: Sendable {
    let scriptID: UUID
    let contentSignature: String
    let wordCount: Int
    /// Captured at resume so subsequent pauses re-persist the same context.
    private(set) var resumedMode: ReaderMode?
    private(set) var resumedSpeedWPM: Double?
    private(set) var focusTokenIndex: Int

    private(set) var progress: Double
    private(set) var elapsedActiveTime: TimeInterval
    private(set) var activeRunCount: Int
    private(set) var wasResumed: Bool
    private var activeSince: Date?

    init(scriptID: UUID, body: String, bookmark: ReaderBookmark? = nil) {
        self.scriptID = scriptID
        contentSignature = ReaderContentSignature.make(for: body)
        wordCount = TextMetrics.wordCount(body)

        if let bookmark,
           bookmark.scriptID == scriptID,
           bookmark.isResumeEligible(for: body) {
            progress = bookmark.progress
            elapsedActiveTime = bookmark.elapsedActiveTime
            activeRunCount = bookmark.activeRunCount
            focusTokenIndex = bookmark.focusTokenIndex
            resumedMode = bookmark.mode
            resumedSpeedWPM = bookmark.speedWPM
            wasResumed = true
        } else {
            progress = 0
            elapsedActiveTime = 0
            activeRunCount = 0
            focusTokenIndex = 0
            resumedMode = nil
            resumedSpeedWPM = nil
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
    ) -> ReaderBookmark {
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
    ) -> ReaderBookmark {
        let runningTime = activeSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        let effectiveMode = mode
        let effectiveSpeed = speedWPM
        if let script {
            return ReaderBookmark.make(
                script: script,
                progress: progress,
                focusTokenIndex: focusTokenIndex,
                mode: effectiveMode,
                speedWPM: effectiveSpeed,
                elapsedActiveTime: elapsedActiveTime + runningTime,
                activeRunCount: activeRunCount,
                updatedAt: date
            )
        }
        return ReaderBookmark(
            scriptID: scriptID,
            contentSignature: contentSignature,
            progress: progress,
            focusTokenIndex: focusTokenIndex,
            mode: effectiveMode,
            speedWPM: effectiveSpeed,
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
    ) -> ReaderCompletionRecap {
        _ = pause(at: date)
        progress = 1
        return ReaderCompletionRecap(
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

struct ReaderOverlayState: Equatable, Sendable {
    var controlsVisible = true
    var isPlaying = false
    var isBlackout = false
    var hideControlsAt: Date?
}

enum ReaderOverlayEvent: Equatable, Sendable {
    case stageTapped
    case playbackStarted
    case playbackPaused
    case toggleBlackout
    case timerFired
    case appBecameInactive
}

/// A small reducer for chrome and blackout behavior. It contains no timers;
/// the view schedules one for `hideControlsAt` and sends `.timerFired`.
enum ReaderOverlayReducer {
    static func reduce(
        _ state: inout ReaderOverlayState,
        event: ReaderOverlayEvent,
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

/// Serializes reader-session writes in the order the UI requested them. Swift
/// actors protect the file from simultaneous access, but separate unstructured
/// tasks can still arrive at an actor out of order; this chain preserves the
/// user's save, restart, and completion intent across those suspension points.
@MainActor
final class ReaderSessionMutationQueue {
    private var tail: Task<Void, Never>?

    func enqueue(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let previous = tail
        tail = Task { @MainActor in
            if let previous { await previous.value }
            await operation()
        }
    }

    func waitForAll() async {
        if let tail { await tail.value }
    }
}

actor ReaderSessionStore {
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
        var bookmarks: [ReaderBookmark] = []
        var recaps: [ReaderCompletionRecap] = []
    }

    private let fileURL: URL
    private var cachedArchive: Archive?

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = fileURL ?? base.appendingPathComponent("Phrasa", isDirectory: true)
            .appendingPathComponent("reader-sessions.json")
    }

    func bookmark(for scriptID: UUID, matchingBody body: String) throws -> ReaderBookmark? {
        let candidate = try archive().bookmarks.first { $0.scriptID == scriptID }
        return candidate?.isResumeEligible(for: body) == true ? candidate : nil
    }

    func bookmark(for script: ScriptDocument) throws -> ReaderBookmark? {
        let candidate = try archive().bookmarks.first { $0.scriptID == script.id }
        return candidate?.isResumeEligible(for: script) == true ? candidate : nil
    }

    func save(bookmark: ReaderBookmark) throws {
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

    func save(recap: ReaderCompletionRecap, retainLimit: Int = 200) throws {
        var value = try archive()
        value.recaps.removeAll { $0.id == recap.id }
        value.recaps.append(recap)
        value.recaps.sort { $0.completedAt > $1.completedAt }
        value.recaps = Array(value.recaps.prefix(max(0, retainLimit)))
        value.bookmarks.removeAll { $0.scriptID == recap.scriptID }
        try persist(value)
    }

    func recentRecaps(limit: Int = 20) throws -> [ReaderCompletionRecap] {
        Array(try archive().recaps.prefix(max(0, limit)))
    }

    func statistics() throws -> ReaderHistoryStatistics {
        ReaderHistoryStatistics.summarize(try archive().recaps)
    }

    private func archive() throws -> Archive {
        if let cachedArchive { return cachedArchive }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Archive()
            cachedArchive = empty
            return empty
        }
        do {
            let decoded = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            cachedArchive = decoded
            return decoded
        } catch {
            let recoveryURL = fileURL.deletingPathExtension()
                .appendingPathExtension(
                    "recovery-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString).json"
                )
            do {
                try FileManager.default.copyItem(at: fileURL, to: recoveryURL)
            } catch {
                throw StoreError.unreadableDataWithoutRecovery
            }
            do {
                try persist(Archive())
            } catch {
                throw StoreError.unreadableDataResetFailed
            }
            throw StoreError.unreadableData
        }
    }

    private func persist(_ value: Archive) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: [.atomic, .completeFileProtection])
        cachedArchive = value
    }
}
