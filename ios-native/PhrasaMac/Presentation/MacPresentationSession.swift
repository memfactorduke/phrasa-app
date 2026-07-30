import AppKit
import Foundation
import PhrasaDomain

private final class MacSessionObserverHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func install(_ token: NSObjectProtocol) {
        lock.withLock {
            self.token = token
        }
    }

    func cancel() {
        let token = lock.withLock {
            defer { self.token = nil }
            return self.token
        }
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    deinit {
        cancel()
    }
}

/// Future Mac voice-follow seam. No Speech / microphone usage in this slice.
@MainActor
protocol MacVoiceFollowControlling: AnyObject {
    var isActive: Bool { get }
}

/// Canonical Mac presentation state: one progress, one clock, blackout/resume,
/// pre-roll, and completion hooks. Render surfaces are passive consumers.
@MainActor
@Observable
final class MacPresentationSession {
    private(set) var progress: Double = 0
    private(set) var isPlaying = false
    private(set) var isBlackout = false
    /// When blackout freezes an active run, reveal resumes without a second pre-roll.
    private(set) var resumeAfterBlackout = false
    private(set) var preRoll: Int?
    var speedWPM: Double = 140 {
        didSet {
            let clamped = speedWPM.clamped(to: 40...400)
            if speedWPM != clamped {
                speedWPM = clamped
            }
        }
    }
    /// Durable Speed-mode pre-roll length. Defaults to 5s (matches ReaderSettings).
    var speedCountdown: SpeedCountdown = .default

    private(set) var scriptBody: String = ""
    private(set) var wordCount: Int = 0

    /// Optional future voice controller; unused until a later slice.
    var voiceFollow: (any MacVoiceFollowControlling)?

    var onProgressChanged: ((Double) -> Void)?
    var onPlaybackStateChanged: (() -> Void)?
    var onCompleted: (() -> Void)?
    var onBeganActiveRun: (() -> Void)?

    let clock: MacPlaybackClock

    private var preRollTask: Task<Void, Never>?
    @ObservationIgnored private let appDeactivateObserver = MacSessionObserverHolder()
    private var hasCompleted = false
    private var isTornDown = false

