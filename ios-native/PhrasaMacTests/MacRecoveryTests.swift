import XCTest
import PhrasaDomain
import PhrasaPersistence
@testable import PhrasaMac

@MainActor
final class MacRecoveryTests: XCTestCase {
    func testCorruptLibraryOffersStartFreshAndPreservesArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhrasaMacRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbURL = directory.appendingPathComponent("library.sqlite3")
        // Write an unreadable store without holding a live connection open.
        try Data("not-a-database".utf8).write(to: dbURL, options: .atomic)

        let damaged = MacLibraryStore(
            persistence: LibraryPersistenceFactory.makeShipping(fileURL: dbURL)
        )
        await damaged.load()
        XCTAssertFalse(damaged.isLoaded)
        XCTAssertTrue(damaged.canStartFreshAfterCorruption)
        XCTAssertNotNil(damaged.errorMessage)

        let recovered = await damaged.startFreshAfterCorruption()
        XCTAssertTrue(recovered)
        XCTAssertTrue(damaged.isLoaded)
        // Fresh library reseeds the welcome script.
        XCTAssertTrue(damaged.scripts.contains(where: { $0.title == ScriptDocument.welcome.title }))

        let recoveryRoot = directory.appendingPathComponent("Recovery", isDirectory: true)
        let recoveryEntries = (try? FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(
            recoveryEntries.isEmpty,
            "Damaged library files must be preserved under Recovery/"
        )
    }

    func testDisplaySleepGuardTogglesWithPolicy() {
        let guardInstance = MacDisplaySleepGuard()
        XCTAssertFalse(guardInstance.isPreventingSleep)
        guardInstance.begin(reason: "test")
        XCTAssertTrue(guardInstance.isPreventingSleep)
        guardInstance.end()
        XCTAssertFalse(guardInstance.isPreventingSleep)

        XCTAssertTrue(MacDisplaySleepPolicy.shouldPreventSleep(isPresenting: true, isPlaying: true))
        XCTAssertFalse(MacDisplaySleepPolicy.shouldPreventSleep(isPresenting: true, isPlaying: false))
    }
}
