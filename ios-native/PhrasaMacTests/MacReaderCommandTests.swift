import AppKit
import XCTest
import PhrasaDomain
@testable import PhrasaMac

final class MacReaderCommandTests: XCTestCase {
    func testDocumentedMappingsCoverCoreControls() {
        let commands = Set(MacReaderCommand.documentedMappings.map(\.command))
        XCTAssertTrue(commands.contains(.playPause))
        XCTAssertTrue(commands.contains(.blackout))
        XCTAssertTrue(commands.contains(.slower))
        XCTAssertTrue(commands.contains(.faster))
        XCTAssertTrue(commands.contains(.nudgeBackward))
        XCTAssertTrue(commands.contains(.nudgeForward))
        XCTAssertTrue(commands.contains(.stepBackward))
        XCTAssertTrue(commands.contains(.stepForward))
        XCTAssertTrue(commands.contains(.exit))
        XCTAssertTrue(commands.contains(.shortcutsHelp))
    }

    func testPageKeysResolveToRemoteSteps() {
        XCTAssertEqual(
            MacReaderCommand.resolve(keyEquivalent: "\u{F72C}", characters: ""),
            .stepBackward
        )
        XCTAssertEqual(
            MacReaderCommand.resolve(keyEquivalent: "\u{F72D}", characters: ""),
            .stepForward
        )
    }

    func testRemoteStepIsLargerThanArrowNudge() {
        var playing = false
        var blackout = false
        var speed = 140.0
        var progress = 0.5

        _ = MacReaderCommand.apply(
            .nudgeForward,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress
        )
        let afterNudge = progress
        progress = 0.5
        _ = MacReaderCommand.apply(
            .stepForward,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress
        )
        XCTAssertGreaterThan(progress - 0.5, afterNudge - 0.5)
        XCTAssertEqual(progress, 0.5 + MacReaderCommand.defaultRemoteStep, accuracy: 0.0001)
    }

    func testReaderThemesAreStrictlyMonochrome() {
        for theme in ReaderTheme.allCases {
            XCTAssertTrue(isMonochrome(theme.nsBackground), "\(theme.rawValue) background")
            XCTAssertTrue(isMonochrome(theme.nsForeground), "\(theme.rawValue) foreground")
            XCTAssertGreaterThan(
                contrastRatio(theme.nsForeground, theme.nsBackground),
                4.5,
                "\(theme.rawValue) must keep WCAG AA body contrast"
            )
        }
        assertNSColor(ReaderTheme.paper.nsBackground, r: 1, g: 1, b: 1)
        assertNSColor(ReaderTheme.paper.nsForeground, r: 0, g: 0, b: 0)
        assertNSColor(ReaderTheme.stage.nsBackground, r: 0, g: 0, b: 0)
        assertNSColor(ReaderTheme.stage.nsForeground, r: 1, g: 1, b: 1)
        assertNSColor(ReaderTheme.amber.nsBackground, r: 10 / 255, g: 10 / 255, b: 10 / 255)
        assertNSColor(ReaderTheme.sepia.nsBackground, r: 18 / 255, g: 18 / 255, b: 18 / 255)
    }

