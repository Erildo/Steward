import SwiftUI

/// One connection: who it's connected as, what Steward may do there, when it
/// last did, and a way out.
struct ConnectedAppDetail: View {
    let id: String

    @Environment(StewardTabModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDisconnect = false

    var body: some View {
        Group {
            if let app = model.app(id) {
                list(app)
            } else {
                ContentUnavailableView("Disconnected", systemImage: "link",
                                       description: Text("Steward can't reach this any more."))
            }
        }
        .background(Palette.ground)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func list(_ app: ConnectedApp) -> some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AppIcon(systemImage: app.systemImage, color: app.color, size: 60)
                    Text(app.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                    if let account = app.account {
                        Text(account)
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if app.needsSignIn {
                Section {
                    Button {
                        withAnimation { model.signedInAgain(app.id) }
                    } label: {
                        Label("Sign In Again", systemImage: "person.badge.key")
                            .foregroundStyle(Palette.orangeText)
                    }
                    .listRowBackground(Palette.row)
                } footer: {
                    Text("The website signed Steward out. You sign in yourself in a live view; Steward never sees your password.")
                }
            }

            Section {
                ForEach(app.abilities, id: \.self) { ability in
                    if ability == .send {
                        LabeledContent {
                            Text("With your yes")
                        } label: {
                            explained(ability, app)
                        }
                        .listRowBackground(Palette.row)
                    } else {
                        Toggle(isOn: Binding(
                            get: { model.app(id)?.allowed.contains(ability) ?? false },
                            set: { model.setAllowed(ability, $0, for: id) }
                        )) {
                            explained(ability, app)
                        }
                        .tint(Palette.orange)
                        .listRowBackground(Palette.row)
                    }
                }
            } header: {
                header("Steward may")
            }

            if let used = app.lastUsed {
                Section {
                    LabeledContent("Last used", value: used.formatted(.relative(presentation: .named)))
                        .listRowBackground(Palette.row)
                    if let task = app.lastUsedFor {
                        LabeledContent("For", value: task)
                            .listRowBackground(Palette.row)
                    }
                }
            }

            Section {
                Button(role: .destructive) { confirmsDisconnect = true } label: {
                    Text("Disconnect \(app.kind == .website ? "Website" : app.name)")
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Palette.row)
                .confirmationDialog("Disconnect \(app.name)?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        dismiss()
                        model.disconnect(app.id)
                    }
                } message: {
                    Text("Steward stops reaching \(app.name). Tasks that use it will ask you instead. Files it already saved stay in Files.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func explained(_ ability: ConnectedApp.Ability, _ app: ConnectedApp) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ability.title).foregroundStyle(Palette.ink)
            if let text = app.explains[ability] {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 2)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .textCase(nil)
            .padding(.leading, -4)
    }
}

/// What the owner could connect next. Websites aren't here: they connect the
/// first time an errand needs them and the owner signs in.
struct ConnectAppSheet: View {
    @Environment(StewardTabModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.available.isEmpty {
                        Text("Everything on this iPhone is connected.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                            .listRowBackground(Palette.row)
                    }
                    ForEach(model.available) { app in
                        HStack(spacing: 12) {
                            AppIcon(systemImage: app.systemImage, color: app.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).foregroundStyle(Palette.ink)
                                if let first = app.abilities.first, let text = app.explains[first] {
                                    Text(text)
                                        .font(.footnote)
                                        .foregroundStyle(Palette.muted)
                                }
                            }
                            Spacer(minLength: 8)
                            Button("Connect") {
                                withAnimation { model.connect(app) }
                            }
                            .buttonStyle(.bordered)
                            .tint(Palette.orangeText)
                            .accessibilityLabel("Connect \(app.name)")
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Palette.row)
                    }
                } footer: {
                    Text("Steward starts by reading only. You choose what else it may do, app by app. Websites connect when an errand needs one and you sign in.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Connect an App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(Palette.ink)
        }
    }
}
