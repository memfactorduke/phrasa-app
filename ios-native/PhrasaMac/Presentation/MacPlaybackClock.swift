import AppKit
import Foundation
import QuartzCore

/// Single playback clock for a presentation session.
/// Exactly one timer/display-link may run; double-start is a no-op.
@MainActor
final class MacPlaybackClock {
    /// Fired on the main actor with a non-negative frame delta in seconds.
    var onTick: ((TimeInterval) -> Void)?

    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var lastTickAt: CFTimeInterval = 0
    private(set) var isRunning = false
    private(set) var isFrozen = false

    /// True while a display-link or fallback timer is installed.
    var hasActiveSource: Bool {
        displayLink != nil || fallbackTimer != nil
    }

    /// Starts the clock. Calling while already running is a no-op
    /// (unless frozen, in which case it unfreezes).
    func start() {
        if isRunning {
            if isFrozen {
                unfreeze()
            }
            return
        }
        isRunning = true
        isFrozen = false
        installSource()
    }

    /// Stops and tears down the clock source.
    func stop() {
        isRunning = false
        isFrozen = false
        removeSource()
    }

    /// Freezes ticks without releasing the running intent (blackout).
    func freeze() {
        guard isRunning else { return }
        isFrozen = true
        removeSource()
    }

    /// Resumes after freeze if the clock was running.
    func unfreeze() {
        guard isRunning, isFrozen else { return }
        isFrozen = false
        installSource()
    }

    /// Test seam: deliver a synthetic tick without a live display source.
    func tick(delta: TimeInterval) {
        guard isRunning, !isFrozen else { return }
        onTick?(max(0, delta))
    }

    func teardown() {
        stop()
        onTick = nil
    }

    private func installSource() {
        guard displayLink == nil, fallbackTimer == nil else { return }
        lastTickAt = CACurrentMediaTime()

        if let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            return
        }

        startFallbackTimer()
    }

    private func removeSource() {
        displayLink?.invalidate()
        displayLink = nil
        stopFallbackTimer()
    }

    private func startFallbackTimer() {
        stopFallbackTimer()
        lastTickAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleFallbackTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        guard isRunning, !isFrozen else { return }
        let delta = max(0, link.targetTimestamp - link.timestamp)
        onTick?(delta)
    }

    private func handleFallbackTick() {
        guard isRunning, !isFrozen else { return }
        let now = CACurrentMediaTime()
        let delta = max(0, now - lastTickAt)
        lastTickAt = now
        onTick?(delta)
    }
}
