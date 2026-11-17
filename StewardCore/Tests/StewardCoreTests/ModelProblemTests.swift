import Foundation
import Synchronization
import Testing
@testable import StewardCore

private func http(_ status: Int, _ body: String = "") -> Error {
    OpenAICompatibleClient.HTTPError(status: status, body: body)
}

@Test func classifiesProviderErrors() {
    #expect(ModelProblem.kind(of: http(401)) == .keyRejected)
    #expect(ModelProblem.kind(of: http(403)) == .keyRejected)
    #expect(ModelProblem.kind(of: http(402, #"{"error":{"code":402,"message":"Insufficient credits"}}"#)) == .noCredit)
    #expect(ModelProblem.kind(of: http(400, #"{"error":{"message":"foo/bar is not a valid model ID"}}"#)) == .unknownModel)
    #expect(ModelProblem.kind(of: http(404, "No endpoints found for model foo/bar")) == .unknownModel)
    #expect(ModelProblem.kind(of: http(400, "messages must not be empty")) == .other)
    #expect(ModelProblem.kind(of: http(429)) == .rateLimited)
    #expect(ModelProblem.kind(of: http(503)) == .providerDown)
    #expect(ModelProblem.kind(of: URLError(.timedOut)) == .timedOut)
    #expect(ModelProblem.kind(of: URLError(.notConnectedToInternet)) == .offline)
    #expect(ModelProblem.kind(of: FeedComposer.NothingUsable(raw: "")) == .unusableReply)
    #expect(ModelProblem.kind(of: CancellationError()) == .other)
}

@Test func messagesNameTheProviderAndTheNextStep() {
    let key = ModelProblem(kind: .keyRejected, provider: "OpenRouter")
    #expect(key.message(in: .feed) == "OpenRouter turned down your AI key. Check your AI key.")
    #expect(key.message(in: .conversation).contains("Steward tab under AI › Your Own AI Key"))
    #expect(key.isFixedInKeySettings)

    let model = ModelProblem(kind: .unknownModel, provider: "OpenRouter", model: "foo/bar")
    #expect(model.message(in: .feed).contains("\"foo/bar\"") && model.message(in: .feed).contains("retired"))

    let credit = ModelProblem(kind: .noCredit, provider: "OpenRouter")
    #expect(credit.message(in: .feed).contains("even with a free model"))
    #expect(credit.message(in: .conversation).hasSuffix("write again to retry."))

    #expect(ModelProblem(kind: .providerDown, provider: "OpenRouter").message(in: .feed).contains("nothing on your side"))
}

/// On the key screen the fix is right there, so no message points elsewhere.
@Test func settingsMessagesStayOnTheKeyScreen() {
    let key = ModelProblem(kind: .keyRejected, provider: "Groq").message(in: .settings)
    #expect(key == "Groq turned down this key. Paste it again, and make sure it's a Groq key.")
    let model = ModelProblem(kind: .unknownModel, provider: "OpenRouter", model: "foo/bar").message(in: .settings)
    #expect(model.contains("\"foo/bar\"") && !model.contains("Steward tab"))
    #expect(ModelProblem(kind: .rateLimited, provider: "OpenRouter").message(in: .settings).contains("Check again in a minute"))
    #expect(ModelProblem(kind: .noCredit, provider: "OpenRouter").message(in: .settings).hasSuffix("then check again."))
}

/// OpenRouter can answer 200 with only an error inside; that must surface as
/// the error it is, not as an empty reply.
@Test func errorInsideASuccessfulReplyIsThrown() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ErrorBodyProtocol.self]
    let client = OpenAICompatibleClient(baseURL: URL(string: "https://example.test/v1")!, model: "m", session: URLSession(configuration: config))
    do {
        _ = try await client.complete(system: "s", messages: [.user("hi")], tools: [])
        Issue.record("expected an error")
    } catch let error as OpenAICompatibleClient.HTTPError {
        #expect(error.status == 402)
        #expect(ModelProblem.kind(of: error) == .noCredit)
    }
}

private final class ErrorBodyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"code":"402","message":"Insufficient credits"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Groq's search runs only when the request carries its tool; with no tools
/// of Steward's own, the request also requires a tool so the model searches.
@Test func builtInToolsAreSentAsGivenAndRequired() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CapturingProtocol.self]
    let client = OpenAICompatibleClient(baseURL: URL(string: "https://example.test/v1")!, model: "openai/gpt-oss-120b",
                                        builtInTools: [.object(["type": .string("browser_search")])],
                                        session: URLSession(configuration: config))
    let turn = try await client.complete(system: "s", messages: [.user("hi")], tools: [])
    #expect(turn.text == "ok")
    let body = try #require(CapturingProtocol.lastBody.withLock { $0 })
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((json["tools"] as? [[String: String]]) == [["type": "browser_search"]])
    #expect(json["tool_choice"] as? String == "required")
}

private final class CapturingProtocol: URLProtocol {
    static let lastBody = Mutex<Data?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = Data(); var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&chunk, maxLength: chunk.count); if n <= 0 { break }; buffer.append(chunk, count: n) }
            data = buffer
        }
        Self.lastBody.withLock { $0 = data }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