    private func srgbComponents(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    private func isMonochrome(_ color: NSColor) -> Bool {
        guard let c = srgbComponents(color) else { return false }
        return abs(c.r - c.g) < 0.001 && abs(c.g - c.b) < 0.001
    }

    private func assertNSColor(
        _ color: NSColor,
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        accuracy: CGFloat = 0.002,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let c = srgbComponents(color) else {
            XCTFail("could not convert color to sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(c.r, r, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.g, g, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.b, b, accuracy: accuracy, file: file, line: line)
    }

    private func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = srgbComponents(color) else { return 0 }
            func channel(_ value: CGFloat) -> CGFloat {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.r)
                + 0.7152 * channel(c.g)
                + 0.0722 * channel(c.b)
        }
        let l1 = luminance(foreground)
        let l2 = luminance(background)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func testCharacterResolutionMatchesSpec() {
        XCTAssertEqual(MacReaderCommand.resolve(characters: " "), .playPause)
        XCTAssertEqual(MacReaderCommand.resolve(characters: "b"), .blackout)
        XCTAssertEqual(MacReaderCommand.resolve(characters: "B"), .blackout)
        XCTAssertEqual(MacReaderCommand.resolve(characters: "?"), .shortcutsHelp)
        XCTAssertEqual(MacReaderCommand.resolve(characters: "\u{1B}"), .exit)
        XCTAssertNil(MacReaderCommand.resolve(characters: "x"))
    }

    func testApplyPlayPauseAndBlackout() {
        var playing = false
        var blackout = false
        var speed = 140.0
        var progress = 0.2

        let start = MacReaderCommand.apply(
            .playPause,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress
        )
        XCTAssertEqual(start, .startedPlayback)
        XCTAssertTrue(playing)

        let blackoutEffect = MacReaderCommand.apply(
            .blackout,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress
        )
        XCTAssertEqual(blackoutEffect, .toggledBlackout)
        XCTAssertTrue(blackout)
        XCTAssertFalse(playing)

        let reveal = MacReaderCommand.apply(
            .playPause,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress
        )
        XCTAssertEqual(reveal, .revealChrome)
        XCTAssertFalse(blackout)
    }

    func testSpeedAndNudgeClamp() {
        var playing = false
        var blackout = false
        var speed = 40.0
        var progress = 0.0

        _ = MacReaderCommand.apply(
            .slower,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress
        )
        XCTAssertEqual(speed, 40)

        speed = 400
        _ = MacReaderCommand.apply(
            .faster,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress
        )
        XCTAssertEqual(speed, 400)

        progress = 0.99
        _ = MacReaderCommand.apply(
            .nudgeForward,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress,
            nudgeStep: 0.05
        )
        XCTAssertEqual(progress, 1.0, accuracy: 0.0001)

        progress = 0.01
        _ = MacReaderCommand.apply(
            .nudgeBackward,
            isPlaying: &playing,
            isBlackout: &blackout,
            speedWPM: &speed,
            progress: &progress,
            nudgeStep: 0.05
        )
        XCTAssertEqual(progress, 0.0, accuracy: 0.0001)
    }

    func testOverlayReducerAutoHideAndBlackout() {
        var state = MacReaderOverlayState()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        MacReaderOverlayReducer.reduce(&state, event: .playbackStarted, now: now)
        XCTAssertTrue(state.isPlaying)
        XCTAssertNotNil(state.hideControlsAt)

        MacReaderOverlayReducer.reduce(
            &state,
            event: .timerFired,
            now: now.addingTimeInterval(3)
        )
        XCTAssertFalse(state.controlsVisible)

        MacReaderOverlayReducer.reduce(&state, event: .toggleBlackout, now: now)
        XCTAssertTrue(state.isBlackout)
        XCTAssertFalse(state.controlsVisible)

        MacReaderOverlayReducer.reduce(&state, event: .stageTapped, now: now)
        XCTAssertFalse(state.isBlackout)
        XCTAssertTrue(state.controlsVisible)
    }

    func testDisplaySleepPolicy() {
        XCTAssertTrue(MacDisplaySleepPolicy.shouldPreventSleep(isPresenting: true, isPlaying: true))
        XCTAssertFalse(MacDisplaySleepPolicy.shouldPreventSleep(isPresenting: true, isPlaying: false))
        XCTAssertFalse(MacDisplaySleepPolicy.shouldPreventSleep(isPresenting: false, isPlaying: true))
    }

    func testPrompterGeometryFocusAndSpeed() {
        let focus = MacPrompterGeometry.contentFocusY(
            height: 100,
            focusPosition: 0.4
        )
        XCTAssertEqual(focus, 40, accuracy: 0.001)

        let mirrored = MacPrompterGeometry.visibleFocusY(
            height: 100,
            focusPosition: 0.4,
            mirrorVertical: true
        )
        XCTAssertEqual(mirrored, 60, accuracy: 0.001)

        let pps = MacPrompterGeometry.pointsPerSecond(
            wordCount: 150,
            speedWPM: 150,
            maximumOffset: 600
        )
        // 150 words at 150 WPM => 60s across 600 points => 10 pts/s
        XCTAssertEqual(pps, 10, accuracy: 0.001)
    }

    /// Bottom chrome must reserve stage height so script never sits under controls.
    /// Hidden chrome → full stage. Focus stays inside the readable stage with mirror.
    func testReadableStageExcludesBottomChromeAndKeepsFocusInside() {
        let fixtures: [(stage: CGFloat, chrome: CGFloat, label: String)] = [
            (900, 160, "Mac window + bottom controls"),
            (1_200, 180, "Mac full screen + audience row"),
            (700, 0, "chrome hidden uses full stage"),
        ]

        for fixture in fixtures {
            let readable = MacPrompterGeometry.readableHeight(
                viewportHeight: fixture.stage,
                bottomChromeHeight: fixture.chrome
            )
            XCTAssertEqual(
                readable,
                fixture.stage - fixture.chrome,
                accuracy: 0.001,
                fixture.label
            )
            XCTAssertEqual(
                MacPrompterGeometry.readableHeight(
                    viewportHeight: fixture.stage,
                    bottomChromeHeight: -12
                ),
                fixture.stage,
                accuracy: 0.001,
                "negative chrome is treated as none — \(fixture.label)"
            )

            for focus in [0.15, 0.25, 0.5, 0.85] as [Double] {
                for mirrored in [false, true] {
                    XCTAssertTrue(
                        MacPrompterGeometry.focusLineIsReadable(
                            readableHeight: readable,
                            focusPosition: focus,
                            mirrorVertical: mirrored
                        ),
                        "focus \(focus) mirrored=\(mirrored) — \(fixture.label)"
                    )
                    let focusY = MacPrompterGeometry.visibleFocusY(
                        height: readable,
                        focusPosition: focus,
                        mirrorVertical: mirrored
                    )
                    XCTAssertLessThanOrEqual(
                        focusY,
                        readable + 0.001,
                        "\(fixture.label) focus under chrome"
                    )
                    if fixture.chrome > 0 {
                        XCTAssertLessThan(
                            focusY,
                            fixture.stage - fixture.chrome + 0.001,
                            "\(fixture.label) focus must be above chrome top"
                        )
                    }
                }
            }
        }
    }

    func testSessionTrackerResumeAndRecap() {
        let scriptID = UUID()
        let body = Array(repeating: "word", count: 100).joined(separator: " ")
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        var first = MacReaderSessionTracker(scriptID: scriptID, body: body)
        first.start(at: start)
        first.update(progress: 0.4)
        let bookmark = first.pause(at: start.addingTimeInterval(20))

        XCTAssertTrue(bookmark.isResumeEligible(for: body))
        XCTAssertFalse(bookmark.isResumeEligible(for: body + " edited"))

        var resumed = MacReaderSessionTracker(scriptID: scriptID, body: body, bookmark: bookmark)
        XCTAssertEqual(resumed.progress, 0.4, accuracy: 0.0001)
        XCTAssertTrue(resumed.wasResumed)
        resumed.start(at: start.addingTimeInterval(60))
        let recap = resumed.complete(at: start.addingTimeInterval(100), targetDuration: 55)
        XCTAssertEqual(recap.activeTime, 60, accuracy: 0.001)
        XCTAssertEqual(recap.wordCount, 100)
        XCTAssertTrue(recap.wasResumed)
    }

    /// 10s playing + 50s blackout + 10s resumed => 20s activeTime (not 70).
    func testBlackoutIsExcludedFromActiveTime() {
        let scriptID = UUID()
        let body = Array(repeating: "word", count: 100).joined(separator: " ")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        var tracker = MacReaderSessionTracker(scriptID: scriptID, body: body)
        tracker.start(at: t0)
        tracker.update(progress: 0.1)

        // 10 seconds playing, then blackout suspends the tracker (no bookmark persist).
        MacReaderBlackoutActiveTimeSync.suspendForBlackout(
            tracker: &tracker,
            at: t0.addingTimeInterval(10)
        )
        XCTAssertFalse(tracker.isActive)

        // 50 seconds blackout elapses without active accumulation.
        // Reveal resumes playback → restart tracker.
        MacReaderBlackoutActiveTimeSync.resumeAfterBlackoutIfNeeded(
            tracker: &tracker,
            playbackResumed: true,
            at: t0.addingTimeInterval(60)
        )
        XCTAssertTrue(tracker.isActive)
        tracker.update(progress: 0.2)

        // 10 more seconds playing after reveal.
        let recap = tracker.complete(at: t0.addingTimeInterval(70), targetDuration: nil)
        XCTAssertEqual(recap.activeTime, 20, accuracy: 0.001)
        XCTAssertNotEqual(recap.activeTime, 70, accuracy: 0.001)
    }

    /// Paused → blackout → reveal must not activate the tracker.
    func testPausedBlackoutRevealDoesNotActivateTracker() {
        let scriptID = UUID()
        let body = "hello world pause blackout"
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        var tracker = MacReaderSessionTracker(scriptID: scriptID, body: body)
        tracker.start(at: t0)
        _ = tracker.pause(at: t0.addingTimeInterval(5))
        XCTAssertFalse(tracker.isActive)

        MacReaderBlackoutActiveTimeSync.suspendForBlackout(
            tracker: &tracker,
            at: t0.addingTimeInterval(10)
        )
        XCTAssertFalse(tracker.isActive)

        MacReaderBlackoutActiveTimeSync.resumeAfterBlackoutIfNeeded(
            tracker: &tracker,
            playbackResumed: false,
            at: t0.addingTimeInterval(40)
        )
        XCTAssertFalse(tracker.isActive)

        // Completing while still paused banks only the earlier 5s of play.
        let recap = tracker.complete(at: t0.addingTimeInterval(40), targetDuration: nil)
        XCTAssertEqual(recap.activeTime, 5, accuracy: 0.001)
    }

    func testPlaybackGateRequiresReadyTracker() {
        XCTAssertFalse(MacReaderSessionInteractionGate.allowsPlayback(sessionIsReady: false, hasTracker: true))
        XCTAssertFalse(MacReaderSessionInteractionGate.allowsPlayback(sessionIsReady: true, hasTracker: false))
        XCTAssertTrue(MacReaderSessionInteractionGate.allowsPlayback(sessionIsReady: true, hasTracker: true))
    }

    func testSettingsFlushPolicy() {
        XCTAssertFalse(MacReaderSettingsPersistencePolicy.shouldFlush(for: true))
        XCTAssertTrue(MacReaderSettingsPersistencePolicy.shouldFlush(for: false))
    }
}
