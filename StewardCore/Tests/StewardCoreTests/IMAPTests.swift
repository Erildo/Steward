import Foundation
import Testing
@testable import StewardCore

/// A scripted IMAP server: each command gets the reply its handler writes.
actor FakeIMAPServer: IMAPTransport {
    typealias Handler = @Sendable (_ tag: String, _ command: String) -> String

    private var outgoing: [Data]
    private let handler: Handler
    private(set) var commands: [String] = []
    private(set) var closed = false

    init(greeting: String = "* OK IMAP ready\r\n", handler: @escaping Handler) {
        outgoing = [Data(greeting.utf8)]
        self.handler = handler
    }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let space = line.firstIndex(of: " ")!
        let tag = String(line[..<space])
        let command = String(line[line.index(after: space)...])
        commands.append(command)
        outgoing.append(Data(handler(tag, command).utf8))
    }

    func receive() async throws -> Data {
        outgoing.isEmpty ? Data() : outgoing.removeFirst()
    }

    func close() async { closed = true }
}

struct IMAPReaderTests {
    @Test func literalSplitAcrossChunks() {
        var reader = IMAPReader()
        reader.append(Data("* 1 FETCH (UID 7 BODY[]<0> {5}\r\nhel".utf8))
        #expect(reader.next() == nil)
        reader.append(Data("lo)\r\nS1 OK done\r\n".utf8))
        let fetch = reader.next()
        #expect(fetch?.literals == [Data("hello".utf8)])
        #expect(fetch?.text == "* 1 FETCH (UID 7 BODY[]<0> {5})")
        #expect(reader.next()?.text == "S1 OK done")
        #expect(reader.next() == nil)
    }

    @Test func quotingEscapesAndRefusesControlCharacters() throws {
        #expect(try IMAPSession.quoted(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(throws: IMAPError.self) { try IMAPSession.quoted("bad\r\nLOGOUT") }
    }
}

struct InboxCheckTests {
    static let company = CaseFile.Company(name: "FitWorld", domain: "fitworld.example", email: "members@fitworld.example")
    static let sent = Date(timeIntervalSince1970: 1_794_000_000)

    static func openCase(subject: String = "Cancelling membership 48213", company: CaseFile.Company = company) -> CaseFile {
        var file = CaseFile(errand: "Cancel gym", createdAt: sent, owner: .init(name: "Sam", caseAddress: "case@relay.example", accountRef: "48213", facts: "", goal: "Cancel"), company: company)
        file.emails = [.init(direction: .outgoing, date: sent, from: "case@relay.example", to: company.email, subject: subject, body: "Please cancel.")]
        file.state = .waitingForReply(callID: "c1", until: sent.addingTimeInterval(7 * 86400))
        return file
    }

    static func raw(from: String, subject: String, authResults: String? = nil) -> String {
        var lines = [String]()
        if let authResults { lines.append("Authentication-Results: \(authResults)") }
        lines += ["From: Members <\(from)>", "To: sam@gmail.com", "Subject: \(subject)", "Date: Sat, 14 Nov 2026 10:05:00 +0000", "", "We have cancelled membership 48213."]
        return lines.joined(separator: "\r\n")
    }

    static func server(messages: [UInt32: String], uidValidity: UInt32 = 42, uidNext: UInt32 = 120, search: [UInt32]? = nil) -> FakeIMAPServer {
        FakeIMAPServer { tag, command in
            if command.hasPrefix("LOGIN") { return "\(tag) OK logged in\r\n" }
            if command.hasPrefix("EXAMINE") {
                return "* OK [UIDVALIDITY \(uidValidity)] valid\r\n* OK [UIDNEXT \(uidNext)] next\r\n\(tag) OK [READ-ONLY] done\r\n"
            }
            if command.hasPrefix("UID SEARCH") {
                let found = (search ?? Array(messages.keys)).sorted().map(String.init).joined(separator: " ")
                return "* SEARCH \(found)\r\n\(tag) OK done\r\n"
            }
            if command.hasPrefix("UID FETCH") {
                let uid = UInt32(command.split(separator: " ")[2])!
                guard let body = messages[uid] else { return "\(tag) OK nothing\r\n" }
                let bytes = Data(body.utf8)
                return "* 1 FETCH (UID \(uid) BODY[]<0> {\(bytes.count)}\r\n\(body))\r\n\(tag) OK done\r\n"
            }
            if command == "LOGOUT" { return "* BYE\r\n\(tag) OK bye\r\n" }
            return "\(tag) BAD unknown\r\n"
        }
    }

    static func check(_ server: FakeIMAPServer, password: String = "abcd efgh ijkl mnop") -> InboxCheck {
        InboxCheck(server: InboxServer.known(for: "sam@gmail.com")!, address: "sam@gmail.com", password: password) { _, _ in server }
    }

