import Foundation

/// The owner's mail server for inbox check-ins. Microsoft's consumer mail
/// (Outlook.com, Hotmail, Live) only takes OAuth for IMAP, so it isn't offered.
public struct InboxServer: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    /// The provider whose app-password page the owner is sent to.
    public var provider: String
    /// The provider's receiving server, as it names itself at the top of
    /// Authentication-Results. Only that header's DKIM verdict counts; `nil`
    /// when unknown, and then no inbox mail counts as signed.
    public var trustedAuthservID: String?
    /// Where the owner makes an app password.
    public var appPasswordURL: URL?
    /// The provider's sending server, which takes the same app password.
    /// `nil` in settings saved before Steward sent mail itself: `sending` fills it in.
    public var smtp: SMTPServer?

    public init(host: String, port: UInt16 = 993, provider: String, trustedAuthservID: String? = nil, appPasswordURL: URL? = nil, smtp: SMTPServer? = nil) {
        self.host = host
        self.port = port
        self.provider = provider
        self.trustedAuthservID = trustedAuthservID
        self.appPasswordURL = appPasswordURL
        self.smtp = smtp
    }

    /// Where approved emails go out: the saved server, the known one for the
    /// address, or the IMAP host's "smtp." twin on port 465.
    public func sending(for address: String) -> SMTPServer {
        if let smtp { return smtp }
        if let known = Self.known(for: address)?.smtp ?? Self.knownSending(forIncoming: host) { return known }
        let base = host.lowercased().hasPrefix("imap.") ? String(host.dropFirst(5)) : host
        return SMTPServer(host: "smtp." + base)
    }

    /// A well-known provider's sending server, from its incoming one, for an
    /// address on the owner's own domain (iCloud custom domains, say).
    public static func knownSending(forIncoming host: String) -> SMTPServer? {
        switch host.lowercased() {
        case "imap.gmail.com": SMTPServer(host: "smtp.gmail.com")
        case "imap.mail.me.com": SMTPServer(host: "smtp.mail.me.com", port: 587, startTLS: true)
        case "imap.mail.yahoo.com": SMTPServer(host: "smtp.mail.yahoo.com")
        case "imap.aol.com": SMTPServer(host: "smtp.aol.com")
        case "imap.fastmail.com": SMTPServer(host: "smtp.fastmail.com")
        case "imap.gmx.net": SMTPServer(host: "mail.gmx.net")
        case "outlook.office365.com": SMTPServer(host: "smtp.office365.com", port: 587, startTLS: true)
        default: nil
        }
    }

    /// An outgoing server as the owner typed it: "smtp.example.com" (TLS on
    /// 465) or "smtp.example.com:587" (STARTTLS). `nil` if it isn't one.
    public static func sendingServer(typed text: String) -> SMTPServer? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = parts.first.map(String.init), host.contains("."), !host.contains(" "), parts.count <= 2 else { return nil }
        guard parts.count == 2 else { return SMTPServer(host: host) }
        guard let port = UInt16(parts[1]) else { return nil }
        return SMTPServer(host: host, port: port, startTLS: port != 465)
    }

    /// The server for a well-known address, or `nil` to ask the owner.
    public static func known(for address: String) -> InboxServer? {
        guard let domain = address.split(separator: "@").last?.lowercased(), address.contains("@") else { return nil }
        switch domain {
        case "gmail.com", "googlemail.com":
            return InboxServer(host: "imap.gmail.com", provider: "Gmail", trustedAuthservID: "mx.google.com",
                               appPasswordURL: URL(string: "https://myaccount.google.com/apppasswords"),
                               smtp: SMTPServer(host: "smtp.gmail.com"))
        case "icloud.com", "me.com", "mac.com":
            return InboxServer(host: "imap.mail.me.com", provider: "iCloud Mail", appPasswordURL: URL(string: "https://account.apple.com"),
                               smtp: SMTPServer(host: "smtp.mail.me.com", port: 587, startTLS: true))
        case let d where d.hasPrefix("yahoo.") || d == "ymail.com":
            return InboxServer(host: "imap.mail.yahoo.com", provider: "Yahoo Mail", appPasswordURL: URL(string: "https://login.yahoo.com/account/security"),
                               smtp: SMTPServer(host: "smtp.mail.yahoo.com"))
        case "aol.com":
            return InboxServer(host: "imap.aol.com", provider: "AOL Mail", appPasswordURL: URL(string: "https://login.aol.com/account/security"),
                               smtp: SMTPServer(host: "smtp.aol.com"))
        case "fastmail.com", "fastmail.fm":
            return InboxServer(host: "imap.fastmail.com", provider: "Fastmail", appPasswordURL: URL(string: "https://app.fastmail.com/settings/security/apps"),
                               smtp: SMTPServer(host: "smtp.fastmail.com"))
        case "gmx.com", "gmx.net", "gmx.de":
            return InboxServer(host: "imap.gmx.net", provider: "GMX", smtp: SMTPServer(host: domain == "gmx.com" ? "mail.gmx.com" : "mail.gmx.net"))
        default:
            return nil
        }
    }

    /// Addresses whose provider only allows OAuth for IMAP.
    public static func needsOAuth(_ address: String) -> Bool {
        guard let domain = address.split(separator: "@").last?.lowercased() else { return false }
        return ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains(domain)
            || domain.hasPrefix("outlook.") || domain.hasPrefix("hotmail.")
    }
}

