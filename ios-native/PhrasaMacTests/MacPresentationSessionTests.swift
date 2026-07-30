import AppKit
import XCTest
import PhrasaDomain
@testable import PhrasaMac

// MARK: - Fakes

@MainActor
private final class FakeDisplayCatalog: MacDisplayCatalogProviding {
    var displays: [MacDisplayDescriptor] = []

    func currentDisplays() -> [MacDisplayDescriptor] {
        displays
    }
}

@MainActor
private final class FakeAudienceWindow: MacAudienceWindowControlling {
    private(set) var isVisible = false
    private(set) var currentFrame: CGRect?
    private(set) var presentCount = 0
    private(set) var hideCount = 0
    private(set) var reframeCount = 0
    private(set) var teardownCount = 0
    private(set) var lastContent: NSView?
    private(set) var bindCount = 0
    private(set) var boundControllerWindow: NSWindow?

    func bindControllerWindow(_ window: NSWindow?) {
        boundControllerWindow = window
        bindCount += 1
    }

    func present(frame: CGRect, content: NSView) {
        currentFrame = frame
        lastContent = content
        isVisible = true
        presentCount += 1
    }

    func reframe(to frame: CGRect) {
        currentFrame = frame
        reframeCount += 1
    }

    func hide() {
        isVisible = false
        hideCount += 1
    }

    func teardown() {
        hide()
        teardownCount += 1
        lastContent = nil
        currentFrame = nil
        boundControllerWindow = nil
    }
}

// MARK: - Tests

@MainActor
final class MacPresentationSessionTests: XCTestCase {

    // MARK: Display selection

