import Foundation
import Testing
@testable import StewardCore

/// A scripted SMTP server. Commands get the reply `handler` writes; between
/// DATA and the lone "." it collects the message, then answers `afterData`
/// (or closes the connection when that is `nil`).
actor FakeSMTPServer: SMTPTransport {
    typealias Handler = @Sendable (_ command: String) -> String

    private var outgoing: [Data]
    private let handler: Handler
    private let afterData: String?
    private var inData = false
    private var pending = ""
    private(set) var commands: [String] = []
    private(set) var message = ""
    private(set) var upgraded = false
    private(set) var closed = false

    init(afterData: String? = "250 2.0.0 OK queued\r\n", handler: @escaping Handler = FakeSMTPServer.happy) {
        outgoing = [Data("220 smtp.example ESMTP ready\r\n".utf8)]
        self.handler = handler
        self.afterData = afterData
    }

    static let happy: Handler = { command in
        if command.hasPrefix("EHLO") { return "250-smtp.example\r\n250-8BITMIME\r\n250-AUTH LOGIN PLAIN\r\n250 STARTTLS\r\n" }
        if command.hasPrefix("AUTH PLAIN") { return "235 2.7.0 Accepted\r\n" }
        if command.hasPrefix("MAIL FROM") || command.hasPrefix("RCPT TO") { return "250 OK\r\n" }
        if command == "DATA" { return "354 Go ahead\r\n" }
        if command == "STARTTLS" { return "220 Ready to start TLS\r\n" }
        if command == "QUIT" { return "221 Bye\r\n" }
        return "500 unknown\r\n"
    }

    func send(_ data: Data) async throws {
        pending += String(decoding: data, as: UTF8.self)
        while let range = pending.range(of: "\r\n") {
            let line = String(pending[..<range.lowerBound])
            pending.removeSubrange(..<range.upperBound)
            if inData {
                if line == "." {
                    inData = false
                    if let afterData { outgoing.append(Data(afterData.utf8)) } else { closed = true }
                } else {
                    message += line + "\r\n"
                }
                continue
            }
            commands.append(line)
            let reply = handler(line)
            if line == "DATA", reply.hasPrefix("354") { inData = true }
            outgoing.append(Data(reply.utf8))
        }
    }

    func receive() async throws -> Data {
        if outgoing.isEmpty { return Data() }
        return outgoing.removeFirst()
    }

    func startTLS() async throws { upgraded = true }
    func close() async { closed = true }
}

