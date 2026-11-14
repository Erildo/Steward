import CryptoKit
import Foundation

// The phone's side of the relay (docs/adr/0001, 0002). The relay keeps no
// readable mail: it seals each company reply to this phone's public key, and
// only the private key, which never leaves the device, opens it.

// MARK: Keys and envelopes

/// This phone's key pair for relay mail. The private key belongs in the
/// Keychain; `rawRepresentation` is what to store.
public struct RelayKeys: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(_ privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try .init(rawRepresentation: rawRepresentation)
    }

    /// What the relay seals to: 32 bytes, base64.
    public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
}

/// Mail sealed by the relay. Mirrors `Envelope` in relay/src/crypto.ts:
/// X25519 with an ephemeral key, HKDF-SHA256 (salt: ephemeral public key then
/// ours), AES-256-GCM with the tag after the ciphertext.
public struct RelayEnvelope: Codable, Sendable, Equatable {
    public var v: Int
    public var alg: String
    public var epk: String
    public var nonce: String
    public var ct: String

    static let info = Data("steward-relay-mail-v1".utf8)
    static let algorithm = "X25519-HKDF-SHA256-AES256GCM"

    public struct Unreadable: Error {}

    public func open(with keys: RelayKeys) throws -> RelayMail {
        guard v == 1, alg == Self.algorithm,
              let epkData = Data(base64Encoded: epk), let nonceData = Data(base64Encoded: nonce), let sealed = Data(base64Encoded: ct)
        else { throw Unreadable() }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epkData)
        let secret = try keys.privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: epkData + keys.privateKey.publicKey.rawRepresentation,
            sharedInfo: Self.info,
            outputByteCount: 32
        )
        let box = try AES.GCM.SealedBox(combined: nonceData + sealed)
        let plain = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(RelayMail.self, from: plain)
    }
}

/// What the relay sealed: the email as received, and the DKIM verdict our
/// receiving server gave it. Mirrors `SealedMail` in relay/src/relay.ts.
public struct RelayMail: Codable, Sendable, Equatable {
    public struct Dkim: Codable, Sendable, Equatable {
        public var pass: [String]
        public var authservId: String?
    }
    public var v: Int
    public var caseId: String
    public var receivedAt: String
    public var envelopeFrom: String
    public var dkim: Dkim
    /// The whole message (RFC 5322), base64.
    public var raw: String

    /// The email as a case keeps it.
    public func email(to caseAddress: String) -> CaseFile.Email {
        let message = MIMEMessage(Data(base64Encoded: raw) ?? Data())
        let received = (try? Date(receivedAt, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(receivedAt, strategy: .iso8601)) ?? .now
        return CaseFile.Email(
            direction: .incoming,
            date: message.date ?? received,
            from: message.fromAddress ?? envelopeFrom,
            to: caseAddress,
            subject: message.subject,
            body: message.text,
            dkimPass: dkim.pass
        )
    }
}

// MARK: Reading an email

/// Just enough of an email to hand to the agent: who sent it, the subject, the
/// date and the plain text. HTML-only mail is reduced to its text.
public struct MIMEMessage: Sendable {
    public var headers: [(name: String, value: String)]
    public var text: String

