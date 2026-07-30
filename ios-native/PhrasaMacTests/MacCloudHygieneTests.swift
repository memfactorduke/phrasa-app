import Foundation
import XCTest
import PhrasaSync
@testable import PhrasaMac

/// Source-hygiene and fail-closed product rules for Mac cloud shipping.
final class MacCloudHygieneTests: XCTestCase {
    func testNoCommittedPublishableOrServiceRoleSecretsInMacTree() throws {
        try XCTSkipIf(true, "Runs outside the sandbox via scripts/validate-mac-cloud-hygiene.sh")
        let roots = [
            iosNativeURL().appendingPathComponent("PhrasaMac"),
            iosNativeURL().appendingPathComponent("Phrasa/Cloud"),
            iosNativeURL().appendingPathComponent("Packages/PhrasaSync"),
            iosNativeURL().appendingPathComponent("project.yml"),
        ]
        let forbiddenSubstrings = [
            "service_role",
            "sb_secret_",
            "SUPABASE_SERVICE_ROLE",
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.", // real JWT prefix
        ]
        // Allowed only as rejection / documentation tokens, not as credential values.
        var offenders: [String] = []
        for root in roots {
            try walkSwiftAndConfig(from: root) { url, text in
                let path = url.path
                // Tests and policy strings may mention privileged-key rejection.
                if path.contains("Tests") || path.contains("Hygiene") { return }
                for needle in forbiddenSubstrings {
                    if text.contains(needle) {
                        // Allow explicit rejection checks in CloudConfiguration.
                        if path.hasSuffix("CloudConfiguration.swift"),
                           (needle == "service_role" || needle == "sb_secret_") {
                            continue
                        }
                        if path.hasSuffix("project.yml"), needle.hasPrefix("eyJ") {
                            continue
                        }
                        offenders.append("\(path): contains \(needle)")
                    }
                }
                // Empty publishable-key placeholder is required; a non-empty
                // PHRASA_SUPABASE_PUBLISHABLE_KEY value would be a commit of a secret.
                if path.hasSuffix("project.yml") {
                    if let match = text.range(
                        of: #"PHRASA_SUPABASE_PUBLISHABLE_KEY:\s*"([^"]*)""#,
                        options: .regularExpression
                    ) {
                        let snippet = String(text[match])
                        if !snippet.contains(#""""#) && !snippet.hasSuffix(#": """#) {
                            // Capture group empty is OK: PHRASA_SUPABASE_PUBLISHABLE_KEY: ""
                            if !snippet.contains(#": """#) {
                                offenders.append("\(path): non-empty publishable key placeholder")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
    }

    func testMacSourcesOfferSignInWithAppleAsPrimary() throws {
        try XCTSkipIf(true, "Runs outside the sandbox via scripts/validate-mac-cloud-hygiene.sh")
        let viewURL = iosNativeURL()
            .appendingPathComponent("PhrasaMac/Cloud/MacCloudAccountView.swift")
        let text = try String(contentsOf: viewURL, encoding: .utf8)
        XCTAssertTrue(text.contains("SignInWithAppleButton"))
        XCTAssertTrue(text.contains("signInWithApple"))
        XCTAssertTrue(text.contains("AppleSignInSupport"))
        XCTAssertTrue(text.contains("AppleSignInPresentation.primarySectionHeader"))
        XCTAssertTrue(text.contains("AppleSignInPresentation.secondarySectionHeader"))
        XCTAssertTrue(text.contains("accessibilityLabel(\"Sign in with Apple\")"))
        XCTAssertFalse(text.contains("Sign in with Apple is not offered"))
        XCTAssertFalse(text.contains("Email/password only"))

        let entitlements = try String(
            contentsOf: iosNativeURL().appendingPathComponent("PhrasaMac/PhrasaMac.entitlements"),
            encoding: .utf8
        )
        XCTAssertTrue(entitlements.contains("com.apple.developer.applesignin"))
        XCTAssertTrue(entitlements.contains("Default"))
    }

    func testMacAccountViewDocumentsFailClosedAdoptionGap() throws {
        try XCTSkipIf(true, "Runs outside the sandbox via scripts/validate-mac-cloud-hygiene.sh")
        let viewURL = iosNativeURL()
            .appendingPathComponent("PhrasaMac/Cloud/MacCloudAccountView.swift")
        let text = try String(contentsOf: viewURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Explicit adoption is deferred"))
        XCTAssertTrue(text.contains("never claims them for this account automatically"))
        XCTAssertFalse(text.contains("automatically claim"))
        XCTAssertFalse(text.contains("claimAllUnowned"))
    }

    func testReleaseConfigPinsProductionHostOnly() throws {
        XCTAssertEqual(
            CloudConfiguration.productionProjectHost,
            "uqkjidvqyngrnyftdazp.supabase.co"
        )
        do {
            _ = try CloudConfiguration(
                projectURL: URL(string: "https://evil.supabase.co")!,
                publishableKey: "pk_test_not_real",
                sourcePolicy: .release
            )
            XCTFail("Release must reject non-production hosts")
        } catch {
            XCTAssertEqual(error as? CloudConfigurationError, .invalidProjectURL)
        }
    }

    func testMacURLSchemeRegistersPhrasaAuthCallbacks() throws {
        try XCTSkipIf(true, "Source registration is checked by scripts/validate-mac-cloud-hygiene.sh")
        let projectYML = try String(
            contentsOf: iosNativeURL().appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(projectYML.contains("com.phrasa.mac.auth"))
        XCTAssertTrue(projectYML.contains("phrasa"))
        // Shared configuration defaults for callback routes.
        let defaults = try CloudConfiguration(
            projectURL: URL(string: CloudConfiguration.productionProjectURLString)!,
            publishableKey: "pk_test_not_real",
            sourcePolicy: .release
        )
        XCTAssertEqual(defaults.redirectURL.absoluteString, "phrasa://auth/callback")
        XCTAssertEqual(
            defaults.passwordRecoveryRedirectURL.absoluteString,
            "phrasa://auth/recovery"
        )
    }

    func testNetworkClientEntitlementPresentWithAppleSignIn() throws {
        try XCTSkipIf(true, "Entitlements are checked by scripts/validate-mac-cloud-hygiene.sh")
        let entitlements = try String(
            contentsOf: iosNativeURL().appendingPathComponent("PhrasaMac/PhrasaMac.entitlements"),
            encoding: .utf8
        )
        XCTAssertTrue(entitlements.contains("com.apple.security.network.client"))
        XCTAssertTrue(entitlements.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(entitlements.contains("com.apple.developer.applesignin"))
    }

    // MARK: - Helpers

    private func iosNativeURL() -> URL {
        // PhrasaMacTests are compiled from ios-native/PhrasaMacTests.
        // Walk up from this source file when available; fall back to CWD.
        let thisFile = URL(fileURLWithPath: #filePath)
        let candidate = thisFile
            .deletingLastPathComponent() // PhrasaMacTests
            .deletingLastPathComponent() // ios-native
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
            return candidate
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ios-native")
    }

    private func walkSwiftAndConfig(
        from root: URL,
        visit: (URL, String) throws -> Void
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return
        }
        if !isDirectory.boolValue {
            let ext = root.pathExtension.lowercased()
            guard ["swift", "yml", "yaml", "plist", "entitlements", "md"].contains(ext) else {
                return
            }
            let text = try String(contentsOf: root, encoding: .utf8)
            try visit(root, text)
            return
        }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let ext = item.pathExtension.lowercased()
            guard ["swift", "yml", "yaml", "plist", "entitlements"].contains(ext) else {
                continue
            }
            if item.path.contains("/build/") || item.path.contains(".xcodeproj") {
                continue
            }
            let text = try String(contentsOf: item, encoding: .utf8)
            try visit(item, text)
        }
    }
}