private func ledger() -> SendLedger {
    SendLedger(url: FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json"))
}

private func approved(_ sendID: String = "case-1-call-1", body: String = "Please cancel membership 48213.\n.\nThanks") -> CaseFile.Email {
    var email = CaseFile.Email(direction: .outgoing, date: .now, from: "sam@gmail.com", to: "members@fitworld.example", subject: "Cancelling membership 48213", body: body)
    email.sendID = sendID
    return email
}

private func caseFile() -> CaseFile {
    InboxCheckTests.openCase()
}

struct SMTPSessionTests {
    @Test func sendsOnceFromTheOwnersAddress() async throws {
        let server = FakeSMTPServer()
        let book = ledger()
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: "sam@gmail.com", password: "app-pass", ledger: book) { _ in server }

        try await mailer.send(approved(), in: caseFile())

        let commands = await server.commands
        #expect(commands == [
            "EHLO [127.0.0.1]",
            "AUTH PLAIN " + Data("\0sam@gmail.com\0app-pass".utf8).base64EncodedString(),
            "MAIL FROM:<sam@gmail.com>",
            "RCPT TO:<members@fitworld.example>",
            "DATA",
            "QUIT",
        ])
        let message = await server.message
        #expect(message.contains("From: \"Sam\" <sam@gmail.com>\r\n"))
        #expect(message.contains("To: <members@fitworld.example>\r\n"))
        #expect(message.contains("Message-ID: <case-1-call-1@gmail.com>\r\n"))
        // A line holding only "." is doubled on the wire, so it can't end DATA early.
        #expect(message.contains("\r\n..\r\n"))
        #expect(book.mark("case-1-call-1") == .sent)
        #expect(await server.upgraded == false)

        // The same approval again: nothing is sent, nothing even connects.
        let again = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: "sam@gmail.com", password: "app-pass", ledger: book) { _ in
            Issue.record("connected for an email already sent")
            throw SMTPError(.closed, "no")
        }
        try await again.send(approved(), in: caseFile())
    }

    @Test func upgradesWithStartTLSBeforeLoggingIn() async throws {
        let server = FakeSMTPServer()
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.mail.me.com", port: 587, startTLS: true), address: "sam@icloud.com", password: "p", ledger: ledger()) { _ in server }
        try await mailer.send(approved(), in: caseFile())
        let commands = await server.commands
        #expect(Array(commands.prefix(3)) == ["EHLO [127.0.0.1]", "STARTTLS", "EHLO [127.0.0.1]"])
        #expect(commands[3].hasPrefix("AUTH PLAIN"))
        #expect(await server.upgraded)
    }

    @Test func refusesAServerWithoutStartTLSWhenItIsNeeded() async throws {
        let server = FakeSMTPServer { command in
            command.hasPrefix("EHLO") ? "250-smtp.example\r\n250 AUTH PLAIN\r\n" : FakeSMTPServer.happy(command)
        }
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.example", port: 587, startTLS: true), address: "sam@example.com", password: "p", ledger: ledger()) { _ in server }
        await #expect(throws: SMTPError.self) { try await mailer.send(approved(), in: caseFile()) }
        #expect(await !server.commands.contains { $0.hasPrefix("AUTH") }, "the password never goes over a plain connection")
    }

    @Test func aWrongAppPasswordSendsNothingAndCanBeRetried() async throws {
        let book = ledger()
        let server = FakeSMTPServer { command in
            command.hasPrefix("AUTH") ? "535 5.7.8 Username and Password not accepted\r\n" : FakeSMTPServer.happy(command)
        }
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: "sam@gmail.com", password: "wrong", ledger: book) { _ in server }
        do {
            try await mailer.send(approved(), in: caseFile())
            Issue.record("expected a refusal")
        } catch let error as SMTPError {
            #expect(error.kind == .rejected)
            #expect(error.code == 535)
        }
        #expect(await !server.commands.contains("DATA"))
        #expect(book.mark("case-1-call-1") == nil)
    }

    @Test func aRefusedMessageCanBeRetried() async throws {
        let book = ledger()
        let server = FakeSMTPServer(afterData: "554 5.7.1 Message rejected\r\n")
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: "sam@gmail.com", password: "p", ledger: book) { _ in server }
        await #expect(throws: SMTPError.self) { try await mailer.send(approved(), in: caseFile()) }
        #expect(book.mark("case-1-call-1") == nil)
    }

    @Test func aConnectionCutDuringTheHandOverIsNeverRetriedOnItsOwn() async throws {
        let book = ledger()
        let server = FakeSMTPServer(afterData: nil)
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: "sam@gmail.com", password: "p", ledger: book) { _ in server }
        do {
            try await mailer.send(approved(), in: caseFile())
            Issue.record("expected an uncertain send")
        } catch let error as SMTPError {
            #expect(error.kind == .uncertain)
        }
        #expect(book.mark("case-1-call-1") == .handingOver)

        let retry = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: "sam@gmail.com", password: "p", ledger: book) { _ in
            Issue.record("connected again for an email that may have gone")
            throw SMTPError(.closed, "no")
        }
        await #expect(throws: SMTPError.self) { try await retry.send(approved(), in: caseFile()) }
    }

    @Test func fallsBackToAuthLogin() async throws {
        let server = FakeSMTPServer { command in
            if command.hasPrefix("EHLO") { return "250-smtp.example\r\n250 AUTH LOGIN\r\n" }
            if command == "AUTH LOGIN" { return "334 VXNlcm5hbWU6\r\n" }
            if command == Data("sam@example.com".utf8).base64EncodedString() { return "334 UGFzc3dvcmQ6\r\n" }
            if command == Data("p".utf8).base64EncodedString() { return "235 OK\r\n" }
            return FakeSMTPServer.happy(command)
        }
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.example"), address: "sam@example.com", password: "p", ledger: ledger()) { _ in server }
        try await mailer.send(approved(), in: caseFile())
        #expect(await server.commands.contains("DATA"))
    }

    @Test func multiLineRepliesAreReadWhole() async throws {
        let server = FakeSMTPServer()
        let session = SMTPSession(transport: server)
        try await session.greeting()
        let extensions = try await session.hello(startTLS: false)
        #expect(extensions == ["8BITMIME", "AUTH LOGIN PLAIN", "STARTTLS"])
    }
}

