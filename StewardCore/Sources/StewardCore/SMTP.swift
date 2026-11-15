import Foundation

// Just enough SMTP (RFC 5321) to send an approved email from the owner's own
// mailbox with the same app password the inbox check uses: greet, EHLO,
// STARTTLS when the server needs it, AUTH, one MAIL/RCPT/DATA, QUIT.
// There is no relay: the email leaves from the owner's own address, and their
// provider keeps it in their Sent folder (Gmail does this for SMTP mail).

/// The byte stream to the server. `startTLS` upgrades it in place after the
/// server agreed to STARTTLS. `receive` returns empty data once closed.
public protocol SMTPTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func startTLS() async throws
    func close() async
}

/// The owner's sending server.
public struct SMTPServer: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    /// `true`: plain connection upgraded with STARTTLS (port 587).
    /// `false`: TLS from the first byte (port 465).
    public var startTLS: Bool

    public init(host: String, port: UInt16 = 465, startTLS: Bool = false) {
        self.host = host
        self.port = port
        self.startTLS = startTLS
    }
}

public struct SMTPError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: Sendable, Equatable {
        /// The server refused: a wrong app password, or an address it won't take.
        case rejected
        case closed
        case malformed
        case timeout
        /// The email may have gone out: the connection broke after the whole
        /// message was handed over. Never retried on its own.
        case uncertain
    }
    public var kind: Kind
    public var code: Int?
    public var message: String
    public var description: String { message }

    public init(_ kind: Kind, _ message: String, code: Int? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
    }

    /// What the owner does when a send may or may not have gone out. Approving
    /// the same draft again never resends it; declining ends it, and a new
    /// draft gets a new send ID, so it can go out once.
    static let uncertainAdvice = "Look in your Sent folder. If it's there, decline this draft and tell Steward it went out. If it isn't, decline it and Steward will write a fresh one."
}

/// One server reply: its code and the text of every line.
public struct SMTPReply: Sendable, Equatable {
    public var code: Int
    public var lines: [String]
}

/// One conversation with the server.
public final class SMTPSession: @unchecked Sendable {
    private let transport: any SMTPTransport
    private var buffer: [UInt8] = []
    /// Between DATA and the final ".": a QUIT now would become a line of the
    /// email, so the connection is just closed (the server drops the email).
    private var inMessage = false

    public init(transport: any SMTPTransport) {
        self.transport = transport
    }

    // MARK: Replies

