import XCTest
@testable import Phrasa

/// App-layer measurements for a ~2,000-word script and session hot paths.
/// Timings are printed for the release report; hard fails only on pathological stalls.
final class LargeScriptPerformanceTests: XCTestCase {
    private static let wordCount = 2_000
    private let scriptID = UUID(uuidString: "00000000-0000-0000-0000-00000000PERF".replacingOccurrences(of: "PERF", with: "0001"))!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeBody() -> String {
        (0..<Self.wordCount).map { "word\($0 % 89)" }.joined(separator: " ")
    }

    func testWordCountAndEstimatedDurationForTwoThousandWords() {
        let body = makeBody()
        let started = CFAbsoluteTimeGetCurrent()
        let words = TextMetrics.wordCount(body)
        let duration = TextMetrics.estimatedDuration(body, wordsPerMinute: 150)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(words, Self.wordCount)
        XCTAssertEqual(duration, Double(Self.wordCount) / 150.0 * 60.0, accuracy: 0.01)
        XCTAssertLessThan(elapsed, 0.5, "word metrics stalled (\(elapsed)s)")
        print(String(format: "PERF text_metrics_2000_words=%.3fms duration=%.1fs", elapsed * 1_000, duration))
    }

    func testReaderSessionTrackerAndBookmarkRoundTripOnLargeScript() async throws {
        let body = makeBody()
        let script = ScriptDocument(id: scriptID, title: "Perf talk", body: body)

        let trackStarted = CFAbsoluteTimeGetCurrent()
        var tracker = ReaderSessionTracker(scriptID: scriptID, body: body)
        tracker.start(at: start)
        tracker.update(progress: 0.37, focusTokenIndex: 740)
        let bookmark = tracker.pause(
            at: start.addingTimeInterval(30),
            script: script,
            mode: .speed,
            speedWPM: 155
        )
        let trackElapsed = CFAbsoluteTimeGetCurrent() - trackStarted

        XCTAssertTrue(bookmark.isResumeEligible(for: script))
        XCTAssertEqual(bookmark.progress, 0.37, accuracy: 0.0001)
        XCTAssertEqual(bookmark.focusTokenIndex, 740)
        XCTAssertEqual(bookmark.domainContentSignature, ScriptContentSignature.make(script))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-perf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let storeStarted = CFAbsoluteTimeGetCurrent()
        let store = ReaderSessionStore(fileURL: url)
        try await store.save(bookmark: bookmark)
        let loaded = try await store.bookmark(for: script)
        let storeElapsed = CFAbsoluteTimeGetCurrent() - storeStarted

        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.progress, 0.37, accuracy: 0.0001)
        XCTAssertEqual(restored.focusTokenIndex, 740)
        XCTAssertTrue(restored.isResumeEligible(for: script))

        // Title edit invalidates domain signature; body-hash eligibility remains.
        var renamed = script
        renamed.title = "Renamed talk"
        XCTAssertTrue(bookmark.isResumeEligible(for: body))
        XCTAssertFalse(bookmark.isResumeEligible(for: renamed))

        XCTAssertLessThan(trackElapsed, 1.0, "session tracker stalled (\(trackElapsed)s)")
        XCTAssertLessThan(storeElapsed, 1.0, "session store stalled (\(storeElapsed)s)")
        print(String(format: "PERF session_tracker_2000_words=%.3fms", trackElapsed * 1_000))
        print(String(format: "PERF session_store_2000_words=%.3fms", storeElapsed * 1_000))
    }

    func testExportImportRoundTripForTwoThousandWordScriptStaysBounded() throws {
        let body = makeBody()
        let script = ScriptDocument(title: "Export perf", body: body, tags: ["qa"])
        let exporter = ScriptExportService()
        let importer = ScriptImportService()

        let started = CFAbsoluteTimeGetCurrent()
        let textDoc = exporter.plainText(script: script)
        let jsonDoc = try exporter.scriptJSON(script: script)
        // Re-import as plain text (title + body envelope).
        let reimportedText = try importer.importData(Data(body.utf8), filename: "export-perf.txt")
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(reimportedText.body, body)
        XCTAssertFalse(textDoc.data.isEmpty)
        XCTAssertFalse(jsonDoc.data.isEmpty)
        XCTAssertTrue(String(data: textDoc.data, encoding: .utf8)?.contains("word0") == true)
        XCTAssertEqual(TextMetrics.wordCount(reimportedText.body), Self.wordCount)
        XCTAssertLessThan(elapsed, 2.0, "import/export 2k words stalled (\(elapsed)s)")
        print(String(format: "PERF import_export_2000_words=%.3fms", elapsed * 1_000))
    }

    func testSQLiteCreateEditAutosaveRelaunchForLargeScript() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-perf-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let body = makeBody()
        let created = ScriptDocument(title: "Autosave draft", body: body)
        let first = SQLitePersistenceClient(fileURL: url)

        let createStarted = CFAbsoluteTimeGetCurrent()
        try await first.upsert(created)
        let createElapsed = CFAbsoluteTimeGetCurrent() - createStarted

        var edited = created
        edited.body = body + "\n\nFinal sentence for recovery."
        edited.updatedAt = start.addingTimeInterval(12)
        let editStarted = CFAbsoluteTimeGetCurrent()
        try await first.upsert(edited)
        let editElapsed = CFAbsoluteTimeGetCurrent() - editStarted

        let relaunchStarted = CFAbsoluteTimeGetCurrent()
        let second = SQLitePersistenceClient(fileURL: url)
        let loaded = try await second.load()
        let relaunchElapsed = CFAbsoluteTimeGetCurrent() - relaunchStarted

        let persisted = try XCTUnwrap(loaded.scripts.first { $0.id == created.id })
        XCTAssertTrue(persisted.body.hasSuffix("Final sentence for recovery."))
        XCTAssertEqual(TextMetrics.wordCount(created.body), Self.wordCount)
        XCTAssertLessThan(createElapsed, 2.0, "create stalled (\(createElapsed)s)")
        XCTAssertLessThan(editElapsed, 2.0, "edit stalled (\(editElapsed)s)")
        XCTAssertLessThan(relaunchElapsed, 2.0, "relaunch load stalled (\(relaunchElapsed)s)")
        print(String(format: "PERF app_sqlite_create_2000=%.3fms", createElapsed * 1_000))
        print(String(format: "PERF app_sqlite_edit_2000=%.3fms", editElapsed * 1_000))
        print(String(format: "PERF app_sqlite_relaunch_2000=%.3fms", relaunchElapsed * 1_000))
    }
}