    init(clock: MacPlaybackClock = MacPlaybackClock()) {
        self.clock = clock
        self.clock.onTick = { [weak self] delta in
            self?.handleClockTick(delta: delta)
        }
        appDeactivateObserver.install(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleAppDeactivation()
                }
            }
        )
    }

    func configure(
        scriptBody: String,
        progress: Double = 0,
        speedWPM: Double = 140,
        speedCountdown: SpeedCountdown = .default
    ) {
        self.scriptBody = scriptBody
        wordCount = TextMetrics.wordCount(scriptBody)
        self.speedWPM = speedWPM
        self.speedCountdown = speedCountdown
        setProgress(progress, notify: false)
        hasCompleted = false
    }

    /// Controller scrubbing / nudge. Audience must not call this.
    func setProgress(_ value: Double, notify: Bool = true) {
        let next = value.clamped(to: 0...1)
        guard progress != next else { return }
        progress = next
        if notify {
            onProgressChanged?(progress)
        }
        if progress >= 0.999, isPlaying {
            completeIfNeeded()
        }
    }

    /// Starts playback. When `withPreRoll` is true, uses `speedCountdown` only from
    /// script start (Off / mid-script / resume -> immediate). Blackout reveal never
    /// routes here for a second pre-roll.
    func play(withPreRoll: Bool = true) {
        guard !isTornDown else { return }
        if isBlackout {
            exitBlackout()
            return
        }
        if isPlaying, preRoll == nil { return }

        cancelPreRoll()
        let shouldCountdown = withPreRoll && SpeedModeStartPolicy.shouldBeginWithCountdown(
            mode: .speed,
            progress: progress,
            countdown: speedCountdown
        )
        if shouldCountdown {
            let sequence = speedCountdown.displaySequence
            preRoll = sequence.first
            preRollTask = Task { [weak self] in
                for value in sequence {
                    guard !Task.isCancelled else { return }
                    self?.preRoll = value
                    try? await Task.sleep(for: .seconds(1))
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.preRoll = nil
                guard !self.isTornDown,
                      self.progress < SpeedModeStartPolicy.nearStartThreshold else { return }
                self.startClock()
            }
        } else {
            startClock()
        }
    }

    func pause() {
        cancelPreRoll()
        guard isPlaying || clock.isRunning else {
            isPlaying = false
            onPlaybackStateChanged?()
            return
        }
        isPlaying = false
        clock.stop()
        resumeAfterBlackout = false
        onPlaybackStateChanged?()
    }

    func togglePlayPause() {
        if isBlackout {
            exitBlackout()
            return
        }
        if isPlaying || preRoll != nil {
            pause()
        } else {
            play(withPreRoll: true)
        }
    }

    /// Space / play-pause entry point. Cancels an active pre-roll instead of restarting it.
    func handlePlayPauseCommand() {
        togglePlayPause()
    }

    /// Enter blackout. Playing freezes the only clock and remembers resume intent.
    func enterBlackout() {
        guard !isBlackout else { return }
        cancelPreRoll()
        if isPlaying || clock.isRunning {
            resumeAfterBlackout = true
            // Blackout before isPlaying=false so pause observers skip bookmark persist.
            isBlackout = true
            isPlaying = false
            clock.freeze()
        } else {
            resumeAfterBlackout = false
            isBlackout = true
        }
        onPlaybackStateChanged?()
    }

    /// Reveal from blackout. Resumes only if it had been playing (no second pre-roll).
    func exitBlackout() {
        guard isBlackout else { return }
        let shouldResume = resumeAfterBlackout
        resumeAfterBlackout = false
        if shouldResume {
            // Unfreeze the existing clock — same active run, no second pre-roll.
            // isPlaying before clearing blackout so reveal observers can restart the tracker.
            hasCompleted = false
            isPlaying = true
            if clock.isFrozen {
                clock.unfreeze()
            } else if !clock.isRunning {
                clock.start()
            }
            isBlackout = false
            onPlaybackStateChanged?()
        } else {
            isBlackout = false
            onPlaybackStateChanged?()
        }
    }

    func toggleBlackout() {
        if isBlackout {
            exitBlackout()
        } else {
            enterBlackout()
        }
    }

    /// App deactivation pauses / cancels pre-roll and does not auto-resume.
    func handleAppDeactivation() {
        let wasActive = isPlaying || preRoll != nil || clock.isRunning || resumeAfterBlackout
        cancelPreRoll()
        resumeAfterBlackout = false
        if isPlaying || clock.isRunning {
            isPlaying = false
            clock.stop()
        }
        if isBlackout {
            // Keep blackout visual, but clear resume intent.
        }
        if wasActive {
            onPlaybackStateChanged?()
        }
    }

    func teardown() {
        // Exit + onDisappear can both call teardown; repeated calls are a no-op.
        guard !isTornDown else { return }
        isTornDown = true
        cancelPreRoll()
        resumeAfterBlackout = false
        isPlaying = false
        isBlackout = false
        clock.teardown()
        appDeactivateObserver.cancel()
        onProgressChanged = nil
        onPlaybackStateChanged = nil
        onCompleted = nil
        onBeganActiveRun = nil
        voiceFollow = nil
    }

    // MARK: - Internals

    private func startClock() {
        guard !isTornDown else { return }
        hasCompleted = false
        let wasPlaying = isPlaying
        isPlaying = true
        if !wasPlaying {
            onBeganActiveRun?()
        }
        clock.start()
        onPlaybackStateChanged?()
    }

    private func handleClockTick(delta: TimeInterval) {
        guard isPlaying, !isBlackout, !isTornDown else { return }
        let rate = Self.progressPerSecond(wordCount: wordCount, speedWPM: speedWPM)
        guard rate > 0 else { return }
        let next = min(1, progress + rate * max(0, delta))
        progress = next
        onProgressChanged?(progress)
        if progress >= 0.999 {
            completeIfNeeded()
        }
    }

    private func completeIfNeeded() {
        guard !hasCompleted else { return }
        hasCompleted = true
        isPlaying = false
        clock.stop()
        resumeAfterBlackout = false
        progress = 1
        onProgressChanged?(progress)
        onPlaybackStateChanged?()
        onCompleted?()
    }

    private func cancelPreRoll() {
        preRollTask?.cancel()
        preRollTask = nil
        preRoll = nil
    }

    /// Fraction of script advanced per second at the given WPM.
    static func progressPerSecond(wordCount: Int, speedWPM: Double) -> Double {
        let words = max(1, wordCount)
        guard speedWPM > 0 else { return 0 }
        let duration = Double(words) / speedWPM * 60
        guard duration > 0 else { return 0 }
        return 1 / duration
    }
}