    /// Reads one reply, waiting for every line of a multi-line one ("250-…").
    func reply() async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPError(.malformed, "The mail server sent something Steward didn't understand.")
            }
            let rest = line.dropFirst(3)
            lines.append(String(rest.dropFirst()))
            if rest.first != "-" { return SMTPReply(code: code, lines: lines) }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let end = Self.crlf(in: buffer) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeFirst(end + 2)
                return line
            }
            let data = try await transport.receive()
            if data.isEmpty { throw SMTPError(.closed, "The mail server closed the connection.") }
            buffer.append(contentsOf: data)
            if buffer.count > 1_000_000 { throw SMTPError(.malformed, "The mail server's reply was too long.") }
        }
    }

    private static func crlf(in bytes: [UInt8]) -> Int? {
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 13, bytes[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// Sends one command line and checks the reply's code.
    @discardableResult
    func command(_ line: String, expect: Set<Int>, _ failure: String) async throws -> SMTPReply {
        guard !line.contains("\r"), !line.contains("\n") else { throw SMTPError(.malformed, "A line break can't go into a mail command.") }
        try await transport.send(Data((line + "\r\n").utf8))
        let reply = try await reply()
        guard expect.contains(reply.code) else {
            let said = reply.lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            throw SMTPError(reply.code >= 400 ? .rejected : .malformed, said.isEmpty ? failure : "\(failure) (\(said))", code: reply.code)
        }
        return reply
    }

    // MARK: Steps

    public func greeting() async throws {
        let reply = try await reply()
        guard reply.code == 220 else { throw SMTPError(.rejected, "The mail server isn't taking mail right now.", code: reply.code) }
    }

    /// EHLO, then STARTTLS and EHLO again if the server needs it. Returns the
    /// server's extensions, upper-cased.
    @discardableResult
    public func hello(startTLS: Bool) async throws -> [String] {
        var extensions = try await ehlo()
        if startTLS {
            guard extensions.contains("STARTTLS") else {
                throw SMTPError(.rejected, "That mail server doesn't offer a secure connection, so Steward won't send through it.")
            }
            try await command("STARTTLS", expect: [220], "The mail server wouldn't start a secure connection.")
            // Anything read before the upgrade can't be trusted after it.
            buffer.removeAll()
            try await transport.startTLS()
            extensions = try await ehlo()
        }
        return extensions
    }

    private func ehlo() async throws -> [String] {
        // An address literal: a phone has no host name of its own.
        let reply = try await command("EHLO [127.0.0.1]", expect: [250], "The mail server didn't accept Steward's greeting.")
        return reply.lines.dropFirst().map { $0.uppercased() }
    }

    /// AUTH PLAIN, or AUTH LOGIN for servers that only offer that.
    public func login(user: String, password: String, extensions: [String]) async throws {
        let mechanisms = extensions.filter { $0.hasPrefix("AUTH") }.flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "=" }).dropFirst() }.map(String.init)
        let refused = "Your mail provider didn't accept that address and app password."
        if mechanisms.contains("LOGIN") && !mechanisms.contains("PLAIN") {
            try await command("AUTH LOGIN", expect: [334], refused)
            try await command(Data(user.utf8).base64EncodedString(), expect: [334], refused)
            try await command(Data(password.utf8).base64EncodedString(), expect: [235], refused)
        } else {
            let token = Data(("\0" + user + "\0" + password).utf8).base64EncodedString()
            try await command("AUTH PLAIN " + token, expect: [235], refused)
        }
    }

    /// One email: envelope, then the message. `beforeLastByte` runs just
    /// before the final "." goes out, the last moment the send can still be
    /// called off for sure.
    public func send(from: String, to: String, message: Data, beforeLastByte: () throws -> Void) async throws {
        try await command("MAIL FROM:<\(try Self.address(from))>", expect: [250], "Your mail provider wouldn't send from \(from).")
        try await command("RCPT TO:<\(try Self.address(to))>", expect: [250, 251], "Your mail provider wouldn't send to \(to).")
        try await command("DATA", expect: [354], "Your mail provider wouldn't take the email.")
        inMessage = true
        try await transport.send(Self.dotStuffed(message))
        try beforeLastByte()
        do {
            try await transport.send(Data(".\r\n".utf8))
            inMessage = false
            let reply = try await reply()
            guard reply.code == 250 else {
                let said = reply.lines.joined(separator: " ")
                throw SMTPError(.rejected, "Your mail provider refused the email (\(said)).", code: reply.code)
            }
        } catch let error as SMTPError where error.kind == .rejected {
            throw error
        } catch {
            throw SMTPError(.uncertain, "The connection broke just as the email was handed over, so it may have gone out. " + SMTPError.uncertainAdvice)
        }
    }

    public func quit() async {
        if !inMessage { _ = try? await command("QUIT", expect: [221], "") }
        await transport.close()
    }

    // MARK: Encoding

    /// An address for the envelope: no spaces, brackets or line breaks.
    static func address(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let bad = CharacterSet(charactersIn: "<>\r\n \t\"")
        guard trimmed.contains("@"), trimmed.rangeOfCharacter(from: bad) == nil else {
            throw SMTPError(.malformed, "\(text) isn't an email address Steward can send to.")
        }
        return trimmed
    }

    /// The message with CRLF line ends, each line starting with "." doubled,
    /// and a final CRLF, ready for the "." that ends DATA.
    static func dotStuffed(_ message: Data) -> Data {
        let text = String(decoding: message, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let stuffed = lines.map { $0.hasPrefix(".") ? "." + $0 : $0 }
        return Data((stuffed.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

// MARK: The message

/// An approved email as the message the owner's server sends: plain text in
/// UTF-8, quoted-printable, with a Message-ID made from its `sendID`.
public enum OutgoingMessage {
    public static func render(_ email: CaseFile.Email, fromName: String, fromAddress: String, date: Date) -> Data {
        let domain = fromAddress.split(separator: "@").last.map(String.init) ?? "steward.invalid"
        let id = (email.sendID ?? UUID().uuidString.lowercased()).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let name = oneLine(fromName)
        var headers = [
            "From: " + (name.isEmpty ? "<\(fromAddress)>" : "\(displayName(name)) <\(fromAddress)>"),
            "To: <\(oneLine(email.to))>",
            "Subject: " + encodedWord(oneLine(email.subject)),
            "Date: " + rfc5322(date),
            "Message-ID: <\(id)@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
        ]
        headers.append("")
        return Data((headers.joined(separator: "\r\n") + "\r\n" + quotedPrintable(email.body)).utf8)
    }

    /// Line breaks in a header would start a new header: never let them in.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func displayName(_ name: String) -> String {
        if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return encodedWord(name)
    }

    /// RFC 2047: plain ASCII as it is, anything else as base64 encoded words
    /// of at most 75 characters, split between characters, never inside one.
    static func encodedWord(_ text: String) -> String {
        let text = String(text.prefix(300))
        guard !text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) || text.contains("=?") else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if (chunk + String(character)).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }

    /// RFC 2045 quoted-printable, lines no longer than 76, with CRLF ends.
    static func quotedPrintable(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return lines.map { line -> String in
            let bytes = Array(line.utf8)
            var out = ""
            var current = ""
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let piece: String
                if (byte == 32 || byte == 9) && isLast {
                    piece = String(format: "=%02X", byte)
                } else if (byte >= 33 && byte <= 126 && byte != 61) || byte == 32 || byte == 9 {
                    piece = String(UnicodeScalar(byte))
                } else {
                    piece = String(format: "=%02X", byte)
                }
                // Room for the soft break "=" at the end of a 76-character line.
                if current.count + piece.count > 75 {
                    out += current + "=\r\n"
                    current = ""
                }
                current += piece
            }
            return out + current
        }.joined(separator: "\r\n")
    }

    static func rfc5322(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

// MARK: At most once

/// Which approved emails were handed to the owner's server, by `sendID`, kept
/// in a small file next to the cases. SMTP has no "send once" of its own, so
/// this is what makes a retried approval safe: an email marked sent is never
/// sent again, and one cut off mid-hand-over is never sent again on its own.
public final class SendLedger: @unchecked Sendable {
    public enum Mark: String, Codable, Sendable { case handingOver, sent }

    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func mark(_ sendID: String) -> Mark? {
        lock.withLock { read()[sendID] }
    }

    public func set(_ sendID: String, _ mark: Mark?) throws {
        try lock.withLock {
            var marks = read()
            marks[sendID] = mark
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(marks).write(to: url, options: .atomic)
        }
    }

    private func read() -> [String: Mark] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Mark].self, from: $0) } ?? [:]
    }
}

