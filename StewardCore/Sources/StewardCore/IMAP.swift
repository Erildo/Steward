import Foundation

// Just enough IMAP (RFC 9051, compatible with IMAP4rev1) to look for a
// company's reply in the owner's own inbox at a check-in: log in with an app
// password, select INBOX, search, fetch one message, log out. Read-only:
// fetches use BODY.PEEK, so nothing is marked read (docs/adr/0003).

/// The byte stream to the server. `receive` returns empty data once closed.
public protocol IMAPTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public struct IMAPError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: Sendable, Equatable {
        /// The server said NO or BAD, such as a wrong app password.
        case rejected
        case closed
        case malformed
        case timeout
    }
    public var kind: Kind
    public var message: String
    public var description: String { message }

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// One server response line, with the literals (`{n}` blocks) it carried.
/// Each literal stays in `text` as its `{n}` marker.
public struct IMAPResponse: Sendable, Equatable {
    public var text: String
    public var literals: [Data]
}

/// Splits the server's bytes into responses, waiting for more bytes when a
/// line or a literal isn't complete yet.
public struct IMAPReader: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(contentsOf: data) }

    public mutating func next() -> IMAPResponse? {
        var text: [UInt8] = []
        var literals: [Data] = []
        var index = 0
        while true {
            guard let end = Self.crlf(in: buffer, from: index) else { return nil }
            let line = Array(buffer[index..<end])
            text += line
            index = end + 2
            guard let size = Self.literalSize(line) else { break }
            guard buffer.count - index >= size else { return nil }
            literals.append(Data(buffer[index..<(index + size)]))
            index += size
        }
        buffer.removeFirst(index)
        return IMAPResponse(text: String(decoding: text, as: UTF8.self), literals: literals)
    }

    private static func crlf(in bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i + 1 < bytes.count {
            if bytes[i] == 13, bytes[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// `n` when the line ends with `{n}` (or the non-synchronising `{n+}`).
    static func literalSize(_ line: [UInt8]) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = String(decoding: line[(open + 1)..<(line.count - 1)], as: UTF8.self)
        if digits.hasSuffix("+") { digits.removeLast() }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let size = Int(digits), size >= 0 else { return nil }
        return size
    }
}

/// A logged-in conversation with one IMAP server.
public actor IMAPSession {
    private let transport: any IMAPTransport
    private var reader = IMAPReader()
    private var tags = 0

    public init(transport: any IMAPTransport) {
        self.transport = transport
    }

    /// Reads the server's first line, which must be OK.
    public func greeting() async throws {
        let first = try await readResponse()
        guard first.text.hasPrefix("* OK") || first.text.hasPrefix("* PREAUTH") else {
            throw IMAPError(.rejected, "The mail server didn't accept the connection.")
        }
    }

    public func login(user: String, password: String) async throws {
        do {
            _ = try await command("LOGIN \(try Self.quoted(user)) \(try Self.quoted(password))")
        } catch let error as IMAPError where error.kind == .rejected {
            throw IMAPError(.rejected, "The mail server didn't accept that address and app password.")
        }
    }

    /// Opens INBOX read-only. Returns its UIDVALIDITY and UIDNEXT, when given.
    public func examineInbox() async throws -> (uidValidity: UInt32?, uidNext: UInt32?) {
        let responses = try await command("EXAMINE INBOX")
        return (Self.code("UIDVALIDITY", in: responses), Self.code("UIDNEXT", in: responses))
    }

    /// `UID SEARCH` with criteria the caller has already made safe.
    public func search(_ criteria: String) async throws -> [UInt32] {
        let responses = try await command("UID SEARCH \(criteria)")
        return responses
            .filter { $0.text.hasPrefix("* SEARCH") }
            .flatMap { $0.text.dropFirst("* SEARCH".count).split(separator: " ").compactMap { UInt32($0) } }
    }

    /// The first `maxBytes` of one message, without marking it read.
    public func fetch(uid: UInt32, maxBytes: Int) async throws -> Data? {
        let responses = try await command("UID FETCH \(uid) (BODY.PEEK[]<0.\(maxBytes)>)")
        return responses.first { $0.text.contains(" FETCH ") && !$0.literals.isEmpty }?.literals.first
    }

    public func logout() async {
        _ = try? await command("LOGOUT")
        await transport.close()
    }

    // MARK: Plumbing

    private func command(_ line: String) async throws -> [IMAPResponse] {
        tags += 1
        let tag = "S\(tags)"
        try await transport.send(Data("\(tag) \(line)\r\n".utf8))
        var untagged: [IMAPResponse] = []
        while true {
            let response = try await readResponse()
            guard response.text.hasPrefix(tag + " ") else {
                untagged.append(response)
                continue
            }
            let status = response.text.dropFirst(tag.count + 1)
            guard status.hasPrefix("OK") else { throw IMAPError(.rejected, String(status)) }
            return untagged
        }
    }

    private func readResponse() async throws -> IMAPResponse {
        while true {
            if let response = reader.next() { return response }
            let data = try await transport.receive()
            guard !data.isEmpty else { throw IMAPError(.closed, "The mail server closed the connection.") }
            reader.append(data)
        }
    }

    /// An IMAP quoted string. App passwords and addresses are plain ASCII;
    /// anything that can't be quoted safely is refused rather than sent.
    static func quoted(_ value: String) throws -> String {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw IMAPError(.malformed, "That address or app password has characters the mail server can't take.")
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A number from a response code such as `[UIDVALIDITY 3857529045]`.
    static func code(_ name: String, in responses: [IMAPResponse]) -> UInt32? {
        for response in responses {
            guard let range = response.text.range(of: "[\(name) ") else { continue }
            let digits = response.text[range.upperBound...].prefix { $0.isNumber }
            if let value = UInt32(digits) { return value }
        }
        return nil
    }
}
