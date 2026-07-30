import Foundation
import SwiftUI

struct FindReplaceOptions: Equatable, Sendable {
    var isCaseSensitive = false
    var matchesWholeWords = false
}

struct FindMatch: Equatable, Sendable {
    /// UTF-16 range, matching the range convention used by Apple's text system.
    let range: NSRange

    func stringRange(in text: String) -> Range<String.Index>? {
        Range(range, in: text)
    }
}

struct FindReplaceResult: Equatable, Sendable {
    let text: String
    let replacementCount: Int
}

enum FindReplaceEngine {
    static func matches(
        query: String,
        in text: String,
        options: FindReplaceOptions = .init()
    ) -> [FindMatch] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        guard let expression = expression(for: query, options: options) else { return [] }

        let entireText = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: entireText).map { FindMatch(range: $0.range) }
    }

    static func replacing(
        match: FindMatch,
        with replacement: String,
        in text: String
    ) -> FindReplaceResult {
        guard match.range.location != NSNotFound,
              match.range.location >= 0,
              match.range.length >= 0,
              NSMaxRange(match.range) <= (text as NSString).length
        else {
            return FindReplaceResult(text: text, replacementCount: 0)
        }

        let updated = (text as NSString).replacingCharacters(in: match.range, with: replacement)
        return FindReplaceResult(text: updated, replacementCount: 1)
    }

    static func replacingAll(
        query: String,
        with replacement: String,
        in text: String,
        options: FindReplaceOptions = .init()
    ) -> FindReplaceResult {
        guard !query.isEmpty, !text.isEmpty,
              let expression = expression(for: query, options: options)
        else {
            return FindReplaceResult(text: text, replacementCount: 0)
        }

        let entireText = NSRange(text.startIndex..<text.endIndex, in: text)
        let count = expression.numberOfMatches(in: text, range: entireText)
        guard count > 0 else { return FindReplaceResult(text: text, replacementCount: 0) }

        let literalReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        let updated = expression.stringByReplacingMatches(
            in: text,
            range: entireText,
            withTemplate: literalReplacement
        )
        return FindReplaceResult(text: updated, replacementCount: count)
    }

    private static func expression(
        for query: String,
        options: FindReplaceOptions
    ) -> NSRegularExpression? {
        var pattern = NSRegularExpression.escapedPattern(for: query)
        if options.matchesWholeWords {
            // Unlike `\b`, these boundaries work predictably for accented and
            // non-Latin letters as well as combining marks.
            let wordCharacter = #"[\p{L}\p{M}\p{N}_]"#
            pattern = "(?<!\(wordCharacter))\(pattern)(?!\(wordCharacter))"
        }

        let expressionOptions: NSRegularExpression.Options = options.isCaseSensitive
            ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: pattern, options: expressionOptions)
    }
}

