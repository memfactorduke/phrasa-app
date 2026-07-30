import XCTest

/// Host-side pure helpers for the UI harness (no device, no speech).
final class VoiceFollowProgressParsingTests: XCTestCase {
    func testParsePercentValues() {
        XCTAssertEqual(VoiceFollowPhysicalUITests.parseProgressRatio("0%"), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceFollowPhysicalUITests.parseProgressRatio("12.5%"), 0.125, accuracy: 0.0001)
        XCTAssertEqual(VoiceFollowPhysicalUITests.parseProgressRatio("100%"), 1.0, accuracy: 0.0001)
    }

    func testParseBareNumbers() {
        XCTAssertEqual(VoiceFollowPhysicalUITests.parseProgressRatio("0.05"), 0.05, accuracy: 0.0001)
        XCTAssertEqual(VoiceFollowPhysicalUITests.parseProgressRatio("progress 3.0% done"), 0.03, accuracy: 0.0001)
    }

    func testParseDiagnosticInteger() {
        let value = "permOK=1 nonsil=286 word=87 acc=73 commit=60 status=listening"
        XCTAssertEqual(VoiceFollowPhysicalUITests.parseDiagnosticInt("nonsil", from: value), 286)
        XCTAssertEqual(VoiceFollowPhysicalUITests.parseDiagnosticInt("commit", from: value), 60)
        XCTAssertNil(VoiceFollowPhysicalUITests.parseDiagnosticInt("missing", from: value))
    }

    func testMaterialProgressRequiresFreshPositiveDelta() {
        XCTAssertTrue(
            VoiceFollowPhysicalUITests.hasMaterialProgress(from: 0.10, to: 0.101)
        )
        XCTAssertFalse(
            VoiceFollowPhysicalUITests.hasMaterialProgress(from: 0.10, to: 0.10)
        )
        XCTAssertFalse(
            VoiceFollowPhysicalUITests.hasMaterialProgress(from: 0.10, to: 0.1004)
        )
        XCTAssertFalse(
            VoiceFollowPhysicalUITests.hasMaterialProgress(from: 0.10, to: 0.09)
        )
    }

    func testReleaseVoiceStatusAcceptsActivePresentations() {
        XCTAssertTrue(
            VoiceFollowPhysicalUITests.isHealthyReleaseVoiceStatus(
                "Listening | listening"
            )
        )
        XCTAssertTrue(
            VoiceFollowPhysicalUITests.isHealthyReleaseVoiceStatus(
                "Following | listening"
            )
        )
        XCTAssertTrue(
            VoiceFollowPhysicalUITests.isHealthyReleaseVoiceStatus(
                "Finding place | listening"
            )
        )
    }

    func testReleaseVoiceStatusRejectsMissingAndTerminalStates() {
        let blocked = [
            "missing",
            "Voice access blocked | micDenied",
            "Voice access blocked | speechRestricted",
            "Unavailable | unavailable",
            "Voice paused | cancelled",
            "Request failed | requestError"
        ]
        for status in blocked {
            XCTAssertFalse(
                VoiceFollowPhysicalUITests.isHealthyReleaseVoiceStatus(status),
                "Expected terminal status to be rejected: \(status)"
            )
        }
    }
}
