import XCTest
@testable import Phrasa

final class AppStoreHygieneTests: XCTestCase {
    func testLegalDestinationURLsAreExactIntendedPaths() {
        XCTAssertEqual(
            AppLegalDestination.privacyPolicy.urlString,
            "https://phrasa.app/privacy"
        )
        XCTAssertEqual(
            AppLegalDestination.support.urlString,
            "https://phrasa.app/support"
        )
        XCTAssertEqual(
            AppLegalDestination.sourceCode.urlString,
            "https://github.com/memfactorduke/phrasa-app"
        )
        XCTAssertEqual(
            AppLegalDestination.privacyPolicy.url.absoluteString,
            "https://phrasa.app/privacy"
        )
        XCTAssertEqual(
            AppLegalDestination.support.url.absoluteString,
            "https://phrasa.app/support"
        )
        XCTAssertEqual(
            AppLegalDestination.sourceCode.url.absoluteString,
            "https://github.com/memfactorduke/phrasa-app"
        )
        XCTAssertEqual(AppLegalDestination.privacyPolicy.url.scheme, "https")
        XCTAssertEqual(AppLegalDestination.support.url.scheme, "https")
        XCTAssertEqual(AppLegalDestination.sourceCode.url.scheme, "https")
    }

    func testLibraryOptionsMenuPresentationDataContainsPrivacyAndSupport() {
        let destinations = LibraryOptionsLegalPresentation.destinations
        XCTAssertEqual(destinations, AppLegalDestination.allCases)
        XCTAssertEqual(destinations.count, 3)
        XCTAssertTrue(destinations.contains(.privacyPolicy))
        XCTAssertTrue(destinations.contains(.support))
        XCTAssertTrue(destinations.contains(.sourceCode))

        XCTAssertEqual(
            LibraryOptionsLegalPresentation.titles,
            ["Privacy Policy", "Support", "Open Source Code"]
        )
        XCTAssertEqual(
            LibraryOptionsLegalPresentation.urlStrings,
            [
                "https://phrasa.app/privacy",
                "https://phrasa.app/support",
                "https://github.com/memfactorduke/phrasa-app",
            ]
        )
    }

    func testMicrophoneUsageDescriptionCoversVoiceFollowAndNoPhrasaServers() throws {
        let info = try XCTUnwrap(Bundle(for: LibraryStore.self).infoDictionary)
        let description = try XCTUnwrap(
            info["NSMicrophoneUsageDescription"] as? String
        )
        XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(
            description.localizedCaseInsensitiveContains("microphone"),
            "Mic usage string should name the microphone: \(description)"
        )
        XCTAssertTrue(
            description.localizedCaseInsensitiveContains("voice")
                || description.localizedCaseInsensitiveContains("follow"),
            "Mic usage string should explain voice-following purpose: \(description)"
        )
        XCTAssertTrue(
            description.contains("never sent to Phrasa's servers")
                || description.contains("never sent to Phrasa’s servers"),
            "Mic usage string should state audio is not sent to Phrasa servers: \(description)"
        )
    }

    func testSpeechRecognitionUsageDescriptionMentionsAppleProcessingAndNoDeveloperServerRetention() throws {
        let info = try XCTUnwrap(Bundle(for: LibraryStore.self).infoDictionary)
        let description = try XCTUnwrap(
            info["NSSpeechRecognitionUsageDescription"] as? String
        )
        XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(
            description.contains("on-device"),
            "Usage string should explain on-device preference: \(description)"
        )
        XCTAssertTrue(
            description.contains("Apple may process speech"),
            "Usage string should disclose Apple processing when on-device is unavailable: \(description)"
        )
        XCTAssertTrue(
            description.contains("does not send or retain audio or transcripts on developer-controlled servers"),
            "Usage string should state no developer-controlled server retention of audio/transcripts: \(description)"
        )
    }

