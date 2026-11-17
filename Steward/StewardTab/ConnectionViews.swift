import SwiftUI
import StewardCore

/// The owner's own AI key. Steward talks to the owner's provider directly,
/// with nothing in between. Errands need it until Steward has an AI of its own.
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Any provider that speaks the OpenAI format works. OpenRouter is filled in, and its model names look like \"provider/model\".")
                    if let url = RelaySettings.validURL(address), !ModelAccess.searchesWeb(url) {
                        Text("Only OpenRouter lets Steward search the web. With this provider the Feed works from what the model already knows, so its finds may be dated.")
                    } else {
                        Text("Free models work for chat. Searching the web for the Feed costs under a cent a search, even with a free model, so keep a little credit on OpenRouter.")
                    }
                }
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
                     ? "Steward is using your key. It stays in this iPhone's Keychain and goes only to your provider."
                     : "Your key stays in this iPhone's Keychain and goes only to your provider, never through Steward. Errands, the feed and the daily review need one for now.")
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

/// Connects the owner's own mailbox with an app password. Errands send from
/// it, and a company's replies are read from it at check-ins (docs/adr/0003).
struct InboxSettingsView: View {
    @State private var account = InboxSettings.account
    @State private var address = ""
    @State private var host = ""
    @State private var smtpHost = ""
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
        .navigationTitle("Your Mailbox")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Connected

    private func connected(_ account: InboxSettings.Account) -> some View {
        Group {
            Section {
                LabeledContent("Address", value: account.address)
                LabeledContent("Provider", value: account.server.provider)
                LabeledContent("Sends through", value: account.server.sending(for: account.address).host)
                LabeledContent("Last checked") {
                    Text(lastCheck > 0 ? Date(timeIntervalSince1970: lastCheck).formatted(.relative(presentation: .named)) : "Not yet")
                }
                if !lastProblem.isEmpty {
                    Label(lastProblem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Palette.orangeText)
                }
            } footer: {
                Text("Errands send from this address, only after you approve each email, and your provider keeps a copy in Sent. At each check-in, Steward looks only for new mail from companies you have an open errand with, and reads only those emails. It never marks anything as read.")
            }
            .listRowBackground(Palette.row)

            Section {
                Button(working ? "Checking…" : "Check Connection") { Task { await test(account) } }
                    .disabled(working)
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
                Button("Disconnect Mailbox", role: .destructive) {
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
            try await Self.testBoth(account, password: secret)
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
        guard trimmed.contains("."), !trimmed.contains(" ") else { return nil }
        var custom = InboxServer(host: trimmed, provider: trimmed)
        custom.smtp = InboxServer.sendingServer(typed: smtpHost)
        return custom
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
                    TextField("Incoming server, such as imap.example.com", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Outgoing server, such as smtp.example.com:587", text: $smtpHost)
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
                    Text("\(known.provider) needs an app password: a separate password just for Steward, which you can revoke any time. It's not your normal password.\(known.provider == "Gmail" ? " Gmail only offers app passwords once 2-Step Verification is on." : "")")
                } else {
                    Text("Use an app password from your mail provider, not your normal password. Steward reads securely on port 993. For sending, add :587 to the outgoing server if your provider uses that port; otherwise Steward uses 465.")
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
                Button(working ? "Connecting…" : "Connect Mailbox") { Task { await connectInbox() } }
                    .disabled(working || server == nil || appPassword.isEmpty || InboxServer.needsOAuth(address))
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            } footer: {
                Text("The app password stays in this iPhone's Keychain and goes only to your mail server. The AI never sees it. Steward sends only emails you approve, and reads only replies from companies you have an open errand with.")
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
            try await Self.testBoth(account, password: secret)
            try InboxSettings.save(account, password: secret)
            appPassword = ""
            problem = nil
            self.account = account
        } catch {
            problem = message(error)
        }
    }

    /// Logs in to both servers: reading replies and sending approved emails.
    private static func testBoth(_ account: InboxSettings.Account, password: String) async throws {
        try await InboxSettings.withTimeout(20) { try await InboxSettings.check(account, password: password).test() }
        do {
            // Longer than one read's own deadline, so a slow server shows up as a sending problem.
            try await withDeadline(50, timeoutError: { SMTPError(.timeout, "The outgoing server took too long to answer.") }) {
                try await InboxSettings.mailer(account, password: password).test()
            }
        } catch let error as SMTPError {
            throw SMTPError(error.kind, "Reading works, but sending didn't: \(error.message)")
        }
    }

    private func message(_ error: any Error) -> String {
        (error as? IMAPError)?.message ?? (error as? SMTPError)?.message ?? "Steward couldn't reach that mail server."
    }
}