struct OutgoingMessageTests {
    @Test func encodesNonASCIIAndKeepsHeadersOnOneLine() {
        var email = approved(body: "Ich kündige zum nächstmöglichen Termin.")
        email.subject = "Kündigung 448120\r\nBcc: evil@example.com"
        let text = String(decoding: OutgoingMessage.render(email, fromName: "Lena Hoffmann", fromAddress: "lena@gmail.com", date: Date(timeIntervalSince1970: 0)), as: UTF8.self)

        #expect(!text.contains("\r\nBcc:"), "a line break in the subject can't add a header")
        #expect(text.contains("Subject: =?UTF-8?B?"))
        #expect(text.contains("Content-Transfer-Encoding: quoted-printable"))
        #expect(text.contains("Ich k=C3=BCndige zum n=C3=A4chstm=C3=B6glichen Termin."))
        let subject = MIMEMessage(Data(text.utf8)).subject
        #expect(subject == "Kündigung 448120 Bcc: evil@example.com", "\(subject.debugDescription)")
        #expect(MIMEMessage(Data(text.utf8)).text == "Ich kündige zum nächstmöglichen Termin.")
    }

    @Test func longLinesGetSoftBreaks() {
        let line = String(repeating: "a", count: 200)
        let encoded = OutgoingMessage.quotedPrintable(line)
        #expect(encoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        #expect(encoded.replacingOccurrences(of: "=\r\n", with: "") == line)
    }

    @Test func knownProvidersSendThroughTheirOwnServer() {
        #expect(InboxServer.known(for: "sam@gmail.com")?.sending(for: "sam@gmail.com") == SMTPServer(host: "smtp.gmail.com"))
        #expect(InboxServer.known(for: "sam@icloud.com")?.sending(for: "sam@icloud.com") == SMTPServer(host: "smtp.mail.me.com", port: 587, startTLS: true))
        // Settings saved before sending existed still find their server.
        #expect(InboxServer(host: "imap.gmail.com", provider: "Gmail").sending(for: "sam@gmail.com") == SMTPServer(host: "smtp.gmail.com"))
        #expect(InboxServer(host: "imap.example.org", provider: "x").sending(for: "sam@example.org") == SMTPServer(host: "smtp.example.org"))
    }
}

/// The whole errand on the owner's own mailbox, with no relay: the agent
/// drafts, the owner approves, the email leaves through their SMTP server,
/// the company's reply turns up in their inbox at a check-in, and the case
/// closes on the company's signed words.
struct OwnerMailboxFlowTests {
    static let owner = "sam@gmail.com"

    static func errand() -> CaseFile {
        CaseFile(
            errand: "cancel",
            createdAt: Date(timeIntervalSince1970: 1_794_268_800),
            owner: .init(name: "Sam Rivera", caseAddress: owner, accountRef: "Member 48213", facts: "Monthly plan.", goal: "Cancel with written confirmation."),
            company: InboxCheckTests.company)
    }

