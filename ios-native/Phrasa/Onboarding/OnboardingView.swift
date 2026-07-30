import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private let pages = [
        OnboardingPage(
            icon: "square.and.pencil",
            eyebrow: "Write",
            title: "Your words, ready when you are.",
            detail: "Draft from scratch or import a text, Markdown, or PDF file. Everything works offline."
        ),
        OnboardingPage(
            icon: "text.viewfinder",
            eyebrow: "Present",
            title: "A reader that follows your pace.",
            detail: "Choose a steady speed or let speech recognition keep your place. Recognition stays on device when your hardware supports it."
        ),
        OnboardingPage(
            icon: "lock",
            eyebrow: "Private",
            title: "Local first, by design.",
            detail: "Your library stays on this device. You can export a complete backup anytime."
        )
    ]

    var body: some View {
        ZStack {
            PhrasaDesign.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    PhrasaWordmark()
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhrasaDesign.muted)
                        .phrasaTouchTarget()
                        .accessibilityHint("Skips introduction and opens the library")
                }
                .padding(.horizontal, PhrasaDesign.pagePadding)
                .padding(.top, 12)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                PhrasaIconBadge(systemImage: item.icon)
                                PhrasaEyebrow(text: item.eyebrow)
                                    .padding(.top, 2)
                                Text(item.title)
                                    .font(.system(.largeTitle, design: .default, weight: .semibold))
                                    .foregroundStyle(PhrasaDesign.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(item.detail)
                                    .font(.title3)
                                    .foregroundStyle(PhrasaDesign.muted)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 48)
                            .padding(.bottom, 56)
                        }
                        .tag(index)
                        .accessibilityElement(children: .combine)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? PhrasaDesign.ink : PhrasaDesign.border)
                            .frame(width: index == page ? 18 : 6, height: 6)
                    }
                }
                .animation(PhrasaDesign.motion(reduceMotion: reduceMotion), value: page)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(page + 1) of \(pages.count)")

                Button {
                    if page == pages.count - 1 {
                        finish()
                    } else {
                        PhrasaMotion.withAnimationIfAllowed(reduceMotion: reduceMotion) {
                            page += 1
                        }
                    }
                } label: {
                    Text(page == pages.count - 1 ? "Open my library" : "Continue")
                }
                .buttonStyle(PhrasaPrimaryButtonStyle())
                .padding(.horizontal, PhrasaDesign.pagePadding)
                .padding(.top, 14)
                .padding(.bottom, 22)
                .accessibilityHint(
                    page == pages.count - 1 ? "Finishes setup" : "Shows the next introduction page"
                )
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func finish() {
        isPresented = false
    }
}

private struct OnboardingPage {
    let icon: String
    let eyebrow: String
    let title: String
    let detail: String
}
