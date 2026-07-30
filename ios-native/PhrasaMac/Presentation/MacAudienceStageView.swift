import AppKit
import SwiftUI
import PhrasaDomain

/// Shared appearance for controller + audience (settings/theme only).
@MainActor
@Observable
final class MacReaderAppearanceState {
    var settings: ReaderSettings

    init(settings: ReaderSettings = ReaderSettings()) {
        self.settings = settings
    }
}

/// Chrome-free audience stage bound to the same session/settings/script.
/// Passive: never creates a clock and cannot scrub progress.
struct MacAudienceStageView: View {
    var session: MacPresentationSession
    var appearance: MacReaderAppearanceState
    let text: String

    var body: some View {
        let settings = appearance.settings
        ZStack {
            settings.theme.background.ignoresSafeArea()

            MacPrompterTextView(
                text: text,
                settings: settings,
                progress: session.progress,
                allowsScrubbing: false,
                onProgressChange: nil
            )
            .opacity(session.isBlackout ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if session.isBlackout {
                Color.black.ignoresSafeArea()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

/// Hosts `MacAudienceStageView` in an AppKit content view for the audience window.
@MainActor
enum MacAudienceStageHosting {
    static func makeView(
        session: MacPresentationSession,
        appearance: MacReaderAppearanceState,
        text: String
    ) -> NSView {
        let root = MacAudienceStageView(
            session: session,
            appearance: appearance,
            text: text
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        return hosting
    }
}
