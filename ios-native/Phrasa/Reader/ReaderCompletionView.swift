import SwiftUI

struct ReaderCompletionView: View {
    @Environment(\.dismiss) private var dismiss
    let recap: ReaderCompletionRecap
    let onReadAgain: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(PhrasaDesign.ink)
                    .frame(width: 56, height: 56)
                    .background(PhrasaDesign.surfaceSecondary, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius)
                            .stroke(PhrasaDesign.border, lineWidth: 1)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run complete")
                        .font(.system(.largeTitle, design: .default, weight: .semibold))
                        .foregroundStyle(PhrasaDesign.ink)
                    Text(recap.wasResumed
                         ? "You picked up where you left off and finished the script."
                         : "You reached the end of the script.")
                        .foregroundStyle(PhrasaDesign.muted)
                }
                HStack(spacing: 12) {
                    recapCard("Time", recap.activeTime.compactDuration)
                    recapCard("Average", "\(Int(recap.averageWordsPerMinute.rounded())) wpm")
                }
                if let delta = recap.targetDelta {
                    Label(targetLabel(delta), systemImage: "timer")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PhrasaDesign.muted)
                }
                Spacer()
                Button("Read again") {
                    dismiss()
                    onReadAgain()
                }
                .buttonStyle(PhrasaSecondaryButtonStyle())
                Button("Done") {
                    dismiss()
                    onDone()
                }
                .buttonStyle(PhrasaPrimaryButtonStyle())
            }
            .padding(24)
            .background(PhrasaDesign.canvas)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func recapCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PhrasaDesign.ink)
            Text(title).font(.caption).foregroundStyle(PhrasaDesign.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
                .stroke(PhrasaDesign.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func targetLabel(_ delta: TimeInterval) -> String {
        if abs(delta) < 1 { return "Right on target" }
        return delta < 0
            ? "\(abs(delta).compactDuration) faster than target"
            : "\(delta.compactDuration) slower than target"
    }
}
