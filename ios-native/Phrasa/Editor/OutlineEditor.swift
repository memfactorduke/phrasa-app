import SwiftUI

struct OutlineEditor: View {
    @Binding var points: [OutlinePoint]

    var body: some View {
        List {
            if points.isEmpty {
                ContentUnavailableView(
                    "No talking points",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Add a point to present without reading word-for-word.")
                )
                .foregroundStyle(PhrasaDesign.muted)
                .listRowBackground(Color.clear)
            }
            ForEach($points) { $point in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Talking point", text: $point.text, axis: .vertical)
                        .font(.headline)
                        .foregroundStyle(PhrasaDesign.ink)
                    TextField("Note (optional)", text: $point.note, axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(PhrasaDesign.muted)
                }
                .padding(.vertical, 8)
                .listRowBackground(PhrasaDesign.elevated)
            }
            .onDelete { points.remove(atOffsets: $0) }
            .onMove { points.move(fromOffsets: $0, toOffset: $1) }

            Button {
                points.append(OutlinePoint())
            } label: {
                Label("Add point", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(minHeight: PhrasaDesign.minTouchTarget)
            }
            .listRowBackground(Color.clear)
            .foregroundStyle(PhrasaDesign.ink)
        }
        .scrollContentBackground(.hidden)
        .background(PhrasaDesign.canvas)
        .toolbar { EditButton() }
    }
}
