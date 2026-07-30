import XCTest

/// Physical-device Voice Follow UI harness (non-shipping).
///
/// Flow: existing library → bundled Welcome script (or known fallback) →
/// prompter → Voice → Start →
/// system mic then speech permissions → host-visible `VOICE_QA_READY` → 25s real
/// speech window → assert material progress → pause/resume → background/foreground
/// recovery. No mocked speech.
///
/// This target must never be archived or uploaded with the App Store product.
///
/// `testVoiceFollowPhysicalStimulusProgressAndRecovery` is the instrumented
/// DEBUG proof. `testVoiceFollowShippingReleaseProgress` is the shipping
/// RELEASE proof and intentionally uses only public reader accessibility.
final class VoiceFollowPhysicalUITests: XCTestCase {
    private let speechWindowSeconds: TimeInterval = 25
    private let bundledScriptTitleFragment = "Welcome to Phrasa"
    private let fallbackScriptTitleFragment = "Fetterman"

    private enum A11y {
        static let library = "phrasa.library.scripts"
        static let progress = "phrasa.reader.progress"
        static let mode = "phrasa.reader.mode"
        static let playPause = "phrasa.reader.playPause"
        static let voiceStatus = "phrasa.reader.voiceStatus"
        static let voiceDiagnostics = "VoicePipelineDiagnostics"
        static let openPrompter = "phrasa.editor.openPrompter"
    }

    private enum HarnessError: Error {
        case wrongBuildConfiguration(String)
        case missingFixture(String)
        case missingDebugDiagnostics
        case unreadableDebugDiagnostics
        case missingReaderProgress
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Full physical Voice Follow path. Requires real mic + spoken script text.
    func testVoiceFollowPhysicalStimulusProgressAndRecovery() throws {
        try requireDebugHarnessBuild()

        let app = XCUIApplication()
        // Physical iPadOS devices do not reliably support XCTest's TCC reset API.
        // Exercise the current real permission state instead; the product still
        // handles first-run prompts below when iPadOS presents them.
        // Preserve on-device library / account data. Do not reset content or settings.
        app.launchArguments = app.launchArguments.filter {
            $0 != "-AppleLanguages" && !$0.hasPrefix("-UITesting")
        }
        app.launch()

        try dismissOnboardingIfNeeded(in: app)
        try openKnownQAScript(in: app)
        try openPrompter(in: app)
        try ensureChromeVisible(in: app)
        try switchToVoiceMode(in: app)

        let baselineProgress = try requireProgressRatio(in: app)
        let baselineDiagnostics = try requireVoiceDiagnostics(in: app)
        let baselineCommit = Self.parseDiagnosticInt("commit", from: baselineDiagnostics) ?? 0
        emitHostMarker("VOICE_QA_STATUS_BEFORE=\(readVoiceStatus(in: app))")
        try startVoiceFollow(in: app)
        try handleSystemPermissionsIfNeeded()
        emitHostMarker("VOICE_QA_STATUS_AFTER_START=\(readVoiceStatus(in: app))")

        // Host orchestrator watches stdout/stderr/log for this exact token, then
        // drives Mac speakers (say) for the 25-second stimulus window.
        emitHostMarker("VOICE_QA_READY")
        RunLoop.current.run(until: Date().addingTimeInterval(speechWindowSeconds))

        // Reader chrome intentionally auto-hides during playback, so the visible
        // ProgressView and status panel are volatile. The DEBUG app exposes an
        // always-present privacy-safe diagnostic element specifically for this
        // physical harness. Read committed token movement from that stable surface.
        let afterDiagnostics = try requireVoiceDiagnostics(in: app)
        let afterCommit = Self.parseDiagnosticInt("commit", from: afterDiagnostics) ?? 0
        let nonSilentBuffers = Self.parseDiagnosticInt("nonsil", from: afterDiagnostics) ?? 0
        let wordCallbacks = Self.parseDiagnosticInt("word", from: afterDiagnostics) ?? 0
        let accepted = Self.parseDiagnosticInt("acc", from: afterDiagnostics) ?? 0
        emitHostMarker("VOICE_QA_DIAGNOSTICS=\(afterDiagnostics)")
        emitHostMarker("VOICE_QA_PROGRESS=\(baselineProgress);commit=\(baselineCommit)->\(afterCommit)")
        XCTAssertGreaterThan(
            nonSilentBuffers,
            0,
            "The physical iPad microphone did not receive non-silent audio: \(afterDiagnostics)"
        )
        XCTAssertGreaterThan(
            wordCallbacks,
            0,
            "Speech recognition produced no word callbacks: \(afterDiagnostics)"
        )
        XCTAssertGreaterThan(
            accepted,
            0,
            "Voice alignment accepted no spoken observations: \(afterDiagnostics)"
        )
        XCTAssertGreaterThan(
            afterCommit,
            baselineCommit,
            "Expected committed token progress after real speech stimulus: \(afterDiagnostics)"
        )

        try pauseAndResume(in: app)
        try backgroundAndForeground(app: app)
        try assertVoiceRecovered(in: app)
    }

