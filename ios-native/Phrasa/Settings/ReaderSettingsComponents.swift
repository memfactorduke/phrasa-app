import SwiftUI

struct ReaderSettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    init(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(PhrasaDesign.muted)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .background(PhrasaDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius, style: .continuous)
                    .stroke(PhrasaDesign.border, lineWidth: 1)
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(PhrasaDesign.muted)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ReaderSettingsSlider: View {
    let title: String
    let valueText: String
    let accessibilityValue: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(PhrasaDesign.ink)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PhrasaDesign.muted)
            }

            Slider(value: $value, in: range, step: step)
                .tint(PhrasaDesign.ember)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue)
        }
        .padding(16)
    }
}

struct ReaderThemeTile: View {
    let theme: ReaderTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index == 0 ? theme.readerAccent : theme.foreground.opacity(0.72))
                            .frame(width: index == 0 ? 27 : 18, height: 4)
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.readerAccent)
                    }
                }

                Text(theme.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PhrasaDesign.cardRadius)
                    .stroke(isSelected ? PhrasaDesign.ink : PhrasaDesign.border, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(theme.label) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Applies this monochrome stage look to the prompter")
    }
}

struct ReaderFontTile: View {
    let readingFont: ReadingFont
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("Aa")
                    .font(readingFont.font(size: 22))
                    .frame(width: 36, alignment: .leading)
                Text(readingFont.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(PhrasaDesign.ember)
                }
            }
            .foregroundStyle(PhrasaDesign.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isSelected ? PhrasaDesign.surfaceSecondary : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: PhrasaDesign.controlRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(readingFont.label) font")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ReaderPresetChip: View {
    let preset: ReaderAppearancePreset
    let isSelected: Bool
    let apply: () -> Void
    let delete: (() -> Void)?

    var body: some View {
        Button(action: apply) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(preset.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? PhrasaDesign.ember : PhrasaDesign.ink)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(isSelected ? PhrasaDesign.ember.opacity(0.10) : PhrasaDesign.surfaceSecondary)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(isSelected ? PhrasaDesign.ember : PhrasaDesign.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) look")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Applies this appearance without changing playback settings")
        .contextMenu {
            if let delete {
                Button("Delete look", systemImage: "trash", role: .destructive, action: delete)
            }
        }
    }
}
