import SwiftUI

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("phrasa.onboarding.completed") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false
    @State private var showingFreshStartConfirmation = false

    var body: some View {
        Group {
            if library.isLoaded {
                LibraryView()
            } else {
                LaunchView()
            }
        }
        .alert(
            "Phrasa needs attention",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.clearError() } }
            ),
            actions: {
                if library.isLoaded {
                    Button("OK") { library.clearError() }
                } else {
                    Button("Try again") {
                        Task { await library.load() }
                    }
                    if library.canStartFreshAfterCorruption {
                        Button("Start fresh…", role: .destructive) {
                            showingFreshStartConfirmation = true
                        }
                    }
                }
            },
            message: { Text(library.errorMessage ?? "Please try again.") }
        )
        .confirmationDialog(
            "Start with a fresh library?",
            isPresented: $showingFreshStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Preserve damaged files and start fresh", role: .destructive) {
                Task { await library.startFreshAfterCorruption() }
            }
            Button("Cancel", role: .cancel) {
                library.redisplayRecoverableLoadError()
            }
        } message: {
            Text("Phrasa will move the damaged database into a recovery folder before creating a new library. It will not delete or overwrite the damaged files.")
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView(isPresented: Binding(
                get: { showingOnboarding },
                set: { value in
                    showingOnboarding = value
                    if !value { hasCompletedOnboarding = true }
                }
            ))
        }
        .onChange(of: library.isLoaded, initial: true) { _, isLoaded in
            if isLoaded && !hasCompletedOnboarding { showingOnboarding = true }
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            PhrasaDesign.canvas.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(PhrasaDesign.ink)
                ProgressView().tint(PhrasaDesign.ink.opacity(0.8))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading Phrasa")
        }
    }
}