/// How far the inbox has been read, so each check-in only looks at new mail.
public struct InboxCursor: Codable, Sendable, Equatable {
    public var uidValidity: UInt32?
    public var lastUID: UInt32

    public init(uidValidity: UInt32? = nil, lastUID: UInt32 = 0) {
        self.uidValidity = uidValidity
        self.lastUID = lastUID
    }
}

/// One company reply found in the owner's inbox, for one case.
public struct InboxDelivery: Sendable, Equatable {
    public var caseID: UUID
    public var email: CaseFile.Email
}

/// One check-in against the owner's inbox. It looks only at new mail from the
/// domains of open errands that have sent something, since the first send,
/// and fetches only those messages (read-only). With no such errand it
/// doesn't connect at all.
public struct InboxCheck: Sendable {
    public typealias Connect = @Sendable (_ host: String, _ port: UInt16) async throws -> any IMAPTransport

    public var server: InboxServer
    public var address: String
    public var password: String
    public var connect: Connect
    /// The most of one message fetched; enough for any reply's text.
    public var maxBytes = 512 * 1024

    public init(server: InboxServer, address: String, password: String, connect: @escaping Connect) {
        self.server = server
        self.address = address
        self.password = password
        self.connect = connect
    }

    /// Logs in and out again: checks the address and app password work.
    public func test() async throws {
        let session = IMAPSession(transport: try await connect(server.host, server.port))
        do {
            try await session.greeting()
            try await session.login(user: address, password: password)
            _ = try await session.examineInbox()
        } catch {
            await session.logout()
            throw error
        }
        await session.logout()
    }

    public func run(cases: [CaseFile], cursor: InboxCursor) async throws -> (deliveries: [InboxDelivery], cursor: InboxCursor) {
        let open = cases.filter { $0.state != .closed && $0.emails.contains { $0.direction == .outgoing } && Self.isPlainDomain($0.company.domain) }
        guard !open.isEmpty else { return ([], cursor) }

        let session = IMAPSession(transport: try await connect(server.host, server.port))
        do {
            let result = try await read(open, cursor: cursor, session: session)
            await session.logout()
            return result
        } catch {
            await session.logout()
            throw error
        }
    }

