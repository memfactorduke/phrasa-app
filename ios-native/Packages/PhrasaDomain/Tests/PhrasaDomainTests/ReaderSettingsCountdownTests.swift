import XCTest
@testable import PhrasaDomain

final class ReaderSettingsCountdownTests: XCTestCase {
    func testDefaultAndCases() {
        XCTAssertEqual(ReaderSettings().speedCountdown, .fiveSeconds)
        XCTAssertEqual(SpeedCountdown.allCases, [.off, .fiveSeconds, .fifteenSeconds])
        XCTAssertEqual(SpeedCountdown.off.displaySequence, [])
        XCTAssertEqual(SpeedCountdown.fiveSeconds.displaySequence, [5, 4, 3, 2, 1])
        XCTAssertEqual(SpeedCountdown.fifteenSeconds.displaySequence.count, 15)
    }

    func testLegacySettingsWithoutCountdownDecodeToFiveSeconds() throws {
        let legacy = """
        {
          "mode":"speed", "scrollStyle":"continuous", "font":"hyperlegible",
          "fontSize":56, "lineHeight":1.45, "horizontalMargin":0.12,
          "alignment":"leading", "theme":"stage", "mirrorHorizontal":false,
          "mirrorVertical":false, "focusPosition":0.25, "speedWPM":140,
          "recognitionLanguage":"en-US", "showPacing":true
        }
        """.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(ReaderSettings.self, from: legacy).speedCountdown,
            .fiveSeconds
        )
    }

    func testRoundTripAndUnknownValueFallback() throws {
        for countdown in SpeedCountdown.allCases {
            var settings = ReaderSettings()
            settings.speedCountdown = countdown
            let decoded = try JSONDecoder().decode(
                ReaderSettings.self,
                from: JSONEncoder().encode(settings)
            )
            XCTAssertEqual(decoded.speedCountdown, countdown)
        }

        let unknown = """
        {"speedCountdown":7}
        """.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(ReaderSettings.self, from: unknown).speedCountdown,
            .fiveSeconds
        )
    }

    func testStartPolicyOnlyCountsDownForSpeedAtBeginning() {
        XCTAssertTrue(SpeedModeStartPolicy.shouldBeginWithCountdown(
            mode: .speed, progress: 0, countdown: .fiveSeconds
        ))
        XCTAssertFalse(SpeedModeStartPolicy.shouldBeginWithCountdown(
            mode: .speed, progress: 0, countdown: .off
        ))
        XCTAssertFalse(SpeedModeStartPolicy.shouldBeginWithCountdown(
            mode: .voice, progress: 0, countdown: .fifteenSeconds
        ))
        XCTAssertFalse(SpeedModeStartPolicy.shouldBeginWithCountdown(
            mode: .speed, progress: 0.01, countdown: .fiveSeconds
        ))
    }
}