struct FindReplaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String

    @State private var query = ""
    @State private var replacement = ""
    @State private var options = FindReplaceOptions()
    @State private var matches: [FindMatch] = []
    @State private var selectedMatchIndex = 0
    @State private var statusMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case query
        case replacement
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    searchField
                    replacementField
                    optionsRow
                }
                .padding(20)

                Divider().overlay(PhrasaDesign.border)

                matchArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(PhrasaDesign.border)
                actionBar
                    .padding(16)
            }
            .background(PhrasaDesign.canvas)
            .navigationTitle("Find & replace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            focusedField = .query
            refreshMatches()
        }
        .onChange(of: query) { _, _ in refreshMatches() }
        .onChange(of: options) { _, _ in refreshMatches() }
        .onChange(of: text) { _, _ in refreshMatches(keepSelection: true) }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PhrasaDesign.muted)
            TextField("Find", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .query)
                .onSubmit { focusedField = .replacement }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PhrasaDesign.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius).stroke(PhrasaDesign.border, lineWidth: 1)
        }
    }

    private var replacementField: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(PhrasaDesign.muted)
            TextField("Replace with", text: $replacement)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedField, equals: .replacement)
                .onSubmit { replaceCurrent() }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius).stroke(PhrasaDesign.border, lineWidth: 1)
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $options.isCaseSensitive) {
                Text("Aa")
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityLabel("Match case")

            Toggle(isOn: $options.matchesWholeWords) {
                Label("Whole word", systemImage: "textformat")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)

            Spacer()

            Text(matchCountLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(PhrasaDesign.muted)
                .accessibilityLabel(matchCountAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var matchArea: some View {
        if query.isEmpty {
            ContentUnavailableView(
                "Find in this script",
                systemImage: "text.magnifyingglass",
                description: Text("Enter a word or phrase above.")
            )
        } else if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            VStack(spacing: 16) {
                Spacer(minLength: 10)
                MatchPreview(text: text, match: matches[selectedMatchIndex])
                    .padding(.horizontal, 20)
                HStack(spacing: 20) {
                    Button { moveSelection(by: -1) } label: {
                        Label("Previous", systemImage: "chevron.up")
                    }
                    Button { moveSelection(by: 1) } label: {
                        Label("Next", systemImage: "chevron.down")
                    }
                }
                .buttonStyle(.bordered)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(PhrasaDesign.muted)
                        .transition(.opacity)
                }
                Spacer(minLength: 10)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Replace") { replaceCurrent() }
                .buttonStyle(.bordered)
                .disabled(matches.isEmpty)
            Button("Replace all") { replaceAll() }
                .buttonStyle(.borderedProminent)
                .tint(PhrasaDesign.ink)
                .disabled(matches.isEmpty)
            Spacer()
        }
    }

    private var matchCountLabel: String {
        guard !matches.isEmpty else { return query.isEmpty ? "" : "No matches" }
        return "\(selectedMatchIndex + 1) of \(matches.count)"
    }

    private var matchCountAccessibilityLabel: String {
        guard !matches.isEmpty else { return query.isEmpty ? "" : "No matches" }
        return "Match \(selectedMatchIndex + 1) of \(matches.count)"
    }

    private func refreshMatches(keepSelection: Bool = false) {
        let oldIndex = selectedMatchIndex
        matches = FindReplaceEngine.matches(query: query, in: text, options: options)
        selectedMatchIndex = keepSelection
            ? min(oldIndex, max(0, matches.count - 1))
            : 0
        statusMessage = nil
    }

    private func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex + offset + matches.count) % matches.count
        statusMessage = nil
    }

    private func replaceCurrent() {
        guard matches.indices.contains(selectedMatchIndex) else { return }
        let result = FindReplaceEngine.replacing(
            match: matches[selectedMatchIndex],
            with: replacement,
            in: text
        )
        text = result.text
        statusMessage = result.replacementCount == 1 ? "Replaced" : nil
    }

    private func replaceAll() {
        let result = FindReplaceEngine.replacingAll(
            query: query,
            with: replacement,
            in: text,
            options: options
        )
        text = result.text
        statusMessage = result.replacementCount == 1
            ? "Replaced 1 match"
            : "Replaced \(result.replacementCount) matches"
    }
}

private struct MatchPreview: View {
    let text: String
    let match: FindMatch

    var body: some View {
        Group {
            if let range = match.stringRange(in: text) {
                let context = contextParts(around: range)
                (Text(context.before)
                    + Text(context.match).bold().underline()
                    + Text(context.after))
            } else {
                Text("The selected match is no longer available.")
                    .foregroundStyle(PhrasaDesign.muted)
            }
        }
        .font(.body)
        .foregroundStyle(PhrasaDesign.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PhrasaDesign.elevated, in: RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
                .stroke(PhrasaDesign.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func contextParts(
        around range: Range<String.Index>
    ) -> (before: String, match: String, after: String) {
        let beforeStart = text.index(range.lowerBound, offsetBy: -48, limitedBy: text.startIndex)
            ?? text.startIndex
        let afterEnd = text.index(range.upperBound, offsetBy: 48, limitedBy: text.endIndex)
            ?? text.endIndex
        let beforePrefix = beforeStart == text.startIndex ? "" : "…"
        let afterSuffix = afterEnd == text.endIndex ? "" : "…"
        return (
            beforePrefix + text[beforeStart..<range.lowerBound],
            String(text[range]),
            text[range.upperBound..<afterEnd] + afterSuffix
        )
    }
}