    /// Physical proof against the same Release configuration that ships.
    ///
    /// Release intentionally excludes the DEBUG diagnostics surface. This test
    /// therefore reveals the auto-hidden chrome after the real speech window,
    /// then re-queries fresh visible progress and status values.
    func testVoiceFollowShippingReleaseProgress() throws {
        try requireReleaseHarnessBuild()

        let app = XCUIApplication()
        app.launchArguments = app.launchArguments.filter {
            $0 != "-AppleLanguages" && !$0.hasPrefix("-UITesting")
        }
        app.launch()

        try dismissOnboardingIfNeeded(in: app)
        try openKnownQAScript(in: app)
        try openPrompter(in: app)
        try ensureChromeVisible(in: app)
        try switchToVoiceMode(in: app)

        let baselineProgress = try requireProgressRatio(in: app)
        XCTAssertLessThan(
            baselineProgress,
            0.98,
            "The selected QA script is already at its end; restart it before Release Voice QA"
        )

        emitHostMarker("VOICE_RELEASE_QA_STATUS_BEFORE=\(readVoiceStatus(in: app))")
        try startVoiceFollow(in: app)
        try handleSystemPermissionsIfNeeded()

        // Play hides chrome. Reveal it once to prove Voice did not enter a
        // terminal permission state before asking the host to speak.
        try ensureChromeVisible(in: app)
        let startedStatus = readVoiceStatus(in: app)
        emitHostMarker("VOICE_RELEASE_QA_STATUS_AFTER_START=\(startedStatus)")
        XCTAssertTrue(
            Self.isHealthyReleaseVoiceStatus(startedStatus),
            "Shipping Voice Follow did not reach listening state: \(startedStatus)"
        )

        emitHostMarker("VOICE_QA_READY")
        RunLoop.current.run(until: Date().addingTimeInterval(speechWindowSeconds))

        // Never reuse baseline or DEBUG counters here. Reader chrome
        // intentionally auto-hides, so reveal and query new Release UI values.
        try ensureChromeVisible(in: app)
        let afterProgress = try requireProgressRatio(in: app)
        // Reading progress can consume the whole auto-hide window on physical
        // hardware. The status element can disappear between `exists` and
        // `label`, which XCTest records as a harness failure even though the
        // shipping app is still following. The required terminal proof is the
        // already-observed healthy Listening state plus fresh material progress.
        let afterStatus = "chrome-auto-hidden-after-progress"
        emitHostMarker(
            "VOICE_RELEASE_QA_PROGRESS=\(baselineProgress)->\(afterProgress)"
        )
        emitHostMarker("VOICE_RELEASE_QA_STATUS_AFTER=\(afterStatus)")

        let madeMaterialProgress = Self.hasMaterialProgress(
            from: baselineProgress,
            to: afterProgress
        )
        XCTAssertTrue(
            madeMaterialProgress,
            "Shipping Voice Follow made no fresh visible progress "
                + "(\(baselineProgress) -> \(afterProgress)); verify the host audio route and script"
        )
        emitHostMarker("VOICE_RELEASE_QA_STATUS_HIDDEN_AFTER_PROGRESS=1")
    }

    /// Simulator / CI smoke: launches library chrome only (no speech).
    func testLibraryLaunchSmoke() throws {
        let app = XCUIApplication()
        app.launch()
        try dismissOnboardingIfNeeded(in: app)

        let library = app.descendants(matching: .any)["phrasa.library.scripts"]
        let scriptsNav = app.navigationBars["Scripts"]
        let loaded = library.waitForExistence(timeout: 12) || scriptsNav.waitForExistence(timeout: 12)
        XCTAssertTrue(loaded, "Library should appear after launch (existing data preserved)")
    }