    func testDisplaySelectionResolvesByStableIDNotIndex() {
        let a = MacDisplayDescriptor(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Studio",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isMain: true,
            isEphemeral: false
        )
        let b = MacDisplayDescriptor(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            name: "Confidence",
            frame: CGRect(x: 1920, y: 0, width: 1280, height: 720),
            isMain: false,
            isEphemeral: false
        )
        let displays = [a, b]

        XCTAssertEqual(
            MacDisplaySelectionResolver.resolve(selectedID: b.id, in: displays)?.name,
            "Confidence"
        )
        // Reordered list still resolves by ID.
        XCTAssertEqual(
            MacDisplaySelectionResolver.resolve(selectedID: b.id, in: [b, a])?.id,
            b.id
        )
        XCTAssertNil(
            MacDisplaySelectionResolver.resolve(
                selectedID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),
                in: displays
            )
        )
        XCTAssertFalse(
            MacDisplaySelectionResolver.isSelectionConnected(
                selectedID: UUID(),
                in: displays
            )
        )
    }

    func testStableDisplayIDIsDeterministicForSameDisplayID() {
        let first = MacSystemDisplayCatalog.stableID(for: 0x0042)
        let second = MacSystemDisplayCatalog.stableID(for: 0x0042)
        XCTAssertEqual(first.id, second.id)
        let other = MacSystemDisplayCatalog.stableID(for: 0x0043)
        // Distinct display IDs must not collide when both are ephemeral fallbacks.
        if first.isEphemeral && other.isEphemeral {
            XCTAssertNotEqual(first.id, other.id)
        }
    }

    // MARK: Disconnect / reconnect state machine

    func testAudienceDisconnectRetainsIntentAndReconnectRestores() {
        let catalog = FakeDisplayCatalog()
        let window = FakeAudienceWindow()
        let secondary = MacDisplayDescriptor(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            name: "Confidence",
            frame: CGRect(x: 1920, y: 0, width: 1280, height: 720),
            isMain: false,
            isEphemeral: false
        )
        catalog.displays = [secondary]

        let coordinator = MacAudienceOutputCoordinator(
            catalog: catalog,
            windowController: window
        )
        coordinator.selectDisplay(id: secondary.id)
        coordinator.setEnabled(true) {
            NSView(frame: .zero)
        }

        XCTAssertTrue(coordinator.isAudienceVisible)
        XCTAssertTrue(coordinator.hasVisibleAudienceOutput)
        XCTAssertNil(coordinator.statusMessage)
        XCTAssertEqual(window.presentCount, 1)

        // Disconnect selected screen — retain selection + enabled, hide, status.
        catalog.displays = []
        coordinator.applyDisplaysForTesting([])

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(coordinator.selectedDisplayID, secondary.id)
        XCTAssertFalse(coordinator.isAudienceVisible)
        XCTAssertFalse(coordinator.hasVisibleAudienceOutput)
        XCTAssertEqual(coordinator.statusMessage, "Audience display disconnected.")
        XCTAssertGreaterThanOrEqual(window.hideCount, 1)

        // Same UUID reconnects → re-open automatically while enabled.
        catalog.displays = [secondary]
        coordinator.applyDisplaysForTesting([secondary])

        XCTAssertTrue(coordinator.isAudienceVisible)
        XCTAssertTrue(coordinator.hasVisibleAudienceOutput)
        XCTAssertNil(coordinator.statusMessage)
        XCTAssertGreaterThan(window.presentCount, 1)

        // Never silently fall back: enabling with missing selection stays hidden.
        coordinator.selectDisplay(id: UUID())
        XCTAssertFalse(coordinator.isAudienceVisible)
        XCTAssertEqual(coordinator.statusMessage, "Audience display disconnected.")
    }

    func testAudienceDisableReleasesVisibilityWithoutClearingSelection() {
        let catalog = FakeDisplayCatalog()
        let window = FakeAudienceWindow()
        let display = MacDisplayDescriptor(
            id: UUID(),
            name: "Stage",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMain: false,
            isEphemeral: true
        )
        catalog.displays = [display]
        let coordinator = MacAudienceOutputCoordinator(
            catalog: catalog,
            windowController: window
        )
        coordinator.selectDisplay(id: display.id)
        coordinator.setEnabled(true) { NSView(frame: .zero) }
        XCTAssertTrue(coordinator.isAudienceVisible)

        coordinator.setEnabled(false)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(coordinator.isAudienceVisible)
        XCTAssertEqual(coordinator.selectedDisplayID, display.id)
        XCTAssertNil(coordinator.statusMessage)
    }

    /// Geometry change while already visible must reframe only — no extra present.
    func testGeometryChangeWhileVisibleReframesWithoutRePresenting() {
        let catalog = FakeDisplayCatalog()
        let window = FakeAudienceWindow()
        let id = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let initial = MacDisplayDescriptor(
            id: id,
            name: "Stage",
            frame: CGRect(x: 1920, y: 0, width: 1280, height: 720),
            isMain: false,
            isEphemeral: false
        )
        catalog.displays = [initial]
        let coordinator = MacAudienceOutputCoordinator(
            catalog: catalog,
            windowController: window
        )
        coordinator.selectDisplay(id: id)
        coordinator.setEnabled(true) { NSView(frame: .zero) }

        XCTAssertEqual(window.presentCount, 1)
        XCTAssertEqual(window.reframeCount, 0)
        XCTAssertEqual(window.currentFrame, initial.frame)

        let resized = MacDisplayDescriptor(
            id: id,
            name: "Stage",
            frame: CGRect(x: 1920, y: 0, width: 1600, height: 900),
            isMain: false,
            isEphemeral: false
        )
        coordinator.applyDisplaysForTesting([resized])

        XCTAssertEqual(window.presentCount, 1, "geometry refresh must not call present again")
        XCTAssertEqual(window.reframeCount, 1)
        XCTAssertEqual(window.currentFrame, resized.frame)
        XCTAssertTrue(coordinator.isAudienceVisible)
    }

    // MARK: Blackout

    func testBlackoutPlayingFreezesAndRevealResumesWithoutSecondPreRoll() {
        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "one two three four five six seven eight nine ten", speedWPM: 120)

        // Skip pre-roll for deterministic test.
        session.play(withPreRoll: false)
        XCTAssertTrue(session.isPlaying)
        XCTAssertTrue(clock.isRunning)

        clock.tick(delta: 1.0)
        let mid = session.progress
        XCTAssertGreaterThan(mid, 0)

        session.enterBlackout()
        XCTAssertTrue(session.isBlackout)
        XCTAssertTrue(session.resumeAfterBlackout)
        XCTAssertFalse(session.isPlaying)
        XCTAssertTrue(clock.isFrozen)
        XCTAssertFalse(clock.hasActiveSource)

        // Frozen clock must not advance progress.
        clock.tick(delta: 5.0)
        XCTAssertEqual(session.progress, mid, accuracy: 0.000_001)

        session.exitBlackout()
        XCTAssertFalse(session.isBlackout)
        XCTAssertFalse(session.resumeAfterBlackout)
        XCTAssertTrue(session.isPlaying)
        XCTAssertTrue(clock.isRunning)
        XCTAssertNil(session.preRoll)

        clock.tick(delta: 1.0)
        XCTAssertGreaterThan(session.progress, mid)
    }

    func testBlackoutWhilePausedStaysPausedOnReveal() {
        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "hello world again", speedWPM: 140)
        session.setProgress(0.25)

        XCTAssertFalse(session.isPlaying)
        session.enterBlackout()
        XCTAssertTrue(session.isBlackout)
        XCTAssertFalse(session.resumeAfterBlackout)

        session.exitBlackout()
        XCTAssertFalse(session.isBlackout)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(session.progress, 0.25, accuracy: 0.000_001)
    }

    // MARK: Pre-roll

    func testDefaultSpeedCountdownIsFiveSeconds() {
        let session = MacPresentationSession(clock: MacPlaybackClock())
        session.configure(scriptBody: "one two three four five", speedWPM: 120)
        XCTAssertEqual(session.speedCountdown, .fiveSeconds)

        session.play(withPreRoll: true)
        XCTAssertEqual(session.preRoll, 5)
        XCTAssertFalse(session.isPlaying)
        session.pause()
    }

    func testSpeedCountdownPolicyControlsPreRoll() {
        let session = MacPresentationSession(clock: MacPlaybackClock())
        session.configure(scriptBody: "one two three four five six", speedWPM: 120)

        session.speedCountdown = .off
        session.play(withPreRoll: true)
        XCTAssertNil(session.preRoll)
        XCTAssertTrue(session.isPlaying)
        session.pause()

        session.speedCountdown = .fiveSeconds
        session.play(withPreRoll: true)
        XCTAssertEqual(session.preRoll, 5)
        XCTAssertFalse(session.isPlaying)
        session.pause()

        session.speedCountdown = .fifteenSeconds
        session.play(withPreRoll: true)
        XCTAssertEqual(session.preRoll, 15)
        XCTAssertFalse(session.isPlaying)
        session.pause()

        session.setProgress(0.25)
        session.play(withPreRoll: true)
        XCTAssertNil(session.preRoll)
        XCTAssertTrue(session.isPlaying)
        session.pause()
    }

    func testConfigureThreadsSpeedCountdownAndBlackoutDoesNotRestartIt() {
        let session = MacPresentationSession(clock: MacPlaybackClock())
        session.configure(
            scriptBody: "one two three four five six seven eight",
            speedWPM: 120,
            speedCountdown: .fifteenSeconds
        )
        XCTAssertEqual(session.speedCountdown, .fifteenSeconds)

        session.play(withPreRoll: false)
        session.enterBlackout()
        session.exitBlackout()
        XCTAssertTrue(session.isPlaying)
        XCTAssertNil(session.preRoll)
        session.pause()
    }

    /// Space / playPause while pre-roll is active cancels the countdown, not restarts it.
    func testPlayPauseDuringPreRollCancelsCountdown() {
        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "one two three four five", speedWPM: 120)

        session.play(withPreRoll: true)
        XCTAssertNotNil(session.preRoll)
        XCTAssertEqual(session.preRoll, 5)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(clock.isRunning)

        // Session command path (Space / playPause) must cancel, not restart.
        session.handlePlayPauseCommand()
        XCTAssertNil(session.preRoll, "pre-roll must be cancelled")
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)

        // togglePlayPause is the same seam.
        session.play(withPreRoll: true)
        XCTAssertNotNil(session.preRoll)
        session.togglePlayPause()
        XCTAssertNil(session.preRoll)
        XCTAssertFalse(session.isPlaying)
    }

    // MARK: One clock / two renderers

    func testClockDoubleStartIsNoOpAndStopTeardown() {
        let clock = MacPlaybackClock()
        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)

        clock.start()
        XCTAssertTrue(clock.isRunning)
        XCTAssertTrue(clock.hasActiveSource)

        clock.start() // double-start no-op
        XCTAssertTrue(clock.isRunning)
        XCTAssertTrue(clock.hasActiveSource)

        clock.stop()
        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)

        clock.start()
        clock.teardown()
        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)
        XCTAssertNil(clock.onTick)
    }

    /// Two renderers (controller + audience) share one session clock; neither owns timers.
    func testTwoRenderersOneSessionClock() {
        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "a b c d e f g h", speedWPM: 180)

        let controllerSurface = MacPrompterTextView(
            text: "a b c d e f g h",
            settings: ReaderSettings(),
            progress: session.progress,
            allowsScrubbing: true,
            onProgressChange: { _ in }
        )
        let audienceSurface = MacPrompterTextView(
            text: "a b c d e f g h",
            settings: ReaderSettings(),
            progress: session.progress,
            allowsScrubbing: false,
            onProgressChange: nil
        )

        let controllerCoordinator = controllerSurface.makeCoordinator()
        let audienceCoordinator = audienceSurface.makeCoordinator()

        for (label, coordinator) in [
            ("controller", controllerCoordinator),
            ("audience", audienceCoordinator)
        ] as [(String, MacPrompterTextView.Coordinator)] {
            let propertyNames = Set(Mirror(reflecting: coordinator).children.compactMap(\.label))
            XCTAssertFalse(
                propertyNames.contains("displayLink"),
                "\(label) coordinator must not own a display link"
            )
            XCTAssertFalse(
                propertyNames.contains("fallbackTimer"),
                "\(label) coordinator must not own a fallback timer"
            )
            XCTAssertFalse(
                propertyNames.contains("clock"),
                "\(label) coordinator must not own a clock"
            )
            XCTAssertFalse(
                propertyNames.contains(where: { $0.lowercased().contains("timer") }),
                "\(label) coordinator must not own timer state"
            )
        }

        // Audience is strictly passive: no scrub / progress callback.
        XCTAssertFalse(audienceSurface.allowsScrubbing)
        XCTAssertNil(audienceSurface.onProgressChange)
        XCTAssertTrue(controllerSurface.allowsScrubbing)
        XCTAssertNotNil(controllerSurface.onProgressChange)

        // Surface values also expose no isPlaying — progress is external.
        let surfaceLabels = Set(Mirror(reflecting: audienceSurface).children.compactMap(\.label))
        XCTAssertFalse(surfaceLabels.contains("isPlaying"))
        XCTAssertTrue(surfaceLabels.contains("progress"))

        session.play(withPreRoll: false)
        XCTAssertTrue(session.clock === clock)
        XCTAssertTrue(clock.isRunning)
        XCTAssertTrue(clock.hasActiveSource)

        // Single active source: the session clock.
        XCTAssertTrue(session.clock.hasActiveSource)

        session.teardown()
        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)
    }

    func testSessionOwnsSingleClockAndPassiveSurfacesDoNotCreateClocks() {
        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "a b c d e f", speedWPM: 180)
        session.play(withPreRoll: false)

        // Session drives the one clock.
        XCTAssertTrue(session.clock === clock)
        XCTAssertTrue(clock.isRunning)

        // Passive render surfaces accept progress only — no play API / clock ownership.
        // Architectural proof: MacPrompterTextView has no isPlaying parameter.
        let mirror = Mirror(reflecting: MacPrompterTextView(
            text: "x",
            settings: ReaderSettings(),
            progress: 0.5,
            allowsScrubbing: false,
            onProgressChange: nil
        ))
        let labels = Set(mirror.children.compactMap(\.label))
        XCTAssertFalse(labels.contains("isPlaying"))
        XCTAssertTrue(labels.contains("progress"))
        XCTAssertTrue(labels.contains("allowsScrubbing"))

        session.teardown()
        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)
    }

    func testProgressRateMatchesWPMGeometry() {
        // 60 words at 60 WPM => 60s for full progress => 1/60 per second.
        let rate = MacPresentationSession.progressPerSecond(wordCount: 60, speedWPM: 60)
        XCTAssertEqual(rate, 1.0 / 60.0, accuracy: 0.000_001)

        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        let body = Array(repeating: "word", count: 60).joined(separator: " ")
        session.configure(scriptBody: body, speedWPM: 60)
        session.play(withPreRoll: false)
        clock.tick(delta: 30)
        XCTAssertEqual(session.progress, 0.5, accuracy: 0.001)
    }

    func testPacingLabelUsesSessionCachedWordCountAcrossDisplayTicks() {
        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        let body = Array(repeating: "word", count: 2_000).joined(separator: " ")
        session.configure(scriptBody: body, speedWPM: 120)

        XCTAssertEqual(session.wordCount, 2_000)
        XCTAssertEqual(
            MacPacingPresentation.remainingLabel(
                wordCount: session.wordCount,
                progress: 0.5,
                speedWPM: session.speedWPM
            ),
            "~8m 20s left"
        )

        session.play(withPreRoll: false)
        for _ in 0..<120 {
            clock.tick(delta: 1.0 / 120.0)
            _ = MacPacingPresentation.remainingLabel(
                wordCount: session.wordCount,
                progress: session.progress,
                speedWPM: session.speedWPM
            )
        }

        XCTAssertEqual(session.wordCount, 2_000)
        XCTAssertGreaterThan(session.progress, 0)
        session.teardown()
    }

    // MARK: Sleep policy

    func testOutputAwareSleepPolicy() {
        // No audience: playing only.
        XCTAssertTrue(
            MacDisplaySleepPolicy.shouldPreventSleep(
                isPresenting: true,
                isPlaying: true,
                hasVisibleAudienceOutput: false
            )
        )
        XCTAssertFalse(
            MacDisplaySleepPolicy.shouldPreventSleep(
                isPresenting: true,
                isPlaying: false,
                hasVisibleAudienceOutput: false
            )
        )

        // Visible audience: prevent sleep even while paused / blackout.
        XCTAssertTrue(
            MacDisplaySleepPolicy.shouldPreventSleep(
                isPresenting: true,
                isPlaying: false,
                hasVisibleAudienceOutput: true
            )
        )
        XCTAssertTrue(
            MacDisplaySleepPolicy.shouldPreventSleep(
                isPresenting: true,
                isPlaying: true,
                hasVisibleAudienceOutput: true
            )
        )

        // Not presenting or disconnected audience path.
        XCTAssertFalse(
            MacDisplaySleepPolicy.shouldPreventSleep(
                isPresenting: false,
                isPlaying: true,
                hasVisibleAudienceOutput: true
            )
        )
    }

    // MARK: Audience window traits + controller binding

    func testAudienceWindowTraits() {
        let controller = MacAudienceStageWindowController(offScreen: true)
        defer { controller.teardown() }

        guard let window = controller.window as? MacAudienceStageWindow else {
            XCTFail("Expected MacAudienceStageWindow")
            return
        }

        XCTAssertTrue(window.styleMask.contains(.borderless))
        // Custom borderless NSWindow subclass — not an NSPanel subclass.
        XCTAssertTrue(type(of: window) == MacAudienceStageWindow.self)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.isMovable)
        XCTAssertTrue(window.isOpaque)
        XCTAssertFalse(window.hasShadow)

        let behavior = window.collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
        XCTAssertTrue(behavior.contains(.fullScreenDisallowsTiling))
        XCTAssertFalse(behavior.contains(.stationary))

        // Keep off-screen; present without ordering onto a real display geometry.
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let frame = CGRect(x: -10_000, y: -10_000, width: 320, height: 180)
        controller.present(frame: frame, content: content)
        XCTAssertEqual(window.frame, frame)
        XCTAssertTrue(controller.isVisible)

        // After present, audience still cannot become key/main.
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(NSApp.keyWindow === window)

        if let background = window.backgroundColor?.usingColorSpace(.sRGB) {
            XCTAssertEqual(background.redComponent, 0, accuracy: 0.01)
            XCTAssertEqual(background.greenComponent, 0, accuracy: 0.01)
            XCTAssertEqual(background.blueComponent, 0, accuracy: 0.01)
        } else {
            XCTFail("Audience window background must be opaque black")
        }

        controller.hide()
        XCTAssertFalse(controller.isVisible)
    }

    /// Binding seam records the actual controller window; no arbitrary NSApp fallback.
    func testControllerWindowBindingSeam() {
        let fake = FakeAudienceWindow()
        let catalog = FakeDisplayCatalog()
        let display = MacDisplayDescriptor(
            id: UUID(),
            name: "Stage",
            frame: CGRect(x: -10_000, y: -10_000, width: 200, height: 100),
            isMain: false,
            isEphemeral: true
        )
        catalog.displays = [display]

        let coordinator = MacAudienceOutputCoordinator(
            catalog: catalog,
            windowController: fake
        )

        let controllerHost = NSWindow(
            contentRect: CGRect(x: -9_000, y: -9_000, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controllerHost.isReleasedWhenClosed = false
        defer { controllerHost.close() }

        XCTAssertNil(fake.boundControllerWindow)
        coordinator.bindControllerWindow(controllerHost)
        XCTAssertTrue(fake.boundControllerWindow === controllerHost)
        XCTAssertEqual(fake.bindCount, 1)
        XCTAssertTrue(coordinator.boundControllerWindow === controllerHost)

        coordinator.selectDisplay(id: display.id)
        coordinator.setEnabled(true) { NSView(frame: .zero) }
        XCTAssertEqual(fake.presentCount, 1)
        // Present path uses the bound controller only — fake records binding, not NSApp scans.
        XCTAssertTrue(fake.boundControllerWindow === controllerHost)

        // Real AppKit controller: bind + present keeps audience non-key.
        let real = MacAudienceStageWindowController(offScreen: true)
        defer { real.teardown() }
        real.bindControllerWindow(controllerHost)
        XCTAssertTrue(real.boundControllerWindow === controllerHost)

        let content = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        real.present(
            frame: CGRect(x: -10_000, y: -10_000, width: 100, height: 80),
            content: content
        )
        guard let audienceWindow = real.window as? MacAudienceStageWindow else {
            XCTFail("Expected MacAudienceStageWindow")
            return
        }
        XCTAssertFalse(audienceWindow.canBecomeKey)
        XCTAssertFalse(audienceWindow.canBecomeMain)
        XCTAssertFalse(NSApp.keyWindow === audienceWindow)
    }

    // MARK: App deactivation

    func testAppDeactivationPausesAndCancelsPreRollWithoutResume() {
        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "one two three", speedWPM: 100)
        session.play(withPreRoll: true)
        XCTAssertNotNil(session.preRoll)

        session.handleAppDeactivation()
        XCTAssertNil(session.preRoll)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(session.resumeAfterBlackout)

        // Playing then deactivate.
        session.play(withPreRoll: false)
        XCTAssertTrue(session.isPlaying)
        session.handleAppDeactivation()
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.resumeAfterBlackout)
    }

    func testTeardownCancelsClockAndAudience() {
        let catalog = FakeDisplayCatalog()
        let window = FakeAudienceWindow()
        let display = MacDisplayDescriptor(
            id: UUID(),
            name: "A",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMain: true,
            isEphemeral: true
        )
        catalog.displays = [display]

        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "words here", speedWPM: 140)
        session.play(withPreRoll: false)

        let audience = MacAudienceOutputCoordinator(
            catalog: catalog,
            windowController: window
        )
        audience.selectDisplay(id: display.id)
        audience.setEnabled(true) { NSView(frame: .zero) }
        XCTAssertTrue(audience.isAudienceVisible)

        session.teardown()
        audience.teardown()

        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)
        XCTAssertFalse(audience.isAudienceVisible)
        XCTAssertFalse(audience.isEnabled)
        XCTAssertEqual(window.teardownCount, 1)
    }

    /// Exit then onDisappear can both call teardown — second call is a no-op.
    func testTeardownIsIdempotent() {
        let catalog = FakeDisplayCatalog()
        let window = FakeAudienceWindow()
        let display = MacDisplayDescriptor(
            id: UUID(),
            name: "A",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMain: true,
            isEphemeral: true
        )
        catalog.displays = [display]

        let clock = MacPlaybackClock()
        let session = MacPresentationSession(clock: clock)
        session.configure(scriptBody: "words here", speedWPM: 140)
        session.play(withPreRoll: false)

        let audience = MacAudienceOutputCoordinator(
            catalog: catalog,
            windowController: window
        )
        audience.selectDisplay(id: display.id)
        audience.setEnabled(true) { NSView(frame: .zero) }

        session.teardown()
        session.teardown()
        audience.teardown()
        audience.teardown()

        XCTAssertFalse(clock.isRunning)
        XCTAssertFalse(clock.hasActiveSource)
        XCTAssertEqual(window.teardownCount, 1, "window teardown must run once")
        XCTAssertFalse(audience.isEnabled)
        // Further play after tear-down is ignored.
        session.play(withPreRoll: false)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(clock.isRunning)
    }
}
