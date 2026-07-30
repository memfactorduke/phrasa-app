import XCTest
@testable import Phrasa

/// App-target smoke tests proving the embedded domain/persistence packages
/// remain the single definitions used by LibraryStore.
final class DomainBoundaryTests: XCTestCase {
    func testLibraryStoreDefaultsToShippingSQLiteFactory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrasa-store-default-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let library = await MainActor.run {
            LibraryStore(persistence: LibraryPersistenceFactory.makeShipping(fileURL: url))
        }
        await library.load()
        let created = await library.createScript(title: "Boundary", body: "Embedded packages")
        XCTAssertNotNil(created)
        let reopened = SQLitePersistenceClient(fileURL: url)
        let snapshot = try await reopened.load()
        XCTAssertEqual(snapshot.scripts.first?.title, "Boundary")
    }

    func testResumeBookmarkUsesSharedDomainSignature() {
        let script = ScriptDocument(title: "Talk", body: "Words")
        let bookmark = ResumeBookmark(
            scriptID: script.id,
            focusTokenIndex: 4,
            speedProgress: 0.25,
            contentSignature: ScriptContentSignature.make(script)
        )
        XCTAssertNotNil(bookmark.validated(against: script))
        var edited = script
        edited.body = "Changed"
        XCTAssertNil(bookmark.validated(against: edited))
    }

    func testCloudSyncErrorTypeIsSharedDomainDefinition() {
        let error = CloudSyncApplicationError.localLibraryChanged
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    func testEmbeddedPersistenceSourcesDoNotImportUIKit() throws {
        // Guard against domain/persistence/pure-sync sources drifting into UI
        // frameworks or the Supabase SDK when compiled into the app target.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages", isDirectory: true)
        let domain = root.appendingPathComponent("PhrasaDomain/Sources/PhrasaDomain")
        let persistence = root.appendingPathComponent("PhrasaPersistence/Sources/PhrasaPersistence")
        let pureSync = root.appendingPathComponent("PhrasaSync/Sources/PhrasaSync")
        let forbidden = ["import UIKit", "import SwiftUI", "import AppKit", "import Speech", "import AVFoundation", "import Supabase"]
        for directory in [domain, persistence, pureSync] {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
            XCTAssertFalse(files.isEmpty, "expected sources in \(directory.lastPathComponent)")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    XCTAssertFalse(
                        text.contains(token),
                        "\(file.lastPathComponent) must not contain \(token)"
                    )
                }
            }
        }
    }

    func testReaderSessionSignatureIsIndependentOfDomainTitleSignature() {
        // Session resume is body-scoped so title renames do not discard progress.
        // Domain ResumeBookmark remains available for package consumers that need
        // title+body canonical signatures.
        let body = "Hello stage"
        let left = ScriptDocument(title: "Talk A", body: body)
        let right = ScriptDocument(title: "Talk B", body: body)
        XCTAssertEqual(
            ReaderContentSignature.make(for: left.body),
            ReaderContentSignature.make(for: right.body)
        )
        XCTAssertNotEqual(
            ScriptContentSignature.make(left),
            ScriptContentSignature.make(right)
        )
    }
}