    @Test func draftApproveSendReplyAndClose() async throws {
        let clock = Clock()
        let smtp = FakeSMTPServer()
        let book = ledger()
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: Self.owner, password: "p", ledger: book, now: { clock.now }) { _ in smtp }
        let steward = Agent(model: ScriptedModelClient([
            call("1", "send_email", ["to": .string("members@fitworld.example"), "subject": .string("Cancelling membership 48213"), "body": .string("Please cancel membership 48213.\nSam Rivera")]),
            call("2", "wait_for_reply", ["max_days": .number(7)]),
            call("3", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("We have cancelled membership 48213.")]),
        ]), mail: mailer, now: { clock.now })

        // 1. The agent drafts; nothing leaves before the owner's yes.
        var file = try await steward.wake(Self.errand(), with: .start)
        guard case .needsApproval(_, let draft) = file.state else { Issue.record("expected approval, got \(file.state)"); return }
        #expect(draft.from == Self.owner)
        #expect(await smtp.commands.isEmpty)

        // 2. The owner approves: it goes out once, from their own address.
        file = try await steward.wake(file, with: .approval(callID: "1", approved: true))
        guard case .waitingForReply = file.state else { Issue.record("expected waiting, got \(file.state)"); return }
        #expect(await smtp.commands.contains("MAIL FROM:<sam@gmail.com>"))
        #expect(await smtp.message.contains("Subject: Cancelling membership 48213"))

        // A late second tap on the same approval sends nothing more.
        let again = try await steward.wake(file, with: .approval(callID: "1", approved: true))
        #expect(again.state == file.state)
        #expect(await smtp.commands.filter { $0 == "DATA" }.count == 1)

        // 3. A check-in finds the company's reply in the owner's inbox.
        clock.advance(days: 2)
        let imap = InboxCheckTests.server(messages: [
            150: InboxCheckTests.raw(from: "members@fitworld.example", subject: "Re: Cancelling membership 48213",
                                     authResults: "mx.google.com; dkim=pass header.d=fitworld.example"),
        ])
        let check = InboxCheck(server: InboxServer.known(for: Self.owner)!, address: Self.owner, password: "p") { _, _ in imap }
        let (deliveries, _) = try await check.run(cases: [file], cursor: InboxCursor())
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.caseID == file.id)

        // 4. The reply wakes the case, which closes as done on the signed words.
        file = try await steward.wake(file, with: .mail(deliveries.map(\.email)))
        #expect(file.state == .closed)
        #expect(file.closure?.status == .done)
        #expect(file.emails.map(\.direction) == [.outgoing, .incoming])
    }

    @Test func unsignedReplyCannotCloseAsDone() async throws {
        let clock = Clock()
        let smtp = FakeSMTPServer()
        let mailer = OwnerMailer(server: SMTPServer(host: "smtp.gmail.com"), address: Self.owner, password: "p", ledger: ledger(), now: { clock.now }) { _ in smtp }
        let steward = Agent(model: ScriptedModelClient([
            call("1", "send_email", ["to": .string("members@fitworld.example"), "subject": .string("Cancelling membership 48213"), "body": .string("Please cancel.")]),
            call("2", "wait_for_reply", ["max_days": .number(7)]),
            call("3", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("We have cancelled membership 48213.")]),
            call("4", "wait_for_reply", ["max_days": .number(7)]),
        ]), mail: mailer, now: { clock.now })
        var file = try await steward.wake(Self.errand(), with: .start)
        file = try await steward.wake(file, with: .approval(callID: "1", approved: true))

        // Someone else's server claims the company signed it: it doesn't count.
        let imap = InboxCheckTests.server(messages: [
            150: InboxCheckTests.raw(from: "members@fitworld.example", subject: "Re: Cancelling membership 48213",
                                     authResults: "evil.example; dkim=pass header.d=fitworld.example"),
        ])
        let check = InboxCheck(server: InboxServer.known(for: Self.owner)!, address: Self.owner, password: "p") { _, _ in imap }
        let (deliveries, _) = try await check.run(cases: [file], cursor: InboxCursor())
        file = try await steward.wake(file, with: .mail(deliveries.map(\.email)))
        #expect(file.closure?.status != .done)
    }
}

/// Reaches real sending servers, greeting and EHLO only: no login, nothing
/// sent. Run with `STEWARD_LIVE_SMTP=1 swift test --filter LiveSMTPTests`.
struct LiveSMTPTests {
    static let enabled = ProcessInfo.processInfo.environment["STEWARD_LIVE_SMTP"] == "1"

    @Test(.enabled(if: enabled), arguments: [
        SMTPServer(host: "smtp.gmail.com"),
        SMTPServer(host: "smtp.mail.me.com", port: 587, startTLS: true),
        SMTPServer(host: "smtp.mail.yahoo.com"),
    ])
    func greetsOverTLS(_ server: SMTPServer) async throws {
        let session = SMTPSession(transport: try await SMTPStreamTransport.connect(server))
        try await session.greeting()
        let extensions = try await session.hello(startTLS: server.startTLS)
        #expect(extensions.contains { $0.hasPrefix("AUTH") }, "\(server.host) offers login over TLS: \(extensions)")
        await session.quit()
    }

