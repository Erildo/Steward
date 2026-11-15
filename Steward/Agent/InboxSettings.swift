import Foundation
import StewardCore

/// The owner's own inbox, checked at each check-in for replies that went
/// there instead of the case's address (docs/adr/0003). Optional. The address
/// and server are settings; the app password lives in the Keychain and goes
/// only to the owner's mail server, never to a model.
nonisolated enum InboxSettings {
    struct Account: Codable, Equatable {
        var address: String
        var server: InboxServer
    }

    static let accountKey = "inboxAccount"
    static let cursorKey = "inboxCursor"
    static let lastCheckKey = "inboxLastCheck"
    static let problemKey = "inboxProblem"
    static let password = KeychainSlot(service: "com.steward.inbox", account: "appPassword")

    static var account: Account? {
        UserDefaults.standard.data(forKey: accountKey).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
    }

    /// The check for this phone's inbox, or `nil` when none is connected.
    static func check() -> InboxCheck? {
        guard let account, let data = password.read(), let secret = String(data: data, encoding: .utf8) else { return nil }
        return check(account, password: secret)
    }

    static func check(_ account: Account, password: String) -> InboxCheck {
        InboxCheck(server: account.server, address: account.address, password: password) { host, port in
            try await IMAPTLSTransport.connect(host: host, port: port)
        }
    }

    /// Which approved emails already went out, so a retry never sends twice.
    static let ledger = SendLedger(url: URL.applicationSupportDirectory.appending(path: "Steward/sent-emails.json"))

    /// Sends approved emails from the owner's own address, or `nil` when no
    /// mailbox is connected.
    static func mailer() -> OwnerMailer? {
        guard let account, let data = password.read(), let secret = String(data: data, encoding: .utf8) else { return nil }
        return mailer(account, password: secret)
    }

    static func mailer(_ account: Account, password: String) -> OwnerMailer {
        OwnerMailer(server: account.server.sending(for: account.address), address: account.address, password: password, ledger: ledger) { server in
            try await SMTPStreamTransport.connect(server)
        }
    }

    static var isConnected: Bool { account != nil && password.read() != nil }

    /// App passwords never contain spaces; providers show them in groups.
    static func cleaned(_ password: String) -> String {
        password.filter { !$0.isWhitespace }
    }

    static func save(_ account: Account, password secret: String) throws {
        try password.write(Data(secret.utf8))
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: accountKey)
        // A new inbox starts from its newest mail.
        UserDefaults.standard.removeObject(forKey: cursorKey)
        UserDefaults.standard.removeObject(forKey: problemKey)
    }

    static func remove() {
        password.delete()
        for key in [accountKey, cursorKey, lastCheckKey, problemKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    static var cursor: InboxCursor {
        get { UserDefaults.standard.data(forKey: cursorKey).flatMap { try? JSONDecoder().decode(InboxCursor.self, from: $0) } ?? InboxCursor() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: cursorKey) }
    }

    static func recordSuccess() {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastCheckKey)
        UserDefaults.standard.removeObject(forKey: problemKey)
    }

    static func recordProblem(_ message: String) {
        UserDefaults.standard.set(message, forKey: problemKey)
    }

    /// Runs `work`, giving up after `seconds` even if `work` is stuck on the
    /// network: a background check-in only gets a short moment.
    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withDeadline(seconds, timeoutError: { IMAPError(.timeout, "The mail server took too long to answer.") }, work)
    }
}