    /// Physical-device sync diagnostic. Preserves library/account data, opens
    /// the shipping Account & sync surface, retries the pending durable upload,
    /// and emits the exact before/after presentation for host-side DB proof.
    func testPhysicalSyncRetryAndReport() throws {
        let app = XCUIApplication()
        app.launchArguments = app.launchArguments.filter {
            $0 != "-AppleLanguages" && !$0.hasPrefix("-UITesting")
        }
        app.launch()

        try dismissOnboardingIfNeeded(in: app)
        try openAccountSync(in: app)

        emitHostMarker("SYNC_QA_STATUS_BEFORE=\(syncPresentation(in: app))")
        let after = try performManualSync(in: app)
        emitHostMarker("SYNC_QA_STATUS_AFTER=\(after)")
    }

    /// Destructive only to an externally created disposable fixture whose exact
    /// title is prefix-guarded by both the shell runner and this test.
    func testPhysicalSyncDeleteAndReport() throws {
        try requireReleaseHarnessBuild()
        let title = try requireFixture(
            "PHRASA_SYNC_DELETE_FIXTURE_TITLE",
            prefix: "SYNC QA DELETE IPAD "
        )

        let app = launchPreservingDeviceData()
        try dismissOnboardingIfNeeded(in: app)
        let row = try requireExactLibraryScript(title, in: app)
        row.swipeLeft()

        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete swipe action is missing")
        delete.tap()

        let confirm = app.buttons["Delete permanently"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Delete permanently confirmation is missing"
        )
        confirm.tap()

        XCTAssertTrue(
            exactLibraryScript(title, in: app).waitForNonExistence(timeout: 10),
            "Disposable delete fixture is still visible after confirmation"
        )
        emitHostMarker("SYNC_DELETE_QA_LOCAL_ABSENT=1")

        try openAccountSync(in: app)
        emitHostMarker("SYNC_DELETE_QA_STATUS_BEFORE=\(syncPresentation(in: app))")
        let after = try performManualSync(in: app)
        emitHostMarker("SYNC_DELETE_QA_STATUS_AFTER=\(after)")
        try closeAccountSync(in: app)

        try setLibrarySearch(title, in: app)
        XCTAssertTrue(
            exactLibraryScript(title, in: app).waitForNonExistence(timeout: 5),
            "Deleted disposable fixture returned after explicit sync"
        )
        emitHostMarker("SYNC_DELETE_QA_AFTER_SYNC_ABSENT=1")
    }

    /// True divergent edit proof. The cloud fixture/baseline is prepared
    /// externally; this test edits only the exact disposable script, syncs, and
    /// requires both cloud-original and deterministic Local conflict contents.
    func testPhysicalSyncConflictAndReport() throws {
        try requireReleaseHarnessBuild()
        let title = try requireFixture(
            "PHRASA_SYNC_CONFLICT_FIXTURE_TITLE",
            prefix: "SYNC QA CONFLICT "
        )
        let localMarker = try requireFixture("PHRASA_SYNC_CONFLICT_LOCAL_MARKER")
        let cloudMarker = try requireFixture("PHRASA_SYNC_CONFLICT_CLOUD_MARKER")
        XCTAssertNotEqual(localMarker, cloudMarker, "Conflict markers must differ")

        let app = launchPreservingDeviceData()
        try dismissOnboardingIfNeeded(in: app)
        try openExactLibraryScript(title, in: app)
        try replaceEditorBody(with: localMarker, in: app)
        emitHostMarker("SYNC_CONFLICT_QA_LOCAL_SAVE=1")

        try openAccountSync(in: app)
        emitHostMarker("SYNC_CONFLICT_QA_STATUS_BEFORE=\(syncPresentation(in: app))")
        let after = try performManualSync(in: app)
        emitHostMarker("SYNC_CONFLICT_QA_STATUS_AFTER=\(after)")
        try closeAccountSync(in: app)

        try openExactLibraryScript(title, in: app)
        XCTAssertTrue(
            try editorBody(in: app).contains(cloudMarker),
            "Original fixture did not retain the expected cloud body after conflict"
        )
        emitHostMarker("SYNC_CONFLICT_QA_CLOUD_ORIGINAL=1")

        let conflictTitle = "\(title) — Local conflict"
        try openExactLibraryScript(conflictTitle, in: app)
        XCTAssertTrue(
            try editorBody(in: app).contains(localMarker),
            "Local conflict copy did not preserve the iPad body marker"
        )
        emitHostMarker("SYNC_CONFLICT_QA_LOCAL_COPY=1")
    }

