import SwiftUI

/// A lightweight, immutable summary of a script. Character counts use Swift's
/// user-perceived characters, so an emoji or accented grapheme counts as one.
struct DocumentInsights: Equatable, Sendable {
    let wordCount: Int
    let characterCount: Int
    let charactersExcludingWhitespace: Int
    let paragraphCount: Int
    let estimatedDuration: TimeInterval

    init(text: String, wordsPerMinute: Double = 150) {
        wordCount = TextMetrics.wordCount(text)
        characterCount = text.count
        charactersExcludingWhitespace = text.filter { !$0.isWhitespace }.count
        paragraphCount = text
            .components(separatedBy: "\n")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
        estimatedDuration = TextMetrics.estimatedDuration(text, wordsPerMinute: wordsPerMinute)
    }
}

struct DocumentInsightsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let text: String
    var wordsPerMinute: Double = 150

    private var insights: DocumentInsights {
        DocumentInsights(text: text, wordsPerMinute: wordsPerMinute)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("At a glance")
                            .font(.system(.title2, design: .default, weight: .semibold))
                            .foregroundStyle(PhrasaDesign.ink)
                        Text("A quick overview of this script at \(Int(wordsPerMinute.rounded())) words per minute.")
                            .font(.subheadline)
                            .foregroundStyle(PhrasaDesign.muted)
                    }

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        InsightCard(
                            title: "Words",
                            value: insights.wordCount.formatted(),
                            systemImage: "text.word.spacing"
                        )
                        InsightCard(
                            title: "Estimated time",
                            value: insights.estimatedDuration.compactDuration,
                            systemImage: "clock"
                        )
                        InsightCard(
                            title: "Characters",
                            value: insights.characterCount.formatted(),
                            detail: "\(insights.charactersExcludingWhitespace.formatted()) without spaces",
                            systemImage: "character.cursor.ibeam"
                        )
                        InsightCard(
                            title: "Paragraphs",
                            value: insights.paragraphCount.formatted(),
                            systemImage: "paragraph"
                        )
                    }
                }
                .padding(20)
            }
            .background(PhrasaDesign.canvas)
            .navigationTitle("Document insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct InsightCard: View {
    let title: String
    let value: String
    var detail: String? = nil
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(PhrasaDesign.muted)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(.title2, design: .default, weight: .semibold).monospacedDigit())
                .foregroundStyle(PhrasaDesign.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PhrasaDesign.muted)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PhrasaDesign.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(16)
        .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
                .stroke(PhrasaDesign.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