    @Test func findsTheCompanyReplyAndSkipsOtherMail() async throws {
        let file = Self.openCase()
        let server = Self.server(messages: [
            101: Self.raw(from: "members@fitworld.example", subject: "Re: Cancelling membership 48213",
                          authResults: "mx.google.com; dkim=pass header.i=@fitworld.example header.s=s1 header.d=fitworld.example; spf=pass"),
            102: Self.raw(from: "deals@shop.example", subject: "50% off"),
        ])
        let (deliveries, cursor) = try await Self.check(server).run(cases: [file], cursor: InboxCursor(uidValidity: 42, lastUID: 100))

        #expect(deliveries.count == 1)
        #expect(deliveries.first?.caseID == file.id)
        #expect(deliveries.first?.email.direction == .incoming)
        #expect(deliveries.first?.email.body == "We have cancelled membership 48213.")
        #expect(deliveries.first?.email.isSigned(by: "fitworld.example") == true)
        #expect(cursor == InboxCursor(uidValidity: 42, lastUID: 119))

        let commands = await server.commands
        #expect(commands.contains { $0.hasPrefix("EXAMINE INBOX") })
        #expect(commands.contains { $0 == "UID SEARCH UID 101:* SINCE 5-Nov-2026 FROM \"fitworld.example\"" })
        #expect(commands.filter { $0.hasPrefix("UID FETCH") }.allSatisfy { $0.contains("BODY.PEEK[]") })
        #expect(await server.closed)
    }

    @Test func forgedAuthenticationResultsDoNotCountAsSigned() async throws {
        let server = Self.server(messages: [
            101: Self.raw(from: "members@fitworld.example", subject: "Re: Cancelling membership 48213",
                          authResults: "evil.example; dkim=pass header.d=fitworld.example"),
        ])
        let (deliveries, _) = try await Self.check(server).run(cases: [Self.openCase()], cursor: .init(uidValidity: 42, lastUID: 100))
        #expect(deliveries.first?.email.dkimPass == [])
    }

    @Test func doesNotConnectWithoutAnOpenErrandThatSentSomething() async throws {
        var closed = Self.openCase()
        closed.state = .closed
        var unsent = Self.openCase()
        unsent.emails = []
        let check = InboxCheck(server: InboxServer.known(for: "sam@gmail.com")!, address: "sam@gmail.com", password: "x") { _, _ in
            Issue.record("connected")
            throw IMAPError(.closed, "no")
        }
        let (deliveries, cursor) = try await check.run(cases: [closed, unsent], cursor: .init(uidValidity: 42, lastUID: 7))
        #expect(deliveries.isEmpty)
        #expect(cursor == .init(uidValidity: 42, lastUID: 7))
    }

    @Test func skipsAReplyTheCaseAlreadyHas() async throws {
        var file = Self.openCase()
        let raw = Self.raw(from: "members@fitworld.example", subject: "Re: Cancelling membership 48213")
        let message = MIMEMessage(Data(raw.utf8))
        file.emails.append(.init(direction: .incoming, date: message.date!, from: "members@fitworld.example", to: "case@relay.example", subject: message.subject, body: message.text))
        let (deliveries, _) = try await Self.check(Self.server(messages: [101: raw])).run(cases: [file], cursor: .init(uidValidity: 42, lastUID: 100))
        #expect(deliveries.isEmpty)
    }

    @Test func newUIDValiditySearchesFromTheStart() async throws {
        let server = Self.server(messages: [5: Self.raw(from: "members@fitworld.example", subject: "Re: Cancelling membership 48213")], uidValidity: 99)
        let (deliveries, cursor) = try await Self.check(server).run(cases: [Self.openCase()], cursor: .init(uidValidity: 42, lastUID: 100))
        #expect(deliveries.count == 1)
        #expect(cursor.uidValidity == 99)
        #expect(await server.commands.contains { $0.hasPrefix("UID SEARCH UID 1:*") })
    }

    @Test func ignoresTheNewestMessageThatStarRangesAlwaysReturn() async throws {
        let server = Self.server(messages: [90: Self.raw(from: "members@fitworld.example", subject: "Old")], search: [90])
        let (deliveries, _) = try await Self.check(server).run(cases: [Self.openCase()], cursor: .init(uidValidity: 42, lastUID: 100))
        #expect(deliveries.isEmpty)
        #expect(await !server.commands.contains { $0.hasPrefix("UID FETCH") })
    }

    @Test func picksTheCaseWhoseEmailTheReplyAnswers() async throws {
        let older = Self.openCase(subject: "Refund for order 77")
        var newer = Self.openCase(subject: "Cancelling membership 48213")
        newer.createdAt = Self.sent.addingTimeInterval(3600)
        let server = Self.server(messages: [101: Self.raw(from: "members@fitworld.example", subject: "RE: Refund for order 77")])
        let (deliveries, _) = try await Self.check(server).run(cases: [older, newer], cursor: .init(uidValidity: 42, lastUID: 100))
        #expect(deliveries.first?.caseID == older.id)
    }

    @Test func wrongAppPasswordSaysSoPlainly() async throws {
        let server = FakeIMAPServer { tag, command in
            command.hasPrefix("LOGIN") ? "\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n" : "\(tag) OK\r\n"
        }
        await #expect(throws: IMAPError(.rejected, "The mail server didn't accept that address and app password.")) {
            try await Self.check(server).test()
        }
        #expect(await server.closed)
    }

    @Test func knownServersAndOAuthOnlyProviders() {
        #expect(InboxServer.known(for: "a@icloud.com")?.host == "imap.mail.me.com")
        #expect(InboxServer.known(for: "a@yahoo.co.uk")?.host == "imap.mail.yahoo.com")
        #expect(InboxServer.known(for: "a@company.example") == nil)
        #expect(InboxServer.needsOAuth("a@hotmail.co.uk"))
        #expect(!InboxServer.needsOAuth("a@gmail.com"))
    }
}
