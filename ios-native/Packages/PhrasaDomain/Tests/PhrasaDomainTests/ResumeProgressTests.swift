import XCTest
@testable import PhrasaDomain

final class ResumeProgressTests: XCTestCase {
    func testContentSignatureIsStableForSameTitleAndBody() {
        let left = ScriptDocument(title: "Talk", body: "Hello world")
        let right = ScriptDocument(
            id: UUID(),
            title: "Talk",
            body: "Hello world",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(
            ScriptContentSignature.make(left),
            ScriptContentSignature.make(right)
        )
    }

    func testContentSignatureChangesWhenBodyEdits() {
        let original = ScriptDocument(title: "Talk", body: "Hello")
        var edited = original
        edited.body = "Hello there"
        XCTAssertNotEqual(
            ScriptContentSignature.make(original),
            ScriptContentSignature.make(edited)
        )
    }

    func testResumeBookmarkRejectsMismatchedContentSignature() {
        let script = ScriptDocument(title: "Talk", body: "Original body")
        let bookmark = ResumeBookmark(
            scriptID: script.id,
            focusTokenIndex: 12,
            speedProgress: 0.4,
            contentSignature: ScriptContentSignature.make(script)
        )
        XCTAssertEqual(bookmark.validated(against: script)?.focusTokenIndex, 12)

        var edited = script
        edited.body = "Edited body"
        XCTAssertNil(bookmark.validated(against: edited))
    }

    func testResumeBookmarkRejectsDifferentScriptID() {
        let script = ScriptDocument(title: "Talk", body: "Body")
        let bookmark = ResumeBookmark(
            scriptID: UUID(),
            focusTokenIndex: 0,
            contentSignature: ScriptContentSignature.make(script)
        )
        XCTAssertNil(bookmark.validated(against: script))
    }

    func testResumeBookmarkClampsProgressValues() {
        let bookmark = ResumeBookmark(
            scriptID: UUID(),
            focusTokenIndex: -3,
            speedProgress: 1.5,
            contentSignature: "sig",
            mode: .voice,
            speedWPM: 999
        )
        XCTAssertEqual(bookmark.focusTokenIndex, 0)
        XCTAssertEqual(bookmark.speedProgress, 1)
        XCTAssertEqual(bookmark.mode, .voice)
        XCTAssertEqual(bookmark.speedWPM, 400)
    }

    func testResumeBookmarkPersistsModeAndSpeedAndEffectiveProgress() throws {
        let script = ScriptDocument(title: "Talk", body: "one two three four five")
        let bookmark = ResumeBookmark(
            scriptID: script.id,
            focusTokenIndex: 2,
            speedProgress: 0.5,
            contentSignature: ScriptContentSignature.make(script),
            mode: .voice,
            speedWPM: 160
        )
        let data = try JSONEncoder().encode(bookmark)
        let decoded = try JSONDecoder().decode(ResumeBookmark.self, from: data)
        XCTAssertEqual(decoded.mode, .voice)
        XCTAssertEqual(decoded.speedWPM, 160)
        XCTAssertEqual(decoded.focusTokenIndex, 2)
        XCTAssertEqual(decoded.effectiveSpeedProgress(tokenCount: 5), 0.5, accuracy: 0.0001)

        // Token fallback when speed progress is absent.
        let tokenOnly = ResumeBookmark(
            scriptID: script.id,
            focusTokenIndex: 2,
            contentSignature: ScriptContentSignature.make(script)
        )
        XCTAssertEqual(tokenOnly.effectiveSpeedProgress(tokenCount: 5), 0.5, accuracy: 0.0001)

        // Legacy encode/decode without mode/speed still works.
        struct LegacyResume: Encodable {
            var scriptID: UUID
            var focusTokenIndex: Int
            var contentSignature: String
            var savedAt: Date
        }
        let legacyData = try JSONEncoder().encode(
            LegacyResume(
                scriptID: script.id,
                focusTokenIndex: 1,
                contentSignature: "sig",
                savedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let legacy = try JSONDecoder().decode(ResumeBookmark.self, from: legacyData)
        XCTAssertNil(legacy.mode)
        XCTAssertNil(legacy.speedWPM)
        XCTAssertEqual(legacy.focusTokenIndex, 1)
    }

    func testFindLineMatchingLocatesLineAndWraps() {
        let body = "alpha\nbeta\ngamma"
        let first = FindLineMatching.firstMatchRange(in: body, query: "beta")
        XCTAssertNotNil(first)
        XCTAssertEqual(FindLineMatching.lineNumber(in: body, utf16Offset: first!.location), 2)
        let wrapped = FindLineMatching.firstMatchRange(
            in: body,
            query: "alpha",
            fromUTF16Offset: first!.location
        )
        XCTAssertEqual(FindLineMatching.lineNumber(in: body, utf16Offset: wrapped!.location), 1)
        XCTAssertNil(FindLineMatching.firstMatchRange(in: body, query: "   "))
    }

    func testReadingRecapTargetDifference() {
        let recap = ReadingRecap(
            scriptID: UUID(),
            activeDuration: 130,
            averageWPM: 140,
            targetDuration: 120,
            runCount: 2
        )
        XCTAssertEqual(recap.targetDifference, 10)
        XCTAssertEqual(recap.runCount, 2)
    }

    func testReaderSettingsNormalizeMirrorExclusivityAndBounds() {
        var settings = ReaderSettings(
            fontSize: 999,
            lineHeight: 0.1,
            horizontalMargin: 0.9,
            mirrorHorizontal: true,
            mirrorVertical: true,
            focusPosition: 0.01,
            speedWPM: 10,
            targetDuration: 5
        )
        settings.normalize()
        XCTAssertEqual(settings.fontSize, 160)
        XCTAssertEqual(settings.lineHeight, 1)
        XCTAssertEqual(settings.horizontalMargin, 0.4)
        XCTAssertEqual(settings.focusPosition, 0.15)
        XCTAssertEqual(settings.speedWPM, 40)
        XCTAssertFalse(settings.mirrorHorizontal)
        XCTAssertTrue(settings.mirrorVertical)
        XCTAssertNil(settings.targetDuration)
    }

    func testFreshReaderSettingsDefaultFocusLineIs25Percent() {
        let fresh = ReaderSettings()
        XCTAssertEqual(fresh.focusPosition, 0.25, accuracy: 0.000_1)
    }

    func testPersistedFocusLineIsPreservedThroughCodableRoundTrip() throws {
        // Existing users may have the old 42% default (or any explicit value)
        // already written to disk. Changing the Swift default must not rewrite it.
        var settings = ReaderSettings()
        settings.focusPosition = 0.42
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: data)
        XCTAssertEqual(decoded.focusPosition, 0.42, accuracy: 0.000_1)

        settings.focusPosition = 0.67
        let otherData = try JSONEncoder().encode(settings)
        let otherDecoded = try JSONDecoder().decode(ReaderSettings.self, from: otherData)
        XCTAssertEqual(otherDecoded.focusPosition, 0.67, accuracy: 0.000_1)
    }

    func testReaderThemeLabelsStayStableForLegacyRawValues() {
        XCTAssertEqual(ReaderTheme.stage.rawValue, "stage")
        XCTAssertEqual(ReaderTheme.paper.rawValue, "paper")
        XCTAssertEqual(ReaderTheme.amber.rawValue, "amber")
        XCTAssertEqual(ReaderTheme.sepia.rawValue, "sepia")
        XCTAssertEqual(ReaderTheme.amber.label, "Elevated")
        XCTAssertEqual(ReaderTheme.sepia.label, "Dim")
        XCTAssertEqual(ReaderTheme(rawValue: "amber"), .amber)
        XCTAssertEqual(ReaderTheme(rawValue: "sepia"), .sepia)
    }

    func testLibrarySchemaDocumentsShippingInvariants() {
        XCTAssertEqual(LibrarySchema.currentVersion, 1)
        XCTAssertTrue(
            LibrarySchema.durabilityInvariants.contains(
                where: { $0.contains("SQLite is the only shipping") }
            )
        )
        XCTAssertTrue(
            LibrarySchema.durabilityInvariants.contains(
                where: { $0.contains("JSON persistence is a test double") }
            )
        )
    }

    func testCloudSyncApplicationPolicyRejectsDivergentSnapshots() {
        let base = LibrarySnapshot.empty
        var current = base
        current.seeded = true
        XCTAssertThrowsError(
            try CloudSyncApplicationPolicy.validate(base: base, current: current)
        ) { error in
            XCTAssertEqual(error as? CloudSyncApplicationError, .localLibraryChanged)
        }
    }
}
