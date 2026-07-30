import XCTest
@testable import PhrasaMac

final class MacSessionStoreTests: XCTestCase {
    func testBookmarkRoundTripAndContentMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhrasaMacSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MacReaderSessionStore(
            fileURL: directory.appendingPathComponent("reader-sessions.json")
        )
        let scriptID = UUID()
        let body = "Stable body for resume"
        let bookmark = MacReaderBookmark(
            scriptID: scriptID,
            contentSignature: MacReaderContentSignature.make(for: body),
            progress: 0.33,
            elapsedActiveTime: 12,
            activeRunCount: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.save(bookmark: bookmark)
        let loaded = try await store.bookmark(for: scriptID, matchingBody: body)
        guard let loaded else {
            XCTFail("Expected bookmark")
            return
        }
        XCTAssertEqual(loaded.progress, 0.33, accuracy: 0.0001)

        let mismatched = try await store.bookmark(for: scriptID, matchingBody: body + "!")
        XCTAssertNil(mismatched)

        try await store.clearBookmark(for: scriptID)
        let cleared = try await store.bookmark(for: scriptID, matchingBody: body)
        XCTAssertNil(cleared)
    }

    func testRecapPersistenceKeepsLatest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhrasaMacSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MacReaderSessionStore(
            fileURL: directory.appendingPathComponent("reader-sessions.json")
        )
        let scriptID = UUID()
        let older = MacReaderCompletionRecap(
            scriptID: scriptID,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            activeTime: 30,
            wordCount: 50,
            targetDuration: nil,
            activeRunCount: 1,
            wasResumed: false
        )
        let newer = MacReaderCompletionRecap(
            scriptID: scriptID,
            completedAt: Date(timeIntervalSince1970: 1_700_000_100),
            activeTime: 45,
            wordCount: 50,
            targetDuration: 40,
            activeRunCount: 2,
            wasResumed: true
        )
        try await store.save(recap: older)
        try await store.save(recap: newer)
        let latest = try await store.latestRecap(for: scriptID)
        guard let latest else {
            XCTFail("Expected recap")
            return
        }
        XCTAssertEqual(latest.activeTime, 45, accuracy: 0.001)
        XCTAssertTrue(latest.wasResumed)
    }
}