    public init(_ data: Data) {
        let (headers, body) = Self.split(data)
        self.headers = headers
        text = Self.text(headers: headers, body: body)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var subject: String { Self.decodeWords(header("Subject") ?? "") }

    /// The address in From, without the display name.
    public var fromAddress: String? {
        guard let from = header("From") else { return nil }
        if let open = from.lastIndex(of: "<"), let close = from.lastIndex(of: ">"), open < close {
            return String(from[from.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        let bare = from.trimmingCharacters(in: .whitespaces)
        return bare.contains("@") ? bare.lowercased() : nil
    }

    public var date: Date? {
        guard var value = header("Date") else { return nil }
        if let paren = value.firstIndex(of: "(") { value = String(value[..<paren]) }
        value = value.trimmingCharacters(in: .whitespaces)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let date = f.date(from: value) { return date }
        }
        return nil
    }

    // MARK: Parts

    /// Headers (unfolded) and the body, split at the first empty line.
    static func split(_ data: Data) -> ([(name: String, value: String)], Data) {
        let bytes = [UInt8](data)
        var end = bytes.count, bodyStart = bytes.count
        var i = 0
        while i < bytes.count {
            if bytes[i] == 10 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { end = i; bodyStart = i + 2; break }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { end = i; bodyStart = i + 3; break }
            }
            i += 1
        }
        let head = String(decoding: bytes[0..<end], as: UTF8.self)
        var headers: [(String, String)] = []
        for line in head.components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return (headers, Data(bytes[min(bodyStart, bytes.count)...]))
    }

    /// `text/plain; charset="utf-8"` as ("text/plain", ["charset": "utf-8"]).
    static func contentType(_ headers: [(name: String, value: String)]) -> (String, [String: String]) {
        let value = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "text/plain"
        var parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts.isEmpty ? "text/plain" : parts.removeFirst().lowercased()
        var params: [String: String] = [:]
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            params[key] = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (type, params)
    }

    static func text(headers: [(name: String, value: String)], body: Data) -> String {
        let (type, params) = contentType(headers)
        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            let parts = multipart(body, boundary: boundary).map(split)
            // Prefer plain text anywhere in the tree, then HTML.
            for part in parts where contentType(part.0).0 == "text/plain" || contentType(part.0).0.hasPrefix("multipart/") {
                let text = Self.text(headers: part.0, body: part.1)
                if !text.isEmpty { return text }
            }
            for part in parts where contentType(part.0).0 == "text/html" {
                return Self.text(headers: part.0, body: part.1)
            }
            return ""
        }
        guard type.hasPrefix("text/") else { return "" }
        let encoding = headers.first { $0.name.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame }?.value.lowercased() ?? "7bit"
        let decoded: Data = switch encoding {
        case "base64": Data(base64Encoded: String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }) ?? Data()
        case "quoted-printable": quotedPrintable(body, underscoreIsSpace: false)
        default: body
        }
        let text = string(decoded, charset: params["charset"])
        return type == "text/html" ? stripHTML(text) : text
    }

    static func multipart(_ body: Data, boundary: String) -> [Data] {
        let text = String(decoding: body, as: UTF8.self)
        let marker = "--" + boundary
        var parts: [Data] = []
        for chunk in text.components(separatedBy: marker).dropFirst() {
            if chunk.hasPrefix("--") { break }
            var part = Substring(chunk)
            if part.hasPrefix("\r\n") { part = part.dropFirst(2) } else if part.hasPrefix("\n") { part = part.dropFirst() }
            if part.hasSuffix("\r\n") { part = part.dropLast(2) } else if part.hasSuffix("\n") { part = part.dropLast() }
            parts.append(Data(part.utf8))
        }
        return parts
    }

    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: b - 48
            case 65...70: b - 55
            case 97...102: b - 87
            default: nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 { // "="
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(underscoreIsSpace && b == 95 ? 32 : b)
            i += 1
        }
        return Data(out)
    }

    static func string(_ data: Data, charset: String?) -> String {
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1", "iso8859-1": String(data: data, encoding: .isoLatin1) ?? ""
        case "windows-1252", "cp1252": String(data: data, encoding: .windowsCP1252) ?? ""
        default: String(decoding: data, as: UTF8.self)
        }
    }

    /// RFC 2047 encoded words in a header: =?charset?B|Q?text?=
    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/
        var out = ""
        var rest = Substring(value)
        var lastWasWord = false
        while let match = rest.firstMatch(of: pattern) {
            let gap = rest[..<match.range.lowerBound]
            // Whitespace between two encoded words is not part of the text.
            if !(lastWasWord && gap.allSatisfy(\.isWhitespace)) { out += gap }
            let raw = Data(match.output.3.utf8)
            let bytes = match.output.2.uppercased() == "B" ? (Data(base64Encoded: String(match.output.3)) ?? Data()) : quotedPrintable(raw, underscoreIsSpace: true)
            out += string(bytes, charset: String(match.output.1))
            rest = rest[match.range.upperBound...]
            lastWasWord = true
        }
        return out + rest
    }

    static func stripHTML(_ html: String) -> String {
        var text = html.replacing(/<(script|style)[^>]*>[\s\S]*?<\/\1>/.ignoresCase(), with: "")
        text = text.replacing(/<(br|\/p|\/div|\/li|\/tr|\/h[1-6])[^>]*>/.ignoresCase(), with: "\n")
        text = text.replacing(/<[^>]+>/, with: "")
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacing(/\n{3,}/, with: "\n\n")
    }
}

// MARK: Talking to the relay

public struct RelayError: Error, Equatable, CustomStringConvertible {
    public var status: Int
    public var message: String
    public var description: String { "Relay \(status): \(message)" }
}

/// The relay's HTTP API (relay/src/relay.ts). One per phone, holding the token
/// it got when it registered.
public struct RelayClient: Sendable {
    public var baseURL: URL
    public var token: String
    var session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public struct Registration: Decodable, Sendable { public var deviceId: String; public var token: String }
    public struct OpenedCase: Decodable, Sendable { public var caseId: String; public var address: String }
    public struct SendResult: Decodable, Sendable, Equatable { public var status: String; public var messageId: String?; public var duplicate: Bool }
    public struct InboxItem: Decodable, Sendable { public var id: String; public var caseId: String; public var envelope: RelayEnvelope }