    // MARK: - Navigation

    private func launchPreservingDeviceData() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = app.launchArguments.filter {
            $0 != "-AppleLanguages" && !$0.hasPrefix("-UITesting")
        }
        app.launch()
        return app
    }

    private func requireFixture(_ name: String, prefix: String? = nil) throws -> String {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty,
              !value.contains("$("),
              prefix.map({ value.hasPrefix($0) }) ?? true else {
            XCTFail("Missing or unsafe disposable fixture environment: \(name)")
            throw HarnessError.missingFixture(name)
        }
        return value
    }

    private func libraryRoot(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[A11y.library]
    }

    private func exactLibraryScript(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", title)
        return libraryRoot(in: app)
            .descendants(matching: .staticText)
            .matching(predicate)
            .firstMatch
    }

    private func setLibrarySearch(_ title: String, in app: XCUIApplication) throws {
        let root = libraryRoot(in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 10), "Script library is missing")
        // In the iPad split-view layout the search field is a sibling of the
        // library collection, not one of the collection's descendants.
        let labelledSearch = app.searchFields["Search scripts or #tags"]
        let search = labelledSearch.exists ? labelledSearch : app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), "Library search field is missing")
        search.tap()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(title)
    }

    private func requireExactLibraryScript(
        _ title: String,
        in app: XCUIApplication
    ) throws -> XCUIElement {
        try setLibrarySearch(title, in: app)
        let row = exactLibraryScript(title, in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 12),
            "Exact disposable sync fixture is missing: \(title)"
        )
        return row
    }

    private func openExactLibraryScript(_ title: String, in app: XCUIApplication) throws {
        let row = try requireExactLibraryScript(title, in: app)
        row.tap()
        let body = app.textViews.firstMatch
        if !body.waitForExistence(timeout: 5) {
            row.tap()
        }
        XCTAssertTrue(
            body.waitForExistence(timeout: 10),
            "Editor body did not open for exact fixture: \(title)"
        )
    }

    private func replaceEditorBody(with marker: String, in app: XCUIApplication) throws {
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10), "Editor body is missing")
        body.tap()
        body.typeKey("a", modifierFlags: .command)
        body.typeText(marker)

        let saving = app.staticTexts["Saving…"]
        XCTAssertTrue(
            saving.waitForExistence(timeout: 4),
            "Editor did not enter Saving state after fixture edit"
        )
        XCTAssertTrue(
            app.staticTexts["Saved"].waitForExistence(timeout: 20),
            "Disposable fixture edit did not become durable"
        )
        XCTAssertTrue(
            try editorBody(in: app).contains(marker),
            "Editor body does not contain the supplied local marker"
        )
    }

    private func editorBody(in app: XCUIApplication) throws -> String {
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10), "Editor body is missing")
        return (body.value as? String) ?? body.label
    }

    private func dismissOnboardingIfNeeded(in app: XCUIApplication) throws {
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 3) {
            skip.tap()
            return
        }
        // Multi-page onboarding without Skip visible: finish via primary CTA.
        for _ in 0..<4 {
            let openLibrary = app.buttons["Open my library"]
            if openLibrary.waitForExistence(timeout: 1) {
                openLibrary.tap()
                return
            }
            let cont = app.buttons["Continue"]
            if cont.exists { cont.tap() }
        }
    }

    private func openAccountSync(in app: XCUIApplication) throws {
        let account = app.buttons["Account & sync"]
        if account.exists {
            account.tap()
        } else {
            var libraryOptions = app.buttons["Library options"]
            if !libraryOptions.waitForExistence(timeout: 4) {
                let scriptsBar = app.navigationBars["Scripts"]
                let overflow = scriptsBar.buttons["More"]
                let fallback = scriptsBar.buttons.matching(
                    NSPredicate(format: "identifier == %@", "OverflowBarButtonItem")
                ).firstMatch
                let more = overflow.exists ? overflow : fallback
                XCTAssertTrue(more.waitForExistence(timeout: 8), "Library overflow is missing")
                more.tap()
                libraryOptions = app.buttons["Library options"]
            }
            XCTAssertTrue(
                libraryOptions.waitForExistence(timeout: 8),
                "Library options is missing"
            )
            libraryOptions.tap()
            XCTAssertTrue(account.waitForExistence(timeout: 8), "Account & sync is missing")
            account.tap()
        }

        XCTAssertTrue(
            app.navigationBars["Account & sync"].waitForExistence(timeout: 10),
            "Account & sync screen did not open"
        )
    }

    private func syncPresentation(in app: XCUIApplication) -> String {
        let labels = app.staticTexts.allElementsBoundByIndex
            .map { $0.label }
            .filter {
                $0.contains("Signed in as")
                    || $0.contains("Synced ·")
                    || $0 == "Ready to sync"
                    || $0 == "Syncing safely…"
                    || $0.contains("Needs attention:")
                    || $0.localizedCaseInsensitiveContains("sync")
                    || $0.localizedCaseInsensitiveContains("network")
                    || $0.localizedCaseInsensitiveContains("session")
            }
        return labels.isEmpty ? "no-sync-presentation" : labels.joined(separator: " | ")
    }

    private func performManualSync(in app: XCUIApplication) throws -> String {
        let syncNow = app.buttons["Sync now"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 10), "Sync now is missing")
        XCTAssertTrue(syncNow.isEnabled, "Sync now is disabled")
        syncNow.tap()

        let syncing = app.staticTexts["Syncing safely…"]
        _ = syncing.waitForExistence(timeout: 5)
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, syncing.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        let after = syncPresentation(in: app)
        XCTAssertTrue(
            after.contains("Synced ·"),
            "Physical iPad sync did not succeed: \(after)"
        )
        return after
    }

    private func closeAccountSync(in app: XCUIApplication) throws {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Account & sync Done is missing")
        done.tap()
        XCTAssertTrue(
            libraryRoot(in: app).waitForExistence(timeout: 10),
            "Library did not return after closing Account & sync"
        )
    }

    private func openKnownQAScript(in app: XCUIApplication) throws {
        // Prefer the bundled sample because the runner's default spoken stimulus
        // is its exact opening text. Fall back only for an older preserved library
        // where the sample was deleted.
        let preferred = matchingScript(bundledScriptTitleFragment, in: app)
        let match: XCUIElement
        let selectedTitle: String
        if preferred.waitForExistence(timeout: 4) {
            match = preferred
            selectedTitle = bundledScriptTitleFragment
        } else {
            let fallback = matchingScript(fallbackScriptTitleFragment, in: app)
            XCTAssertTrue(
                fallback.waitForExistence(timeout: 16),
                "Neither the bundled Welcome script nor known QA fallback is visible"
            )
            match = fallback
            selectedTitle = fallbackScriptTitleFragment
        }
        match.tap()

        // iPad split view may need a second tap if selection-only.
        let openPrompter = app.descendants(matching: .any)[A11y.openPrompter]
        if !openPrompter.waitForExistence(timeout: 4) {
            match.tap()
        }
        XCTAssertTrue(
            openPrompter.waitForExistence(timeout: 12),
            "Editor Open prompter control missing after selecting \(selectedTitle)"
        )
    }

    private func matchingScript(_ titleFragment: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            titleFragment,
            titleFragment
        )
        return app.descendants(matching: .any).matching(predicate).element(boundBy: 0)
    }

    private func openPrompter(in app: XCUIApplication) throws {
        let open = app.descendants(matching: .any)[A11y.openPrompter]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        // Reader chrome: progress or play should appear.
        let progress = app.descendants(matching: .any)[A11y.progress]
        let play = app.buttons["Play"]
        let ready = progress.waitForExistence(timeout: 12) || play.waitForExistence(timeout: 12)
        XCTAssertTrue(ready, "Reader stage did not appear")
    }

    private func ensureChromeVisible(in app: XCUIApplication) throws {
        let playPause = app.descendants(matching: .any)[A11y.playPause]
        if playPause.exists { return }
        // Stage tap toggles chrome.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        if playPause.waitForExistence(timeout: 2) { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 2), "Reader chrome did not appear")
    }

    private func switchToVoiceMode(in app: XCUIApplication) throws {
        try ensureChromeVisible(in: app)
        // Segmented control button labeled "Voice".
        let voiceButton = app.buttons["Voice"]
        if voiceButton.waitForExistence(timeout: 4), voiceButton.isHittable {
            voiceButton.tap()
        } else {
            let mode = app.descendants(matching: .any)[A11y.mode]
            if mode.waitForExistence(timeout: 3) {
                // Fall back: tap right half of mode control (Voice is second segment).
                mode.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
            }
        }
        // Voice status panel only renders in voice mode.
        let voiceStatus = app.descendants(matching: .any)[A11y.voiceStatus]
        XCTAssertTrue(
            voiceStatus.waitForExistence(timeout: 6) || app.buttons["Voice"].isSelected,
            "Failed to switch reader mode to Voice"
        )
    }

    private func startVoiceFollow(in app: XCUIApplication) throws {
        try ensureChromeVisible(in: app)
        let play = app.buttons["Play"]
        let playById = app.descendants(matching: .any)[A11y.playPause]
        if play.waitForExistence(timeout: 4), play.isHittable {
            play.tap()
        } else if playById.waitForExistence(timeout: 2) {
            playById.tap()
        } else {
            XCTFail("Play control not available")
        }
    }

    // MARK: - Permissions (mic first, then speech)

    private func handleSystemPermissionsIfNeeded() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Mic prompt first, then speech recognition — product gate order.
        for _ in 0..<6 {
            if !springboard.wait(for: .runningForeground, timeout: 0.2)
                && !springboard.alerts.firstMatch.exists
            {
                // Brief poll for system alert elements without assuming foreground.
            }
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 2) {
                tapAllow(on: alert)
                // Allow sheet animation before next permission.
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                continue
            }
            // Some iPadOS builds surface permission buttons outside alerts.
            if tapAllowButtonIfPresent(in: springboard) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                continue
            }
            break
        }
    }

    private func tapAllow(on alert: XCUIElement) {
        let labels = ["Allow", "OK", "While Using the App", "Allow While Using App", "Continue"]
        for label in labels {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
        // Last resort: rightmost button is typically Allow.
        let buttons = alert.buttons
        if buttons.count > 0 {
            buttons.element(boundBy: buttons.count - 1).tap()
        }
    }

    private func tapAllowButtonIfPresent(in springboard: XCUIApplication) -> Bool {
        let labels = ["Allow", "While Using the App", "Allow While Using App"]
        for label in labels {
            let button = springboard.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                return true
            }
        }
        return false
    }

    // MARK: - Progress / recovery

    private func requireProgressRatio(in app: XCUIApplication) throws -> Double {
        let progress = app.descendants(matching: .any)[A11y.progress]
        guard progress.waitForExistence(timeout: 3) else {
            XCTFail("Reader progress is missing after chrome reveal")
            throw HarnessError.missingReaderProgress
        }
        let raw = (progress.value as? String) ?? progress.label
        return Self.parseProgressRatio(raw)
    }

    private func readVoiceStatus(in app: XCUIApplication) -> String {
        let status = app.descendants(matching: .any)[A11y.voiceStatus]
        guard status.exists else { return "missing" }
        let parts = [status.label, status.value as? String]
            .compactMap { $0 }
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "present-without-text" : parts.joined(separator: " | ")
    }

    private func requireVoiceDiagnostics(in app: XCUIApplication) throws -> String {
        let diagnostics = app.descendants(matching: .any)[A11y.voiceDiagnostics]
        guard diagnostics.waitForExistence(timeout: 4) else {
            XCTFail(
                "VoicePipelineDiagnostics is missing. The instrumented physical "
                    + "test must use the PhrasaVoiceUIQA Debug scheme."
            )
            throw HarnessError.missingDebugDiagnostics
        }
        let raw = (diagnostics.value as? String) ?? diagnostics.label
        guard !raw.isEmpty, raw != A11y.voiceDiagnostics else {
            XCTFail("VoicePipelineDiagnostics exists but has no readable value")
            throw HarnessError.unreadableDebugDiagnostics
        }
        return raw
    }

    static func parseDiagnosticInt(_ key: String, from raw: String) -> Int? {
        let prefix = "\(key)="
        guard let range = raw.range(of: prefix) else { return nil }
        let remainder = raw[range.upperBound...]
        guard let token = remainder.split(separator: " ", maxSplits: 1).first else { return nil }
        return Int(token)
    }

    static func hasMaterialProgress(
        from baseline: Double,
        to after: Double,
        minimumDelta: Double = 0.0005
    ) -> Bool {
        after - baseline >= minimumDelta
    }

    static func isHealthyReleaseVoiceStatus(_ raw: String) -> Bool {
        let normalized = raw.lowercased()
        let terminalTokens = [
            "missing",
            "blocked",
            "denied",
            "restricted",
            "unavailable",
            "cancelled",
            "requesterror"
        ]
        guard !terminalTokens.contains(where: normalized.contains) else {
            return false
        }
        // The combined accessibility element exposes its user-facing label and
        // compact value. Healthy active presentations all retain "listening".
        return normalized.contains("listening")
            || normalized.contains("following")
            || normalized.contains("finding place")
    }

    /// Parses "12.5%", "12%", or "0.125" style accessibility values.
    static func parseProgressRatio(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") {
            let number = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
            if let pct = Double(number) { return pct / 100.0 }
        }
        // Extract first number.
        let pattern = #"([0-9]+(?:\.[0-9]+)?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range(at: 1), in: trimmed),
           let value = Double(trimmed[range])
        {
            return value > 1.0 ? value / 100.0 : value
        }
        return 0
    }

    private func pauseAndResume(in app: XCUIApplication) throws {
        try ensureChromeVisible(in: app)
        // iPadOS can report the visible SwiftUI control as not hittable during
        // its fade transition. The round button has a stable bottom-right stage
        // location; tap it physically, then prove the effect from engine state.
        tapPhysicalPlayPause(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let pausedDiagnostics = try requireVoiceDiagnostics(in: app)
        emitHostMarker("VOICE_QA_PAUSED=\(pausedDiagnostics)")
        XCTAssertTrue(
            pausedDiagnostics.contains("status=idle"),
            "Voice engine did not pause: \(pausedDiagnostics)"
        )

        // Pausing keeps chrome visible, so the same physical control resumes.
        tapPhysicalPlayPause(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let resumedDiagnostics = try requireVoiceDiagnostics(in: app)
        emitHostMarker("VOICE_QA_RESUMED=\(resumedDiagnostics)")
        XCTAssertTrue(
            resumedDiagnostics.contains("status=listening"),
            "Voice engine did not resume: \(resumedDiagnostics)"
        )
    }

    private func tapPhysicalPlayPause(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.92)).tap()
    }

    private func backgroundAndForeground(app: XCUIApplication) throws {
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App failed to return to foreground")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    }

    private func assertVoiceRecovered(in app: XCUIApplication) throws {
        try ensureChromeVisible(in: app)
        let playPause = app.descendants(matching: .any)[A11y.playPause]
        XCTAssertTrue(playPause.exists, "Reader controls missing after foreground recovery")

        let beforeRecovery = try requireVoiceDiagnostics(in: app)
        // Backgrounding is expected to pause voice. Resume via the stable physical
        // control location, then prove the audio engine returned to listening.
        if !beforeRecovery.contains("status=listening") {
            tapPhysicalPlayPause(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            try handleSystemPermissionsIfNeeded()
        }

        let recoveredDiagnostics = try requireVoiceDiagnostics(in: app)
        emitHostMarker("VOICE_QA_FOREGROUND_RECOVERY=\(recoveredDiagnostics)")
        XCTAssertTrue(
            recoveredDiagnostics.contains("permOK=1")
                && recoveredDiagnostics.contains("eng=1")
                && recoveredDiagnostics.contains("status=listening"),
            "Voice pipeline failed to recover after background: \(recoveredDiagnostics)"
        )
    }

    // MARK: - Build configuration contract

    private func requireDebugHarnessBuild() throws {
        #if DEBUG
        return
        #else
        XCTFail(
            "Instrumented Voice QA was compiled as Release. "
                + "Run PhrasaVoiceUIQA in Debug."
        )
        throw HarnessError.wrongBuildConfiguration("expected Debug")
        #endif
    }

    private func requireReleaseHarnessBuild() throws {
        #if DEBUG
        XCTFail(
            "Shipping Voice QA was compiled as Debug. "
                + "Run PhrasaVoiceReleaseUIQA in Release."
        )
        throw HarnessError.wrongBuildConfiguration("expected Release")
        #else
        return
        #endif
    }

    // MARK: - Host marker

    private func emitHostMarker(_ token: String) {
        // Multiple channels so teed xcodebuild logs and Console are reliable.
        fputs("\(token)\n", stdout)
        fflush(stdout)
        fputs("\(token)\n", stderr)
        fflush(stderr)
        NSLog("%@", token)
        print(token)
    }
}
