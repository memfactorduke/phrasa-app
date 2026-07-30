import Foundation
import Supabase
import XCTest
@testable import PhrasaDomain
@testable import PhrasaSync
@testable import PhrasaSyncSupabase

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SupabaseAdapterTests: XCTestCase {
    func testKeysetPageValidationRequiresStrictlyIncreasingExactCountedPages() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let fourthID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        var accumulated: [Int] = []
        var expectedTotal: Int?

        XCTAssertFalse(try SupabaseCloudRepository.appendCompleteKeysetPage(
            [1, 2],
            rowIDs: [firstID, secondID],
            after: nil,
            reportedCount: 4,
            expectedTotal: &expectedTotal,
            accumulated: &accumulated
        ))
        XCTAssertTrue(try SupabaseCloudRepository.appendCompleteKeysetPage(
            [3, 4],
            rowIDs: [thirdID, fourthID],
            after: secondID,
            reportedCount: 2,
            expectedTotal: &expectedTotal,
            accumulated: &accumulated
        ))
        XCTAssertEqual(accumulated, [1, 2, 3, 4])

        var invalid: [Int] = []
        var invalidExpectedTotal: Int?
        XCTAssertThrowsError(try SupabaseCloudRepository.appendCompleteKeysetPage(
            [1],
            rowIDs: [firstID],
            after: secondID,
            reportedCount: 1,
            expectedTotal: &invalidExpectedTotal,
            accumulated: &invalid
        ))
    }

    func testConditionalTimestampPreservesServerMicroseconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
        XCTAssertEqual(
            SupabaseCloudRepository.timestamp(date),
            "2023-11-14T22:13:20.123456Z"
        )
    }

    func testFactoryBuildsClientFromValidatedConfiguration() throws {
        let configuration = try CloudConfiguration(
            projectURL: URL(string: "https://example.supabase.co")!,
            publishableKey: "sb_publishable_unit_test"
        )
        // Construction is the shipping-capable gate: privileged keys are rejected
        // by CloudConfiguration before a client exists. The SDK surface of the
        // returned client is not public for URL/key introspection.
        let client = SupabaseClientFactory.make(
            configuration: configuration,
            keychainService: "com.phrasa.test.supabase.auth"
        )
        XCTAssertNotNil(client)
        XCTAssertThrowsError(
            try CloudConfiguration(
                projectURL: configuration.projectURL,
                publishableKey: "sb_secret_blocked"
            )
        )
    }

    func testSharedSupabaseSourcesStayWithinMinimalBackendContract() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PhrasaSyncSupabaseTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PhrasaSync package
        let supabaseSources = packageRoot
            .appendingPathComponent("Sources/PhrasaSyncSupabase", isDirectory: true)
        let fileManager = FileManager.default
        let enumerator = try XCTUnwrap(
            fileManager.enumerator(
                at: supabaseSources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        var combined = ""
        var fileCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            combined += try String(contentsOf: fileURL, encoding: .utf8)
            combined += "\n"
            fileCount += 1
        }
        XCTAssertGreaterThan(fileCount, 0)

        let forbidden = CloudBackendContract.forbiddenMatches(in: combined)
        XCTAssertEqual(
            forbidden,
            [],
            "PhrasaSyncSupabase must not assume \(forbidden.joined(separator: ", "))"
        )

        // Positive contract: only the allowed tables appear as PostgREST targets.
        for table in CloudBackendContract.allowedTables {
            XCTAssertTrue(
                combined.contains(".from(\"\(table)\")"),
                "Expected allowed table \(table) in shared repository"
            )
        }
        XCTAssertFalse(combined.contains(".storage"))
        XCTAssertFalse(combined.contains("client.storage"))
        XCTAssertEqual(
            CloudBackendContract.allowedRPCs,
            ["delete_own_account"]
        )
    }

    // MARK: - CloudReaderSettings.speedCountdown

    /// Wire encode/decode must round-trip every supported countdown value so
    /// multi-device sync does not drop Off / 5s / 15s preferences.
    func testCloudReaderSettingsSpeedCountdownRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for countdown in SpeedCountdown.allCases {
            var settings = ReaderSettings()
            settings.speedCountdown = countdown
            settings.normalize()
            let cloud = CloudReaderSettings(settings)
            let data = try encoder.encode(cloud)
            let decoded = try decoder.decode(CloudReaderSettings.self, from: data)
            XCTAssertEqual(
                decoded.speedCountdown,
                countdown,
                "round-trip failed for \(countdown)"
            )
            XCTAssertEqual(decoded.readerSettings.speedCountdown, countdown)

            // Wire payload stores the raw Int seconds value (not a string label).
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object["speedCountdown"] as? Int, countdown.rawValue)
        }
    }

    /// Legacy cloud preference blobs without `speedCountdown` must decode to the
    /// product default (5 seconds) rather than Off or failing open.
    func testCloudReaderSettingsLegacyPayloadWithoutSpeedCountdownDefaultsToFive() throws {
        let legacy = """
        {
          "mode":"speed",
          "scrollStyle":"continuous",
          "fontFamily":"hyperlegible",
          "fontSize":56,
          "lineHeight":1.45,
          "marginX":12,
          "align":"left",
          "theme":"stage",
          "mirrorH":false,
          "mirrorV":false,
          "focusPosition":0.25,
          "speedWpm":140,
          "recognitionLang":"en-US",
          "showPacing":true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CloudReaderSettings.self, from: legacy)
        XCTAssertEqual(decoded.speedCountdown, .fiveSeconds)
        XCTAssertEqual(decoded.readerSettings.speedCountdown, .fiveSeconds)
    }

    func testCloudReaderSettingsUnknownSpeedCountdownFallsBackToDefault() throws {
        let unknown = """
        {
          "mode":"speed",
          "scrollStyle":"continuous",
          "fontFamily":"hyperlegible",
          "fontSize":56,
          "lineHeight":1.45,
          "marginX":12,
          "align":"left",
          "theme":"stage",
          "mirrorH":false,
          "mirrorV":false,
          "focusPosition":0.25,
          "speedWpm":140,
          "speedCountdown":7,
          "recognitionLang":"en-US",
          "showPacing":true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CloudReaderSettings.self, from: unknown)
        XCTAssertEqual(decoded.speedCountdown, .fiveSeconds)
    }

    // MARK: - Update payloads omit immutable created_at

    func testScriptContentUpdatePayloadOmitsCreatedAtAndUpdatedAt() throws {
        let document = ScriptDocument(
            id: UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!,
            title: "QA",
            body: "body",
            tags: ["sync-qa", "handoff"],
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_000),
            updatedAt: Date(timeIntervalSince1970: 1_784_521_301.793_238)
        )
        let data = try JSONEncoder().encode(CloudScriptContentMutation(document: document))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["created_at"], "Content updates must not rewrite created_at")
        XCTAssertNil(object["createdAt"])
        XCTAssertNil(object["updated_at"])
        XCTAssertNil(object["updatedAt"])
        XCTAssertNil(object["last_opened_at"])
        XCTAssertEqual(object["tags"] as? [String], ["sync-qa", "handoff"])
        XCTAssertEqual(object["title"] as? String, "QA")
        XCTAssertEqual(object["body"] as? String, "body")
    }

    func testFolderRenamePayloadOmitsCreatedAt() throws {
        let folder = ScriptFolder(
            id: UUID(),
            name: "Renamed",
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_000)
        )
        let data = try JSONEncoder().encode(CloudFolderRenameMutation(folder: folder))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "Renamed")
        XCTAssertNil(object["created_at"])
        XCTAssertNil(object["createdAt"])
        XCTAssertNil(object["id"])
        XCTAssertNil(object["user_id"])
    }

    func testFolderInsertPayloadStillIncludesCreatedAt() throws {
        let folder = ScriptFolder(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "New",
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_000)
        )
        let data = try JSONEncoder().encode(
            CloudFolderInsertMutation(userID: UUID(), folder: folder)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "New")
        XCTAssertNotNil(object["created_at"], "Insert must still set created_at once")
    }

    func testWireMillisecondsKeepsParsedAlreadyMsDateCanonical() {
        // Production: already-aligned .734 must not become .733 under Double noise.
        let parsed = Date(timeIntervalSince1970: 1_784_520_732.734_000)
        XCTAssertEqual(CloudTimestampPrecision.wireMilliseconds(parsed), 1_784_520_732_734)
        let again = CloudTimestampPrecision.wireNormalized(parsed)
        XCTAssertEqual(CloudTimestampPrecision.wireMilliseconds(again), 1_784_520_732_734)
        XCTAssertTrue(CloudTimestampPrecision.wireMatches(parsed, again))

        // Sub-ms still collapses to the same wire ms (insert echo case).
        let sub = Date(timeIntervalSince1970: 1_784_520_732.734_980)
        XCTAssertEqual(CloudTimestampPrecision.wireMilliseconds(sub), 1_784_520_732_734)
        XCTAssertTrue(CloudTimestampPrecision.wireMatches(parsed, sub))
    }

    // MARK: - Open-update OCC boundary (fourth production failure)

    func testOpenUpdateScopeColumnsAndMonotonicOrFilter() {
        XCTAssertEqual(
            CloudScriptOpenUpdate.scopeFilterColumns.sorted(),
            ["id", "user_id"].sorted()
        )
        XCTAssertFalse(
            CloudScriptOpenUpdate.scopeFilterColumns.contains("last_opened_at"),
            "Equality OCC must not use last_opened_at (production-brittle)"
        )
        XCTAssertFalse(
            CloudScriptOpenUpdate.scopeFilterColumns.contains("updated_at"),
            "Recency metadata must not be blocked by an independent content timestamp"
        )

        let writeValue = CloudScriptOpenUpdate.valueToWrite(
            desired: Date(timeIntervalSince1970: 1_784_521_290.872_156)
        )
        let filter = CloudScriptOpenUpdate.monotonicOpenOrFilter(
            openToWrite: writeValue,
            timestamp: SupabaseCloudRepository.timestamp
        )
        XCTAssertTrue(filter.hasPrefix("last_opened_at.is.null,last_opened_at.lt.\""))
        XCTAssertTrue(filter.hasSuffix("\""))
        XCTAssertTrue(filter.contains(".872000Z\""))
        XCTAssertFalse(filter.contains("last_opened_at.eq."))
    }

    func testProductionOpenTimestampsFormatForUpdatedAtOCC() {
        // Remote authoritative clocks from production QA.
        let remoteUpdated = Date(timeIntervalSince1970: 1_784_521_303.075_535)
        let remoteOpened = Date(timeIntervalSince1970: 1_784_521_290.871_000)
        let localOpened = Date(timeIntervalSince1970: 1_784_521_290.872_156)

        let updatedStamp = SupabaseCloudRepository.timestamp(remoteUpdated)
        XCTAssertTrue(
            updatedStamp.hasSuffix(".075535Z"),
            "updated_at OCC must preserve full microseconds: \(updatedStamp)"
        )
        let openedStamp = SupabaseCloudRepository.timestamp(remoteOpened)
        XCTAssertTrue(
            openedStamp.hasSuffix(".871000Z"),
            "last_opened formatting is µs-padded: \(openedStamp)"
        )

        // Policy: open must advance; write value is wire-stable.
        XCTAssertTrue(
            CloudScriptOpenUpdate.needsAdvancement(desired: localOpened, current: remoteOpened)
        )
        let writeValue = CloudScriptOpenUpdate.valueToWrite(desired: localOpened)
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(writeValue),
            1_784_521_290_872
        )
        XCTAssertFalse(
            CloudScriptOpenUpdate.needsAdvancement(desired: localOpened, current: writeValue)
        )
    }

    func testOpenedMutationEncodesOnlyLastOpenedAt() throws {
        let open = CloudScriptOpenUpdate.valueToWrite(
            desired: Date(timeIntervalSince1970: 1_784_521_290.872_156)
        )
        let data = try JSONEncoder().encode(CloudScriptOpenedMutation(lastOpenedAt: open))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["last_opened_at"])
        XCTAssertNil(object["updated_at"])
        XCTAssertNil(object["created_at"])
        XCTAssertNil(object["title"])
        XCTAssertEqual(object.count, 1)
    }

    func testSourceDocumentsOpenUpdateDoesNotPredicateOnLastOpened() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoURL = packageRoot
            .appendingPathComponent("Sources/PhrasaSyncSupabase/SupabaseCloudRepository.swift")
        let source = try String(contentsOf: repoURL, encoding: .utf8)
        // Guard: open-update path must not reintroduce last_opened_at equality OCC.
        // Content delete still may eq updated_at; folder delete may eq created_at.
        let openUpdateRegion: String = {
            guard let start = source.range(of: "private func updateLastOpenedIfNeeded"),
                  let end = source.range(of: "private func reconcileLastOpenedWrite")
            else { return "" }
            return String(source[start.lowerBound..<end.lowerBound])
        }()
        XCTAssertFalse(
            openUpdateRegion.isEmpty,
            "Could not isolate updateLastOpenedIfNeeded for source audit"
        )
        // Executable filter calls only (ignore prose in comments).
        let executableLines = openUpdateRegion
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(
            executableLines.contains(".eq(\"last_opened_at\""),
            "Must not equality-filter last_opened_at (production-brittle)"
        )
        XCTAssertFalse(
            executableLines.contains(".eq(\"updated_at\""),
            "Open metadata must not depend on an exact content timestamp"
        )
        XCTAssertTrue(
            executableLines.contains(".or("),
            "Open update must use PostgREST or() for monotonic null/lt open filter"
        )
        XCTAssertTrue(openUpdateRegion.contains("monotonicOpenOrFilter"))
        XCTAssertTrue(openUpdateRegion.contains("CloudScriptOpenUpdate"))
        // Content mismatch on open reconcile must not silently return server.
        let reconcileRegion: String = {
            guard let start = source.range(of: "private func reconcileLastOpenedWrite"),
                  let end = source.range(of: "private func rememberScriptRow")
            else { return "" }
            return String(source[start.lowerBound..<end.lowerBound])
        }()
        XCTAssertTrue(
            reconcileRegion.contains("scriptConflict"),
            "Open reconcile must fail closed on content mismatch"
        )
        XCTAssertTrue(
            reconcileRegion.contains("incompleteRemoteSnapshot"),
            "Open still behind after retry must fail loudly, not return current"
        )
        // Exhausted retry must throw, not accept lagging open as success.
        XCTAssertTrue(reconcileRegion.contains("reconcileLastOpened.retryExhausted"))
    }

    // MARK: - Production JSON → wire OCC → request query items

    /// Exact remote representation after the tags update (production QA).
    /// PostgREST JSON uses `+00:00`, not `Z`.
    private var productionScriptJSON: Data {
        Data(
            """
            [{
              "id": "63E110D1-314E-49FA-B549-36DCC3B5F557",
              "folder_id": null,
              "title": "QA script",
              "body": "body",
              "source_type": "manual",
              "outline": null,
              "tags": ["sync-qa", "handoff"],
              "last_opened_at": "2026-07-20T04:21:30.871+00:00",
              "created_at": "2026-07-20T04:12:12.733+00:00",
              "updated_at": "2026-07-20T04:21:43.075535+00:00"
            }]
            """.utf8
        )
    }

    func testCloudScriptRowPreservesExactUpdatedAtWireFromProductionJSON() throws {
        let decoder = PostgrestClient.Configuration.jsonDecoder
        let rows = try decoder.decode([CloudScriptRow].self, from: productionScriptJSON)
        let row = try XCTUnwrap(rows.first)
        // Exact wire strings — including +00:00 — must be preserved for OCC.
        XCTAssertEqual(row.updatedAtWire, "2026-07-20T04:21:43.075535+00:00")
        XCTAssertEqual(row.lastOpenedAtWire, "2026-07-20T04:21:30.871+00:00")
        XCTAssertEqual(row.createdAtWire, "2026-07-20T04:12:12.733+00:00")
        // Parser accepts +00:00 and yields usable Dates.
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(row.updatedAt),
            1_784_521_303_075
        )
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(try XCTUnwrap(row.lastOpenedAt)),
            1_784_521_290_871
        )
        XCTAssertEqual(
            CloudTimestampPrecision.wireMilliseconds(row.createdAt),
            1_784_520_732_733
        )
        // Reformatted Date is not the OCC token (Z vs +00:00); cache must keep wire.
        let reformatted = SupabaseCloudRepository.timestamp(row.updatedAt)
        XCTAssertNotEqual(
            reformatted,
            row.updatedAtWire,
            "OCC must use preserved wire, not timestamp(Date) which emits Z"
        )
        XCTAssertTrue(reformatted.hasSuffix("Z"))
        XCTAssertTrue(row.updatedAtWire.hasSuffix("+00:00"))
    }

    func testOpenUpdateFilterQueryItemsUseIdentityAndMonotonicOpen() throws {
        let decoder = PostgrestClient.Configuration.jsonDecoder
        let row = try XCTUnwrap(
            try decoder.decode([CloudScriptRow].self, from: productionScriptJSON).first
        )
        let accountID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let openToWrite = CloudScriptOpenUpdate.valueToWrite(
            desired: Date(timeIntervalSince1970: 1_784_521_290.872_156)
        )
        let items = CloudScriptOpenUpdate.postgrestFilterQueryItems(
            scriptID: row.id,
            accountID: accountID,
            openToWrite: openToWrite,
            timestamp: SupabaseCloudRepository.timestamp
        )
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertNil(byName["updated_at"])
        // Open bound is our canonical write stamp (Z form from Self.timestamp).
        XCTAssertEqual(
            byName["or"],
            #"(last_opened_at.is.null,last_opened_at.lt."2026-07-20T04:21:30.872000Z")"#
        )
        XCTAssertEqual(byName["id"], "eq.\(row.id.uuidString)")
        XCTAssertEqual(byName["user_id"], "eq.\(accountID.uuidString)")
    }

    /// Builds the same PostgREST chain as the shipping open UPDATE and asserts
    /// the URL query items match the production-curl shape: identity scope plus
    /// monotonic open, without brittle content-timestamp coupling.
    func testPostgrestClientOpenUpdateRequestQueryItemsMatchProductionCurl() async throws {
        let decoder = PostgrestClient.Configuration.jsonDecoder
        let row = try XCTUnwrap(
            try decoder.decode([CloudScriptRow].self, from: productionScriptJSON).first
        )
        let accountID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let openToWrite = CloudScriptOpenUpdate.valueToWrite(
            desired: Date(timeIntervalSince1970: 1_784_521_290.872_156)
        )

        let expectedItems = CloudScriptOpenUpdate.postgrestFilterQueryItems(
            scriptID: row.id,
            accountID: accountID,
            openToWrite: openToWrite,
            timestamp: SupabaseCloudRepository.timestamp
        )

        final class Capture: @unchecked Sendable {
            var request: URLRequest?
        }
        let capture = Capture()
        let client = PostgrestClient(
            url: URL(string: "https://example.supabase.co/rest/v1")!,
            headers: [
                "apikey": "test",
                "Authorization": "Bearer test",
            ],
            fetch: { request in
                capture.request = request
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data("[]".utf8), response)
            }
        )

        _ = try await client
            .from("scripts")
            .update(CloudScriptOpenedMutation(lastOpenedAt: openToWrite))
            .eq("id", value: row.id.uuidString)
            .eq("user_id", value: accountID.uuidString)
            .or(
                CloudScriptOpenUpdate.monotonicOpenOrFilter(
                    openToWrite: openToWrite,
                    timestamp: SupabaseCloudRepository.timestamp
                )
            )
            .execute()

        let request = try XCTUnwrap(capture.request)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        // Use percentEncodedQueryItems when present; otherwise queryItems.
        let rawItems = components.queryItems ?? []
        let byName = Dictionary(uniqueKeysWithValues: rawItems.map { ($0.name, $0.value ?? "") })

        XCTAssertNil(byName["updated_at"], "Open metadata must not depend on content OCC")
        XCTAssertEqual(
            byName["or"],
            #"(last_opened_at.is.null,last_opened_at.lt."2026-07-20T04:21:30.872000Z")"#,
            "Monotonic or filter must match working curl shape, got \(byName["or"] ?? "nil")"
        )
        for item in expectedItems {
            XCTAssertEqual(
                byName[item.name],
                item.value,
                "Query item \(item.name) mismatch in \(url.absoluteString)"
            )
        }
    }

    func testOpenStillBehindAfterRetryIsNotSilentSuccess() {
        // Policy: isSatisfied false + exhausted retry must not be treated as success.
        let desired = ScriptDocument(
            id: UUID(uuidString: "63E110D1-314E-49FA-B549-36DCC3B5F557")!,
            title: "QA script",
            body: "body",
            tags: ["sync-qa", "handoff"],
            lastOpenedAt: Date(timeIntervalSince1970: 1_784_521_290.872_156),
            createdAt: Date(timeIntervalSince1970: 1_784_520_732.734_000),
            updatedAt: Date(timeIntervalSince1970: 1_784_521_303.075_535)
        )
        var current = desired
        current.lastOpenedAt = Date(timeIntervalSince1970: 1_784_521_290.871_000)
        XCTAssertTrue(
            CloudScriptOpenUpdate.needsAdvancement(
                desired: desired.lastOpenedAt,
                current: current.lastOpenedAt
            )
        )
        XCTAssertFalse(
            CloudScriptOpenUpdate.isSatisfied(desired: desired, current: current),
            "Lagging open must not count as satisfied"
        )
    }
}
