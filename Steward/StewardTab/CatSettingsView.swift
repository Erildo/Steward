import SwiftUI

/// The owner's cat: a coat, a name, and a look at how it reacts. The name
/// shows in Chat's pill; Steward stays the app's name everywhere else.
struct CatSettingsView: View {
    @AppStorage(CatLook.coatKey, store: CatLook.store) private var coat = CatCoat.ginger
    @AppStorage(CatLook.nameKey, store: CatLook.store) private var name = ""
    @State private var shown: CatMood = .idle

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    StewardAvatar(size: 112, mood: shown)
                    Text(displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(shown.title)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)

            Section {
                TextField("Steward", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onChange(of: name) { _, new in
                        if new.count > 14 { name = String(new.prefix(14)) }
                    }
            } header: {
                Text("Name")
            } footer: {
                Text("Shows at the top of Chat, like \"\(name.isEmpty ? "Miso" : displayName) · Thinking\". Leave it blank to keep Steward.")
            }
            .listRowBackground(Palette.row)

            Section {
                HStack(spacing: 0) {
                    ForEach(CatCoat.allCases) { option in
                        Button { coat = option } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(option.fur)
                                    .frame(width: 40, height: 40)
                                    .overlay {
                                        Circle().strokeBorder(Palette.ink.opacity(0.15), lineWidth: 0.5)
                                    }
                                    .padding(3)
                                    .overlay {
                                        if option == coat {
                                            Circle().strokeBorder(Palette.ink, lineWidth: 2)
                                        }
                                    }
                                Text(option.title)
                                    .font(.footnote)
                                    .foregroundStyle(option == coat ? Palette.ink : Palette.muted)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.title) coat")
                        .accessibilityAddTraits(option == coat ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Coat")
            }
            .listRowBackground(Palette.row)

            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(CatMood.allCases) { mood in
                        Button { shown = mood } label: {
                            VStack(spacing: 6) {
                                StewardAvatar(size: 44, blinks: false, mood: mood)
                                Text(mood.title)
                                    .font(.caption)
                                    .foregroundStyle(mood == shown ? Palette.ink : Palette.muted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.vertical, 6)
                            .background(mood == shown ? Palette.ground : .clear, in: .rect(cornerRadius: 12))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mood.title)
                        .accessibilityAddTraits(mood == shown ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("How it reacts")
            } footer: {
                Text("The cat only shows what Steward is really doing: thinking on your message, working on an errand, waiting on a company, or stuck. It sleeps during your Quiet Hours.")
            }
            .listRowBackground(Palette.row)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Your Cat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Steward" : trimmed
    }
}
