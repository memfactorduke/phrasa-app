import Foundation

/// Public HTTPS destinations exposed from the Library's About menu.
/// Centralized so Library menu presentation and tests share exact URL data.
/// Live-page reachability is an external deploy/operator concern, not proven here.
enum AppLegalDestination: String, CaseIterable, Identifiable, Sendable {
    case privacyPolicy
    case support
    case sourceCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy: "Privacy Policy"
        case .support: "Support"
        case .sourceCode: "Open Source Code"
        }
    }

    var systemImage: String {
        switch self {
        case .privacyPolicy: "hand.raised"
        case .support: "questionmark.circle"
        case .sourceCode: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Absolute HTTPS URL string (exact intended store destinations).
    var urlString: String {
        switch self {
        case .privacyPolicy: "https://phrasa.app/privacy"
        case .support: "https://phrasa.app/support"
        case .sourceCode: "https://github.com/memfactorduke/phrasa-app"
        }
    }

    var url: URL {
        // Static HTTPS constants; force-unwrap is intentional and covered by tests.
        URL(string: urlString)!
    }
}

/// Pure presentation descriptor for Library options menu legal links.
/// XCTest proves the exact destination data shared by the menu; it does not
/// prove that SwiftUI links are wired or exposed in the UI.
enum LibraryOptionsLegalPresentation: Sendable {
    static var destinations: [AppLegalDestination] {
        AppLegalDestination.allCases
    }

    static var titles: [String] {
        destinations.map(\.title)
    }

    static var urlStrings: [String] {
        destinations.map(\.urlString)
    }
}
