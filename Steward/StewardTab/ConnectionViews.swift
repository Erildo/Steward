import SwiftUI
import StewardCore

/// The owner's own AI key: optional, never required. With it, Steward talks to
/// the owner's provider directly and nothing passes through Steward's relay.
struct OwnAIKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var model = ""
    @State private var address = ModelAccess.openRouter.absoluteString
    @State private var hasKey = ModelAccess.hasOwnKey
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                SecureField("Key", text: $key)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model name", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Provider address", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Any provider that speaks the OpenAI format works. OpenRouter is filled in, and its model names look like \"provider/model\".")
            }
            .listRowBackground(Palette.row)

            Section {
                Button("Use This Key") { save() }
                    .disabled(key.isEmpty || model.isEmpty || RelaySettings.validURL(address) == nil)
                if hasKey {
                    Button("Remove My Key", role: .destructive) {
                        ModelAccess.removeOwnKey()
                        hasKey = false
                    }
                }
            } footer: {
                Text(hasKey
                     ? "Steward is using your key. It stays in this iPhone's Keychain and goes only to your provider. Errands switch to it the next time Steward opens."
                     : "Your key stays in this iPhone's Keychain and goes only to your provider, never through Steward. Without one, Steward's AI is used.")
            }
            .listRowBackground(Palette.row)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Your Own AI Key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let own = ModelAccess.ownKey() {
                model = own.model
                address = own.baseURL.absoluteString
            }
        }
        .alert("Couldn't save the key", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func save() {
        guard let url = RelaySettings.validURL(address) else { return }
        do {
            try ModelAccess.saveOwnKey(.init(key: key.trimmingCharacters(in: .whitespacesAndNewlines), model: model.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: url))
            key = ""
            hasKey = true
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Which relay carries errand mail and wake-ups: Steward's, the owner's own
/// copy of the open-source relay, or none. Steward never depends on one
/// server staying up (docs/adr/0003).
struct RelayChoiceView: View {
    @AppStorage(RelaySettings.choiceKey) private var choice = RelayChoice.steward
    @AppStorage(RelaySettings.ownURLKey) private var ownURL = ""
    @State private var invite = ""
    @State private var savedInvite = RelaySettings.ownInvite.read() != nil

    var body: some View {
        Form {
            Section {
                Picker("Relay", selection: $choice) {
                    ForEach(RelayChoice.allCases) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(Self.summary(option))
                                .font(.footnote)
                                .foregroundStyle(Palette.muted)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("The relay gives each errand its own email address, holds replies sealed so only this iPhone can open them, and wakes Steward when they arrive. It can't read your errands. Changes apply the next time Steward opens.")
            }
            .listRowBackground(Palette.row)

            if choice == .own {
                Section {
                    TextField("Relay address", text: $ownURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(savedInvite ? "Invite code saved" : "Invite code, if it has one", text: $invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveInvite)
                    if !invite.isEmpty {
                        Button("Save Invite Code", action: saveInvite)
                    }
                } header: {
                    Text("Your relay")
                } footer: {
                    if !ownURL.isEmpty && RelaySettings.validURL(ownURL) == nil {
                        Text("That doesn't look like a web address. It should start with https://.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Run the relay from Steward's open-source code on your own account. Its mail never touches Steward. Your own relay can't send Steward's pushes, so follow-up reminders come from this iPhone, and replies are collected when you open Steward.")
                    }
                }
                .listRowBackground(Palette.row)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Relay")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One line on what each choice means for the owner.
    static func summary(_ option: RelayChoice) -> String {
        switch option {
        case .steward:
            RelaySettings.production == nil ? "Nothing to set up. Not running yet." : "Nothing to set up."
        case .own:
            "A copy of the relay that you run."
        case .none:
            "Chat, tasks and the feed still work. Email errands wait for a relay."
        }
    }

    private func saveInvite() {
        let trimmed = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? RelaySettings.ownInvite.write(Data(trimmed.utf8))
        invite = ""
        savedInvite = true
    }
}

/// Connects the owner's own inbox with an app password, so a company's reply
/// that went there still reaches its errand (docs/adr/0003).
struct InboxSettingsView: View {
    @State private var account = InboxSettings.account
    @State private var address = ""
    @State private var host = ""
    @State private var appPassword = ""
    @State private var working = false
    @State private var problem: String?
    @AppStorage(InboxSettings.lastCheckKey) private var lastCheck = 0.0
    @AppStorage(InboxSettings.problemKey) private var lastProblem = ""

    var body: some View {
        Form {
            if let account {
                connected(account)
            } else {
                connect
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Your Inbox")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Connected

    private func connected(_ account: InboxSettings.Account) -> some View {
        Group {
            Section {
                LabeledContent("Address", value: account.address)
                LabeledContent("Provider", value: account.server.provider)
                LabeledContent("Last checked") {
                    Text(lastCheck > 0 ? Date(timeIntervalSince1970: lastCheck).formatted(.relative(presentation: .named)) : "Not yet")
                }
                if !lastProblem.isEmpty {
                    Label(lastProblem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Palette.orangeText)
                }
            } footer: {
                Text("At each check-in, Steward looks only for new mail from companies you have an open errand with, and reads only those emails. It never marks anything as read.")
            }
            .listRowBackground(Palette.row)

            Section {
                Button(working ? "Checking…" : "Check Connection") { Task { await test(account) } }
                    .disabled(working)
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
                Button("Disconnect Inbox", role: .destructive) {
                    InboxSettings.remove()
                    self.account = nil
                }
            } footer: {
                Text("Disconnecting deletes the app password from this iPhone. To cut access completely, also revoke it at \(account.server.provider).")
            }
            .listRowBackground(Palette.row)
        }
    }

    private func test(_ account: InboxSettings.Account) async {
        guard let data = InboxSettings.password.read(), let secret = String(data: data, encoding: .utf8) else { return }
        working = true
        defer { working = false }
        do {
            try await InboxSettings.withTimeout(20) { try await InboxSettings.check(account, password: secret).test() }
            problem = nil
            lastProblem = ""
        } catch {
            problem = message(error)
        }
    }

    // MARK: Not connected

    private var known: InboxServer? { InboxServer.known(for: address) }

    private var server: InboxServer? {
        if let known { return known }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(".") && !trimmed.contains(" ") ? InboxServer(host: trimmed, provider: trimmed) : nil
    }

    private var connect: some View {
        Group {
            Section {
                TextField("Email address", text: $address)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if address.contains("@"), known == nil, !InboxServer.needsOAuth(address) {
                    TextField("Mail server, such as imap.example.com", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                SecureField("App password", text: $appPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                if InboxServer.needsOAuth(address) {
                    Text("Outlook, Hotmail and Live only allow sign-in through Microsoft, which Steward doesn't support yet.")
                } else if let known {
                    Text("\(known.provider) needs an app password: a separate password just for Steward, which you can revoke any time. It's not your normal password.")
                } else {
                    Text("Use an app password from your mail provider, not your normal password. Steward connects securely on port 993.")
                }
            }
            .listRowBackground(Palette.row)

            if let url = known?.appPasswordURL {
                Section {
                    Link(destination: url) {
                        Label("Make an App Password at \(known?.provider ?? "your provider")", systemImage: "arrow.up.forward")
                    }
                }
                .listRowBackground(Palette.row)
            }

            Section {
                Button(working ? "Connecting…" : "Connect Inbox") { Task { await connectInbox() } }
                    .disabled(working || server == nil || appPassword.isEmpty || InboxServer.needsOAuth(address))
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            } footer: {
                Text("The app password stays in this iPhone's Keychain and goes only to your mail server. The AI never sees it. Steward reads only replies from companies you have an open errand with.")
            }
            .listRowBackground(Palette.row)
        }
    }

    private func connectInbox() async {
        guard let server else { return }
        let account = InboxSettings.Account(address: address.trimmingCharacters(in: .whitespaces).lowercased(), server: server)
        let secret = InboxSettings.cleaned(appPassword)
        working = true
        defer { working = false }
        do {
            try await InboxSettings.withTimeout(20) { try await InboxSettings.check(account, password: secret).test() }
            try InboxSettings.save(account, password: secret)
            appPassword = ""
            problem = nil
            self.account = account
        } catch {
            problem = message(error)
        }
    }

    private func message(_ error: any Error) -> String {
        (error as? IMAPError)?.message ?? "Steward couldn't reach that mail server."
    }
}
