import CryptoKit
import Foundation
import Testing
@testable import StewardCore

// The phone's side of the relay. Conformance/relay_envelope.json is written by
// relay/test/write-fixture.ts: mail the relay sealed, which this side must open.

private let conformance = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Conformance")

private struct EnvelopeFixture: Decodable {
    struct Expect: Decodable { var caseId, receivedAt, from, subject, date, body: String; var dkimPass: [String] }
    var privateKey: String
    var publicKey: String
    var envelope: RelayEnvelope
    var expect: Expect
}

private func fixture() throws -> EnvelopeFixture {
    try JSONDecoder().decode(EnvelopeFixture.self, from: Data(contentsOf: conformance.appending(path: "relay_envelope.json")))
}

// MARK: Envelopes

@Test func thePhoneOpensWhatTheRelaySealed() throws {
    let f = try fixture()
    let keys = try RelayKeys(rawRepresentation: try #require(Data(base64Encoded: f.privateKey)))
    #expect(keys.publicKeyBase64 == f.publicKey)

    let mail = try f.envelope.open(with: keys)
    #expect(mail.caseId == f.expect.caseId)
    #expect(mail.dkim.pass == f.expect.dkimPass)

    let email = mail.email(to: "case-7f3a2b9c4d@relay.steward.example")
    #expect(email.direction == .incoming)
    #expect(email.from == f.expect.from)
    #expect(email.subject == f.expect.subject)
    #expect(email.date == (try Date(f.expect.date, strategy: .iso8601)))
    #expect(email.body == f.expect.body, "plain text preferred over HTML, quoted-printable and soft breaks decoded")
    #expect(email.dkimPass == ["fitwerk.example"])
}

@Test func anotherKeyCannotOpenIt() throws {
    let f = try fixture()
    #expect(throws: (any Error).self) { try f.envelope.open(with: RelayKeys()) }
}

@Test func aTamperedEnvelopeIsRefused() throws {
    let f = try fixture()
    var envelope = f.envelope
    var bytes = [UInt8](try #require(Data(base64Encoded: envelope.ct)))
    bytes[3] ^= 0x01
    envelope.ct = Data(bytes).base64EncodedString()
    let keys = try RelayKeys(rawRepresentation: try #require(Data(base64Encoded: f.privateKey)))
    #expect(throws: (any Error).self) { try envelope.open(with: keys) }
}

// MARK: Reading email

@Test func emailWithoutADateUsesWhenItArrived() {
    let raw = Data("From: a@b.example\r\nSubject: Hi\r\n\r\nBody".utf8).base64EncodedString()
    let mail = RelayMail(v: 1, caseId: "c", receivedAt: "2026-11-12T08:30:05.000Z", envelopeFrom: "x@b.example", dkim: .init(pass: [], authservId: nil), raw: raw)
    #expect(mail.email(to: "case@relay.example").date == Date(timeIntervalSince1970: 1_794_472_205))
}

@Test func base64AndLatin1Bodies() {
    let base64 = MIMEMessage(Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\nV2lyIGJlc3TDpHRpZ2VuLg==\r\n".utf8))
    #expect(base64.text == "Wir bestätigen.")
    var latin = Data("Content-Type: text/plain; charset=ISO-8859-1\n\nK".utf8)
    latin.append(0xFC) // ü
    latin.append(contentsOf: Array("ndigung".utf8))
    #expect(MIMEMessage(latin).text == "Kündigung")
}

@Test func htmlOnlyMailIsReducedToText() {
    let message = MIMEMessage(Data("Content-Type: text/html\n\n<html><style>p{}</style><p>We confirm</p><p>the refund &amp; the date.</p></html>".utf8))
    #expect(message.text == "We confirm\nthe refund & the date.")
}

@Test func encodedWordsInHeaders() {
    #expect(MIMEMessage.decodeWords("=?UTF-8?Q?K=C3=BCndigung?= =?UTF-8?Q?_best=C3=A4tigt?=") == "Kündigung bestätigt")
    #expect(MIMEMessage.decodeWords("Re: =?iso-8859-1?q?R=FCckerstattung?= 77") == "Re: Rückerstattung 77")
    #expect(MIMEMessage(Data("From: \"Support\" <Help@Company.Example>\n\n".utf8)).fromAddress == "help@company.example")
}

// MARK: Proof needs the company's signature

private func caseWith(_ reply: CaseFile.Email) -> CaseFile {
    var file = gymCase()
    file.emails = [reply]
    return file
}

private func relayReply(_ body: String, dkim: [String]?) -> CaseFile.Email {
    CaseFile.Email(direction: .incoming, date: .now, from: "kundenservice@fitwerk.example", to: "case@relay.example", subject: "Re: Kündigung", body: body, dkimPass: dkim)
}

@Test func onlyASignedEmailCanProveDone() {
    let quote = "Wir bestätigen die Kündigung."
    #expect(Gate.checkEvidence(quote, in: caseWith(relayReply(quote, dkim: ["fitwerk.example"]))) == nil)
    #expect(Gate.checkEvidence(quote, in: caseWith(relayReply(quote, dkim: ["mail.fitwerk.example"]))) == nil)
    #expect(Gate.checkEvidence(quote, in: caseWith(relayReply(quote, dkim: nil))) == nil, "simulated mail has no verdict")

    let forged = Gate.checkEvidence(quote, in: caseWith(relayReply(quote, dkim: [])))
    #expect(forged?.contains("wasn't signed by fitwerk.example") == true)
    #expect(Gate.checkEvidence(quote, in: caseWith(relayReply(quote, dkim: ["fitwerk-billing.example", "example"]))) != nil)
}

// MARK: The client

/// Answers requests from a table, and keeps what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.bodies.append(data)
        } else {
            Self.bodies.append(request.httpBody ?? Data())
        }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        let (status, body) = Self.answers[key] ?? (404, #"{"error":"Not found"}"#)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct RelayClientTests {
    init() {
        StubProtocol.answers = [:]
        StubProtocol.requests = []
        StubProtocol.bodies = []
    }

    let base = URL(string: "https://relay.test")!

    @Test func registersWithThePublicKeyOnly() async throws {
        StubProtocol.answers["POST /v1/devices"] = (201, #"{"deviceId":"d1","token":"t1"}"#)
        let keys = RelayKeys()
        let registration = try await RelayClient.register(baseURL: base, keys: keys, invite: "letmein", session: StubProtocol.session())
        #expect(registration.token == "t1")
        let sent = try JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: String]
        #expect(sent == ["publicKey": keys.publicKeyBase64])
        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "x-steward-invite") == "letmein")
    }

    @Test func sendsTheApprovedEmailWithItsSendID() async throws {
        StubProtocol.answers["POST /v1/send"] = (200, #"{"status":"sent","messageId":"m1","duplicate":false}"#)
        var file = gymCase()
        file.relayCaseID = "rc1"
        var email = CaseFile.Email(direction: .outgoing, date: .now, from: file.owner.caseAddress, to: "kundenservice@fitwerk.example", subject: "Kündigung", body: "Bitte kündigen.")
        email.sendID = "s-1"
        try await RelayMailer(client: RelayClient(baseURL: base, token: "t1", session: StubProtocol.session())).send(email, in: file)

        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "authorization") == "Bearer t1")
        let sent = try #require(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: String])
        #expect(sent == ["sendId": "s-1", "caseId": "rc1", "to": "kundenservice@fitwerk.example", "subject": "Kündigung", "body": "Bitte kündigen.", "fromName": "Lena Hoffmann"])
    }

    @Test func aCaseNotOnTheRelayCannotSend() async {
        var email = CaseFile.Email(direction: .outgoing, date: .now, from: "", to: "a@b.example", subject: "S", body: "B")
        email.sendID = "s-1"
        await #expect(throws: RelayMailer.NotOnRelay.self) {
            try await RelayMailer(client: RelayClient(baseURL: base, token: "t", session: StubProtocol.session())).send(email, in: gymCase())
        }
    }

    @Test func relayErrorsKeepTheirMessage() async {
        StubProtocol.answers["POST /v1/cases"] = (401, #"{"error":"Unknown token"}"#)
        await #expect(throws: RelayError(status: 401, message: "Unknown token")) {
            _ = try await RelayClient(baseURL: base, token: "bad", session: StubProtocol.session()).openCase()
        }
    }

    @Test func wakesSendOnlyTheTime() async throws {
        StubProtocol.answers["PUT /v1/cases/rc1/wake"] = (200, #"{"ok":true}"#)
        try await RelayClient(baseURL: base, token: "t", session: StubProtocol.session()).setWake("rc1", at: Date(timeIntervalSince1970: 1_794_268_800))
        let sent = try JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Int]
        #expect(sent == ["at": 1_794_268_800_000])
    }

    @Test func theInboxOpensWhatItCanAndSetsAsideWhatItCannot() async throws {
        let f = try fixture()
        let envelope = String(decoding: try JSONEncoder().encode(f.envelope), as: UTF8.self)
        StubProtocol.answers["GET /v1/inbox"] = (200, #"{"items":[{"id":"i1","caseId":"\#(f.expect.caseId)","envelope":\#(envelope),"receivedAt":1},{"id":"i2","caseId":"other","envelope":\#(envelope),"receivedAt":2}]}"#)
        let keys = try RelayKeys(rawRepresentation: try #require(Data(base64Encoded: f.privateKey)))
        let inbox = RelayInbox(client: RelayClient(baseURL: base, token: "t", session: StubProtocol.session()), keys: keys)
        let (deliveries, unreadable) = try await inbox.fetch()
        #expect(deliveries.map(\.itemID) == ["i1"])
        #expect(unreadable == ["i2"], "an envelope claiming another case is set aside")
    }
}