    /// Registers this phone. The token in the answer is shown once: keep it in the Keychain.
    public static func register(baseURL: URL, keys: RelayKeys, pushToken: String? = nil, invite: String? = nil, session: URLSession = .shared) async throws -> Registration {
        var body: [String: String] = ["publicKey": keys.publicKeyBase64]
        if let pushToken { body["pushToken"] = pushToken }
        var request = URLRequest(url: baseURL.appending(path: "v1/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let invite { request.setValue(invite, forHTTPHeaderField: "x-steward-invite") }
        request.httpBody = try JSONEncoder().encode(body)
        return try await decode(Registration.self, from: session.data(for: request))
    }

    public func openCase() async throws -> OpenedCase {
        try await call("POST", "v1/cases", as: OpenedCase.self)
    }

    public func closeCase(_ caseID: String) async throws {
        _ = try await call("DELETE", "v1/cases/\(caseID)", as: Ok.self)
    }

    /// A visible notification at `date`. The relay learns only the case and the time.
    public func setWake(_ caseID: String, at date: Date) async throws {
        _ = try await call("PUT", "v1/cases/\(caseID)/wake", body: ["at": Int((date.timeIntervalSince1970 * 1000).rounded())], as: Ok.self)
    }

    public func clearWake(_ caseID: String) async throws {
        _ = try await call("DELETE", "v1/cases/\(caseID)/wake", as: Ok.self)
    }

    public func setPushToken(_ pushToken: String?) async throws {
        _ = try await call("PUT", "v1/devices/push", body: ["pushToken": pushToken as Any], as: Ok.self)
    }

    public func inbox() async throws -> [InboxItem] {
        struct Page: Decodable { var items: [InboxItem] }
        return try await call("GET", "v1/inbox", as: Page.self).items
    }

    /// Tells the relay the phone has saved these, so it deletes them.
    public func ack(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await call("POST", "v1/inbox/ack", body: ["ids": ids], as: Deleted.self)
    }

    public func send(_ email: CaseFile.Email, relayCaseID: String, fromName: String?) async throws -> SendResult {
        guard let sendID = email.sendID else { throw RelayError(status: 0, message: "An email needs a send ID before it goes to the relay.") }
        var body: [String: Any] = ["sendId": sendID, "caseId": relayCaseID, "to": email.to, "subject": email.subject, "body": email.body]
        if let fromName, !fromName.isEmpty { body["fromName"] = fromName }
        return try await call("POST", "v1/send", body: body, as: SendResult.self)
    }

    // MARK: Plumbing

    private struct Ok: Decodable {}
    private struct Problem: Decodable { var error: String }
    private struct Deleted: Decodable { var deleted: Int }

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await Self.decode(type, from: session.data(for: request))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from result: (Data, URLResponse)) throws -> T {
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(Problem.self, from: data))?.error ?? "No details."
            throw RelayError(status: status, message: message)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Sends approved emails through the relay, from the case's own address.
public struct RelayMailer: MailSender {
    public var client: RelayClient

    public init(client: RelayClient) {
        self.client = client
    }

    public struct NotOnRelay: Error {}

    public func send(_ email: CaseFile.Email, in file: CaseFile) async throws {
        guard let relayCaseID = file.relayCaseID else { throw NotOnRelay() }
        _ = try await client.send(email, relayCaseID: relayCaseID, fromName: file.owner.name)
    }
}

/// Collects sealed mail from the relay and opens it on the phone.
public struct RelayInbox: Sendable {
    public var client: RelayClient
    public var keys: RelayKeys

    public init(client: RelayClient, keys: RelayKeys) {
        self.client = client
        self.keys = keys
    }

    public struct Delivery: Sendable {
        /// Ack this with the relay once the case is saved.
        public var itemID: String
        public var relayCaseID: String
        public var mail: RelayMail
    }

    /// What's waiting. An envelope this phone can't open is returned in
    /// `unreadable` so the caller can ack and drop it, rather than fetch it forever.
    public func fetch() async throws -> (deliveries: [Delivery], unreadable: [String]) {
        var deliveries: [Delivery] = []
        var unreadable: [String] = []
        for item in try await client.inbox() {
            if let mail = try? item.envelope.open(with: keys), mail.caseId == item.caseId {
                deliveries.append(Delivery(itemID: item.id, relayCaseID: item.caseId, mail: mail))
            } else {
                unreadable.append(item.id)
            }
        }
        return (deliveries, unreadable)
    }
}