    private func read(_ open: [CaseFile], cursor: InboxCursor, session: IMAPSession) async throws -> ([InboxDelivery], InboxCursor) {
        try await session.greeting()
        try await session.login(user: address, password: password)
        let (validity, uidNext) = try await session.examineInbox()
        // A new UIDVALIDITY means old numbers mean nothing: start over, and
        // let the "since" date and duplicate check keep it to new replies.
        var last = validity != nil && validity == cursor.uidValidity ? cursor.lastUID : 0
        var deliveries: [InboxDelivery] = []
        var seen = Set<UInt32>()

        let byDomain = Dictionary(grouping: open) { $0.company.domain.lowercased() }
        for (domain, files) in byDomain.sorted(by: { $0.key < $1.key }) {
            let firstSend = files.flatMap(\.emails).filter { $0.direction == .outgoing }.map(\.date).min() ?? .now
            let since = Self.imapDate(firstSend.addingTimeInterval(-24 * 3600))
            let criteria = "UID \(last + 1):* SINCE \(since) FROM \"\(domain)\""
            // "n:*" always includes the newest message, even if older than n.
            for uid in try await session.search(criteria).sorted() where uid > last && !seen.contains(uid) {
                seen.insert(uid)
                guard let raw = try await session.fetch(uid: uid, maxBytes: maxBytes) else { continue }
                if let delivery = Self.delivery(raw: raw, to: files, server: server, owner: address) {
                    deliveries.append(delivery)
                }
            }
        }
        if let uidNext, uidNext > 0 { last = max(last, uidNext - 1) }
        if let newest = seen.max() { last = max(last, newest) }
        return (deliveries, InboxCursor(uidValidity: validity, lastUID: last))
    }

    // MARK: Matching

    /// The case a message belongs to, or `nil` when it isn't from the
    /// company's domain or the case already has it.
    static func delivery(raw: Data, to files: [CaseFile], server: InboxServer, owner: String) -> InboxDelivery? {
        let message = MIMEMessage(raw)
        guard let from = message.fromAddress, let fromDomain = from.split(separator: "@").last.map(String.init) else { return nil }
        let candidates = files.filter { fromDomain == $0.company.domain.lowercased() || fromDomain.hasSuffix("." + $0.company.domain.lowercased()) }
        guard !candidates.isEmpty else { return nil }
        let subject = message.subject
        // A reply's subject names the case's own email; otherwise the newest case.
        let file = candidates.first { file in
            file.emails.contains { $0.direction == .outgoing && !$0.subject.isEmpty && subject.localizedCaseInsensitiveContains($0.subject) }
        } ?? candidates.max { $0.createdAt < $1.createdAt }!
        let email = CaseFile.Email(
            direction: .incoming,
            date: message.date ?? .now,
            from: from,
            to: owner,
            subject: subject,
            body: message.text,
            dkimPass: server.trustedAuthservID.map { dkimPass(raw: raw, trustedAuthservID: $0) } ?? []
        )
        let known = (file.emails + file.inbox).contains {
            $0.direction == .incoming && $0.from.lowercased() == from && $0.subject == subject && abs($0.date.timeIntervalSince(email.date)) < 120
        }
        return known ? nil : InboxDelivery(caseID: file.id, email: email)
    }

    /// Domains whose DKIM signature passed, from the topmost
    /// Authentication-Results header, and only if the owner's own provider
    /// wrote it. Mirrors `dkimVerdict` in relay/src/dkim.ts.
    static func dkimPass(raw: Data, trustedAuthservID: String) -> [String] {
        let message = MIMEMessage(raw)
        guard let header = message.header("Authentication-Results") else { return [] }
        var value = ""
        var depth = 0
        for character in header {
            if character == "(" { depth += 1 } else if character == ")", depth > 0 { depth -= 1 } else if depth == 0 { value.append(character) }
        }
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let id = parts.first?.split(separator: " ").first?.lowercased(), id == trustedAuthservID.lowercased() else { return [] }
        var pass = Set<String>()
        for result in parts.dropFirst() {
            let lower = result.lowercased()
            guard lower.hasPrefix("dkim=pass") || lower.hasPrefix("dkim = pass") else { continue }
            for token in lower.split(whereSeparator: { $0 == " " || $0 == "\t" }) where token.hasPrefix("header.d=") {
                let domain = token.dropFirst("header.d=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if isPlainDomain(domain) { pass.insert(domain) }
            }
        }
        return pass.sorted()
    }

    /// Letters, digits, dots and hyphens only, so a domain can go into a
    /// search command without escaping.
    static func isPlainDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.contains(".") && domain.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "." || $0 == "-"
        }
    }

    /// IMAP's date format for SEARCH SINCE, such as 1-Nov-2026.
    static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter.string(from: date)
    }
}
