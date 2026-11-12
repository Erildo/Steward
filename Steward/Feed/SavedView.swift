import SwiftUI
import StewardCore

/// Finds the owner kept. They outlive each day's batch.
struct SavedView: View {
    @Environment(FeedModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.taste.saved.isEmpty {
                    ContentUnavailableView(
                        "Nothing Saved Yet",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark on a find to keep it here after today's finds are gone.")
                    )
                } else {
                    List {
                        ForEach(model.taste.saved) { card in
                            Link(destination: card.url) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                                    Text("\(Text(card.source).fontWeight(.semibold)) · \(card.topic)")
                                        .font(.footnote)
                                        .foregroundStyle(Palette.muted)
                                }
                                .padding(.vertical, 2)
                            }
                            .accessibilityHint("Opens in Safari")
                        }
                        .onDelete { offsets in model.update { $0.saved.remove(atOffsets: offsets) } }
                        .listRowBackground(Palette.row)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Palette.ground)
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
