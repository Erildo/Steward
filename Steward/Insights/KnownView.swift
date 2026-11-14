import SwiftUI

/// Everything Steward knows about the owner, in plain words: what they told
/// it, what it guessed and from where, and the parts of life it leaves alone.
/// Nothing it has worked out is kept from them.
struct KnownView: View {
    @Environment(InsightsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    if model.facts.isEmpty {
                        empty("Nothing yet. What you tell Steward about yourself shows up here.")
                    }
                    ForEach(model.facts) { row($0) }
                } header: {
                    header("You told Steward")
                }

                Section {
                    if model.guesses.isEmpty {
                        empty("No guesses yet. Steward needs about a week of chats and tasks.")
                    }
                    ForEach(model.guesses) { row($0) }
                } header: {
                    header("Steward's guesses")
                } footer: {
                    Text("Guesses come from patterns in your chats, tasks and Feed. Forget one and Steward stops using it.")
                }

                Section {
                    ForEach($model.topics) { $topic in
                        Toggle(isOn: $topic.allowed) {
                            Label(topic.name, systemImage: topic.systemImage)
                                .foregroundStyle(Palette.ink)
                        }
                        .tint(Palette.orange)
                        .listRowBackground(Palette.row)
                    }
                } header: {
                    header("What Steward may notice")
                } footer: {
                    Text("Steward notices; it never diagnoses. Topics that are off are never used for insights, even when they come up in a chat.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("What Steward Knows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: model.exportText) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(Palette.ink)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .textCase(nil)
            .padding(.leading, -4)
    }

    private func row(_ item: Known) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.text)
                .font(.body)
                .foregroundStyle(Palette.ink)
            Text(item.source)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 2)
        .listRowBackground(Palette.row)
        .accessibilityElement(children: .combine)
        .swipeActions {
            Button("Forget", systemImage: "trash", role: .destructive) {
                withAnimation { model.forget(item) }
            }
        }
        .contextMenu {
            Button("Forget", systemImage: "trash", role: .destructive) {
                withAnimation { model.forget(item) }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.muted)
            .listRowBackground(Palette.row)
    }
}