// MARK: Sending from the owner's mailbox

/// Sends approved emails from the owner's own address through their own
/// server. Each `sendID` goes out at most once.
public struct OwnerMailer: MailSender {
    public typealias Connect = @Sendable (_ server: SMTPServer) async throws -> any SMTPTransport

    public var server: SMTPServer
    public var address: String
    public var password: String
    public var ledger: SendLedger
    public var connect: Connect
    public var now: @Sendable () -> Date

    public init(server: SMTPServer, address: String, password: String, ledger: SendLedger, now: @escaping @Sendable () -> Date = { .now }, connect: @escaping Connect) {
        self.server = server
        self.address = address
        self.password = password
        self.ledger = ledger
        self.now = now
        self.connect = connect
    }

    public func send(_ email: CaseFile.Email, in file: CaseFile) async throws {
        let sendID = email.sendID
        if let sendID {
            switch ledger.mark(sendID) {
            case .sent: return
            case .handingOver:
                throw SMTPError(.uncertain, "This email may already have gone out. " + SMTPError.uncertainAdvice)
            case nil: break
            }
        }
        let message = OutgoingMessage.render(email, fromName: file.owner.name, fromAddress: address, date: now())
        let session = SMTPSession(transport: try await connect(server))
        do {
            try await session.greeting()
            let extensions = try await session.hello(startTLS: server.startTLS)
            try await session.login(user: address, password: password, extensions: extensions)
            try await session.send(from: address, to: email.to, message: message) {
                if let sendID { try ledger.set(sendID, .handingOver) }
            }
        } catch {
            // Refused for sure (not cut off mid-hand-over): approving again may retry.
            if let sendID, (error as? SMTPError)?.kind != .uncertain, ledger.mark(sendID) == .handingOver {
                try? ledger.set(sendID, nil)
            }
            await session.quit()
            throw error
        }
        if let sendID { try? ledger.set(sendID, .sent) }
        await session.quit()
    }

    /// Logs in and out again: checks the address and app password can send.
    public func test() async throws {
        let session = SMTPSession(transport: try await connect(server))
        do {
            try await session.greeting()
            let extensions = try await session.hello(startTLS: server.startTLS)
            try await session.login(user: address, password: password, extensions: extensions)
        } catch {
            await session.quit()
            throw error
        }
        await session.quit()
    }
}
