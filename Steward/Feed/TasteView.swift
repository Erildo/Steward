import SwiftUI
import StewardCore

/// The owner's taste file, readable and editable: everything the feed knows.
struct TasteView: View {
    @Environment(FeedModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        NavigationStack {
            List {
                ListSection(title: "Things you love",
                            placeholder: "Add something you love",
                            footer: "Shows, films, music, creators, sports, topics. Anything.",
                            items: model.taste.loves) { edit in model.update { edit(&$0.loves) } }
                ListSection(title: "Curious about",
                            placeholder: "Add something you're curious about",
                            footer: "Things you'd like to know more about.",
                            items: model.taste.curious) { edit in model.update { edit(&$0.curious) } }
                ListSection(title: "Your goals",
                            placeholder: "Add a goal",
                            footer: "Steward looks for a step toward each one.",
                            items: model.taste.goals) { edit in model.update { edit(&$0.goals) } }

                sharedSection
                savedSection
                reactionsSection

                Section {
                    Button("Delete Everything", role: .destructive) { confirmsDelete = true }
                } footer: {
                    Text("This is one file on your iPhone, backed up with it. Steward sends it to its model only to find your feed.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Your taste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete your taste, saved items and feed?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    model.deleteEverything()
                    dismiss()
                }
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private var sharedSection: some View {
        Section {
            if model.taste.shared.isEmpty {
                Label("In Safari, YouTube or any app, tap Share, then Steward.", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
            }
            ForEach(model.taste.shared) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).foregroundStyle(Palette.ink).lineLimit(2)
                    let detail = [item.feeling?.label, item.note.isEmpty ? nil : item.note].compactMap(\.self).joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(Palette.muted)
                    }
                }
            }
            .onDelete { offsets in model.update { $0.shared.remove(atOffsets: offsets) } }
        } header: {
            Text("Shared with Steward")
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if !model.taste.saved.isEmpty {
            Section("Saved") {
                ForEach(model.taste.saved) { card in
                    Link(destination: card.url) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title).foregroundStyle(Palette.ink).lineLimit(2)
                            Text(card.source).font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .onDelete { offsets in model.update { $0.saved.remove(atOffsets: offsets) } }
            }
        }
    }

    @ViewBuilder
    private var reactionsSection: some View {
        let reactions = model.taste.reactions
        if !reactions.isEmpty {
            Section {
                let more = reactions.count { $0.kind == .more }
                let less = reactions.count - more
                LabeledContent("More like this", value: "\(more)")
                LabeledContent("Not for me", value: "\(less)")
                Button("Clear Reactions") { model.update { $0.reactions.removeAll() } }
            } header: {
                Text("Reactions")
            } footer: {
                Text("Steward learns from these. Clearing them doesn't change anything else.")
            }
        }
    }
}

/// One editable list: rows you can delete, and a field that adds on Return.
private struct ListSection: View {
    let title: String
    let placeholder: String
    let footer: String
    let items: [String]
    let edit: ((inout [String]) -> Void) -> Void

    @State private var draft = ""

    var body: some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item).foregroundStyle(Palette.ink)
            }
            .onDelete { offsets in edit { $0.remove(atOffsets: offsets) } }
            TextField(placeholder, text: $draft)
                .submitLabel(.done)
                .onSubmit(add)
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !text.isEmpty, !items.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { return }
        edit { $0.append(text) }
    }
}