    func testVoicePermissionUsageKeysPresentForBothEntryPaths() throws {
        // Voice Follow (ReaderView) and Outline both share SpeechRecognitionService;
        // both system prompts require these Info.plist keys in the shipping bundle.
        let info = try XCTUnwrap(Bundle(for: LibraryStore.self).infoDictionary)
        XCTAssertNotNil(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertNotNil(info["NSSpeechRecognitionUsageDescription"] as? String)
        XCTAssertEqual(VoicePermissionGate.requestOrder.first, .microphone)
        XCTAssertEqual(VoicePermissionGate.requestOrder.last, .speechRecognition)
    }

    func testExportComplianceDeclaresExemptEncryptionOnly() throws {
        let info = try XCTUnwrap(Bundle(for: LibraryStore.self).infoDictionary)
        let usesNonExempt = try XCTUnwrap(
            info["ITSAppUsesNonExemptEncryption"] as? Bool
        )
        XCTAssertFalse(
            usesNonExempt,
            "Local-only build must declare ITSAppUsesNonExemptEncryption = false"
        )
    }

    func testShippingInfoPlistKeepsPinnedProductionURLEmptyKeyAndIdentity() throws {
        let info = try XCTUnwrap(Bundle(for: LibraryStore.self).infoDictionary)
        let productionURL = CloudConfiguration.productionProjectURLString

        let urlValue = try XCTUnwrap(info[CloudConfiguration.urlInfoKey] as? String)
        XCTAssertTrue(
            urlValue == productionURL || urlValue == "$(PHRASA_SUPABASE_URL)",
            "Shipping Info.plist URL must be the pinned production host or its build-setting placeholder, got \(urlValue)"
        )

        let keyValue = info[CloudConfiguration.publishableKeyInfoKey] as? String ?? ""
        XCTAssertTrue(
            keyValue.isEmpty || keyValue == "$(PHRASA_SUPABASE_PUBLISHABLE_KEY)",
            "Publishable key must remain the empty operator placeholder, got \(keyValue)"
        )

        // Empty key keeps cloud offline/incomplete even with the pinned URL.
        // Release also ignores env — evil overrides must not create a client.
        XCTAssertThrowsError(
            try CloudConfiguration.load(
                infoDictionary: info,
                environment: [
                    "SUPABASE_URL": "https://evil.example.com",
                    "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_evil",
                ],
                sourcePolicy: .release
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .incompleteConfiguration)
        }

        // With the publishable key supplied at load time, only the production host
        // is accepted; foreign hosts still fail under Release policy.
        let ready = try CloudConfiguration.load(
            infoDictionary: [
                CloudConfiguration.urlInfoKey: productionURL,
                CloudConfiguration.publishableKeyInfoKey: "sb_publishable_shipping",
            ],
            environment: [
                "SUPABASE_URL": "https://evil.example.com",
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_evil",
            ],
            sourcePolicy: .release
        )
        XCTAssertEqual(ready?.projectURL.absoluteString, productionURL)
        XCTAssertEqual(ready?.publishableKey, "sb_publishable_shipping")

        XCTAssertThrowsError(
            try CloudConfiguration.load(
                infoDictionary: [
                    CloudConfiguration.urlInfoKey: "https://other.supabase.co",
                    CloudConfiguration.publishableKeyInfoKey: "sb_publishable_shipping",
                ],
                environment: [:],
                sourcePolicy: .release
            )
        ) { error in
            XCTAssertEqual(error as? CloudConfigurationError, .invalidProjectURL)
        }

        XCTAssertNotNil(
            info["CFBundleURLTypes"],
            "Shipping app registers the phrasa:// auth callback scheme"
        )
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Phrasa")
        // Marketing/version keys may be expanded from build settings in the host
        // app; assert the placeholders or concrete release values are present.
        let shortVersion = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertFalse(shortVersion.isEmpty)
        XCTAssertFalse(build.isEmpty)
        // Candidate lineage is 1.0 / 14 when settings expand; accept either the
        // expanded values or the Xcode variable forms used in the Info.plist source.
        let shortOK = shortVersion == "1.0" || shortVersion.contains("MARKETING_VERSION")
        let buildOK = build == "14" || build.contains("CURRENT_PROJECT_VERSION")
        XCTAssertTrue(shortOK, "Unexpected short version: \(shortVersion)")
        XCTAssertTrue(buildOK, "Unexpected build: \(build)")
    }

    func testGeneratedProjectLinksCloudSDKIntoShippingIOSAndMacTargets() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYAML = try String(
            contentsOf: iosRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let shippingTarget = try XCTUnwrap(
            projectYAML.split(separator: "  PhrasaTests:", maxSplits: 1).first?
                .split(separator: "  Phrasa:", maxSplits: 1).last
        )
        // iOS shipping now includes Cloud UI/auth and Supabase adapter.
        XCTAssertFalse(shippingTarget.contains("- Cloud/**"))
        XCTAssertTrue(shippingTarget.contains("- package: Supabase"))
        XCTAssertTrue(shippingTarget.contains("PhrasaSyncSupabase"))
        XCTAssertTrue(shippingTarget.contains("CFBundleURLTypes"))
        XCTAssertTrue(shippingTarget.contains("Packages/PhrasaSync/Sources/PhrasaSync"))
        // Sign in with Apple is the primary account path — entitlements required.
        XCTAssertTrue(shippingTarget.contains("CODE_SIGN_ENTITLEMENTS: Phrasa/Phrasa.entitlements"))
        XCTAssertTrue(shippingTarget.contains("Phrasa.entitlements"))

        // Build settings pin the exact production URL for Debug and Release; the
        // publishable key remains the empty operator placeholder.
        let productionURL = CloudConfiguration.productionProjectURLString
        XCTAssertTrue(
            shippingTarget.contains("PHRASA_SUPABASE_URL: \"\(productionURL)\""),
            "project.yml Phrasa target must pin PHRASA_SUPABASE_URL to \(productionURL)"
        )
        XCTAssertTrue(
            shippingTarget.contains("PHRASA_SUPABASE_PUBLISHABLE_KEY: \"\""),
            "project.yml Phrasa target must keep PHRASA_SUPABASE_PUBLISHABLE_KEY empty"
        )

        let pbxproj = try String(
            contentsOf: iosRoot
                .appendingPathComponent("PhrasaNative.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        // Generated build settings must carry the same exact URL (Debug + Release).
        let urlAssignments = pbxproj.components(separatedBy: "\n").filter {
            $0.contains("PHRASA_SUPABASE_URL")
        }
        XCTAssertFalse(urlAssignments.isEmpty, "pbxproj must set PHRASA_SUPABASE_URL")
        for line in urlAssignments {
            XCTAssertTrue(
                line.contains(productionURL),
                "Every PHRASA_SUPABASE_URL assignment must be the pinned production URL: \(line)"
            )
        }
        let keyAssignments = pbxproj.components(separatedBy: "\n").filter {
            $0.contains("PHRASA_SUPABASE_PUBLISHABLE_KEY")
        }
        XCTAssertFalse(keyAssignments.isEmpty, "pbxproj must set PHRASA_SUPABASE_PUBLISHABLE_KEY")
        for line in keyAssignments {
            XCTAssertTrue(
                line.contains("PHRASA_SUPABASE_PUBLISHABLE_KEY = \"\";")
                    || line.contains("PHRASA_SUPABASE_PUBLISHABLE_KEY = ;")
                    || line.contains("PHRASA_SUPABASE_PUBLISHABLE_KEY = \"\""),
                "Publishable key must stay empty in generated build settings: \(line)"
            )
        }

        let testTarget = try XCTUnwrap(
            projectYAML.split(separator: "  PhrasaTests:", maxSplits: 1).last?
                .split(separator: "  PhrasaMac:", maxSplits: 1).first
        )
        // Tests no longer recompile Cloud/adapter sources; they use the app target.
        XCTAssertFalse(testTarget.contains("- path: Phrasa/Cloud"))
        XCTAssertFalse(testTarget.contains("PhrasaSyncSupabase"))

        // Mac shipping links the same Supabase transport + shared auth coordinator
        // with Sign in with Apple primary. Publishable key stays empty.
        let macTarget = try XCTUnwrap(
            projectYAML.split(separator: "  PhrasaMac:", maxSplits: 1).last?
                .split(separator: "  PhrasaMacTests:", maxSplits: 1).first
        )
        XCTAssertTrue(macTarget.contains("product: PhrasaSync"))
        XCTAssertTrue(macTarget.contains("PhrasaSyncSupabase"))
        XCTAssertTrue(macTarget.contains("- package: Supabase"))
        XCTAssertTrue(macTarget.contains("CloudCoordinator.swift"))
        XCTAssertTrue(macTarget.contains("SupabaseAuthService.swift"))
        XCTAssertTrue(macTarget.contains("AppleSignInSupport.swift"))
        XCTAssertTrue(macTarget.contains("CFBundleURLTypes"))
        XCTAssertTrue(
            macTarget.contains("PHRASA_SUPABASE_URL: \"\(productionURL)\""),
            "project.yml PhrasaMac target must pin PHRASA_SUPABASE_URL to \(productionURL)"
        )
        XCTAssertTrue(
            macTarget.contains("PHRASA_SUPABASE_PUBLISHABLE_KEY: \"\""),
            "project.yml PhrasaMac target must keep PHRASA_SUPABASE_PUBLISHABLE_KEY empty"
        )
        XCTAssertTrue(macTarget.contains("CODE_SIGN_ENTITLEMENTS: PhrasaMac/PhrasaMac.entitlements"))
    }

    func testShippingSignInWithAppleEntitlementsUseDefaultCapability() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosEntitlements = try String(
            contentsOf: iosRoot.appendingPathComponent("Phrasa/Phrasa.entitlements"),
            encoding: .utf8
        )
        XCTAssertTrue(iosEntitlements.contains("com.apple.developer.applesignin"))
        XCTAssertTrue(iosEntitlements.contains("Default"))

        let macEntitlements = try String(
            contentsOf: iosRoot.appendingPathComponent("PhrasaMac/PhrasaMac.entitlements"),
            encoding: .utf8
        )
        XCTAssertTrue(macEntitlements.contains("com.apple.developer.applesignin"))
        XCTAssertTrue(macEntitlements.contains("Default"))
        XCTAssertTrue(macEntitlements.contains("com.apple.security.network.client"))
    }

    func testPrivacyManifestShipsWithNoTrackingAndUserDefaultsReason() throws {
        let bundle = Bundle(for: LibraryStore.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy must ship in the app bundle"
        )
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let root = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(root["NSPrivacyTracking"] as? Bool, false)
        let trackingDomains = try XCTUnwrap(root["NSPrivacyTrackingDomains"] as? [Any])
        XCTAssertTrue(trackingDomains.isEmpty)
        let collected = try XCTUnwrap(root["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        // Optional sync: Email Address, User ID, Other User Content — linked,
        // App Functionality, not tracking. Keep in sync with App Store packet.
        let expectedTypes: Set<String> = [
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeOtherUserContent",
        ]
        let gotTypes = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(gotTypes, expectedTypes)
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            let purposes = try XCTUnwrap(entry["NSPrivacyCollectedDataTypePurposes"] as? [String])
            XCTAssertTrue(
                purposes.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"),
                "Each collected type must declare App Functionality"
            )
        }
        let accessed = try XCTUnwrap(root["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let userDefaults = accessed.first {
            ($0["NSPrivacyAccessedAPIType"] as? String)
                == "NSPrivacyAccessedAPICategoryUserDefaults"
        }
        let reasons = try XCTUnwrap(userDefaults?["NSPrivacyAccessedAPITypeReasons"] as? [String])
        XCTAssertTrue(
            reasons.contains("CA92.1"),
            "UserDefaults access must declare CA92.1: \(reasons)"
        )
    }

    func testAtkinsonHyperlegibleOFLIsBundledWithAuthoritativeCopyright() throws {
        let bundle = Bundle(for: LibraryStore.self)
        let oflURL = try XCTUnwrap(
            bundle.url(forResource: "OFL", withExtension: "txt"),
            "OFL.txt must ship as an app resource next to the bundled font"
        )
        let text = try String(contentsOf: oflURL, encoding: .utf8)
        // Matches name-table copyright on AtkinsonHyperlegible-Regular.ttf and
        // upstream OFL.txt (googlefonts/atkinson-hyperlegible, google/fonts ofl).
        XCTAssertTrue(
            text.contains("Copyright 2020 Braille Institute of America, Inc."),
            "Bundled OFL must carry the font's copyright holder"
        )
        XCTAssertTrue(
            text.contains("SIL OPEN FONT LICENSE Version 1.1"),
            "Bundled notice must be SIL OFL 1.1"
        )
        XCTAssertTrue(
            text.contains("This Font Software is licensed under the SIL Open Font License, Version 1.1."),
            "Bundled notice must include the OFL preamble line from the authoritative license file"
        )
    }
}