    /// A local STARTTLS server with a self-signed certificate
    /// (`STEWARD_LOCAL_STARTTLS=<port>`): without pinning, the upgrade starts
    /// and stops on the untrusted certificate within seconds, never hangs and
    /// never logs in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STEWARD_LOCAL_STARTTLS"] != nil))
    func startTLSRefusesAnUntrustedCertificateQuickly() async throws {
        let port = UInt16(ProcessInfo.processInfo.environment["STEWARD_LOCAL_STARTTLS"]!)!
        let mailer = OwnerMailer(server: SMTPServer(host: "127.0.0.1", port: port, startTLS: true), address: "sam@example.com", password: "app-pass", ledger: ledger()) {
            try await SMTPStreamTransport.connect($0, seconds: 5)
        }
        let started = Date.now
        do {
            try await mailer.send(approved(), in: caseFile())
            Issue.record("an untrusted certificate was accepted")
        } catch let error as SMTPError {
            #expect(error.kind != .uncertain, "\(error)")
        }
        #expect(Date.now.timeIntervalSince(started) < 15, "gave up in time instead of hanging")
    }

    /// The same server with its certificate pinned (`STEWARD_LOCAL_CERT`, DER):
    /// STARTTLS, login and the whole email go through over the upgraded link.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STEWARD_LOCAL_CERT"] != nil))
    func startTLSSendsOverTheUpgradedConnection() async throws {
        let port = UInt16(ProcessInfo.processInfo.environment["STEWARD_LOCAL_STARTTLS"]!)!
        let pinned = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["STEWARD_LOCAL_CERT"]!))
        let book = ledger()
        let mailer = OwnerMailer(server: SMTPServer(host: "127.0.0.1", port: port, startTLS: true), address: "sam@example.com", password: "app-pass", ledger: book) {
            try await SMTPStreamTransport.connect($0, pinnedCertificate: pinned, seconds: 5)
        }
        try await mailer.send(approved(), in: caseFile())
        #expect(book.mark("case-1-call-1") == .sent)

        let wrong = OwnerMailer(server: SMTPServer(host: "127.0.0.1", port: port, startTLS: true), address: "sam@example.com", password: "nope", ledger: ledger()) {
            try await SMTPStreamTransport.connect($0, pinnedCertificate: pinned, seconds: 5)
        }
        do {
            try await wrong.test()
            Issue.record("a wrong password was accepted")
        } catch let error as SMTPError {
            #expect(error.kind == .rejected, "\(error.message)")
        }
    }
}

struct DeadlineTests {
    @Test func givesUpOnWorkThatNeverReturns() async throws {
        let started = Date.now
        await #expect(throws: SMTPError.self) {
            try await withDeadline(0.2, timeoutError: { SMTPError(.timeout, "slow") }) {
                // Ignores cancellation, like a stuck network read.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        #expect(Date.now.timeIntervalSince(started) < 2)
    }

    @Test func returnsTheWorkWhenItIsFast() async throws {
        let value = try await withDeadline(5, timeoutError: { SMTPError(.timeout, "slow") }) { 42 }
        #expect(value == 42)
    }

    @Test func aCancelledCallerIsAnsweredEvenIfTheWorkIsStuck() async throws {
        let task = Task {
            try await withDeadline(30, timeoutError: { SMTPError(.timeout, "slow") }) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let started = Date.now
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date.now.timeIntervalSince(started) < 2)
    }
}

struct SendingServerTests {
    @Test func typedServersAndIncomingHosts() {
        #expect(InboxServer.sendingServer(typed: "smtp.example.com") == SMTPServer(host: "smtp.example.com"))
        #expect(InboxServer.sendingServer(typed: "smtp.example.com:587") == SMTPServer(host: "smtp.example.com", port: 587, startTLS: true))
        #expect(InboxServer.sendingServer(typed: "nonsense") == nil)
        // A custom-domain iCloud address still sends through iCloud on 587.
        #expect(InboxServer(host: "imap.mail.me.com", provider: "x").sending(for: "me@mydomain.example") == SMTPServer(host: "smtp.mail.me.com", port: 587, startTLS: true))
    }

    @Test func quitIsNeverSentInsideTheMessage() async throws {
        let server = FakeSMTPServer()
        let session = SMTPSession(transport: server)
        try await session.greeting()
        _ = try await session.hello(startTLS: false)
        struct LedgerBroke: Error {}
        await #expect(throws: LedgerBroke.self) {
            try await session.send(from: "sam@gmail.com", to: "members@fitworld.example", message: Data("Subject: x\r\n\r\nbody".utf8)) { throw LedgerBroke() }
        }
        await session.quit()
        #expect(await !server.message.contains("QUIT"))
        #expect(await !server.commands.contains("QUIT"))
        #expect(await server.closed)
    }
}
