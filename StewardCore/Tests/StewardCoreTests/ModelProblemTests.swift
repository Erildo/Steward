import Foundation
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
    #expect(model.message(in: .feed).contains("\"foo/bar\""))

    let credit = ModelProblem(kind: .noCredit, provider: "OpenRouter")
    #expect(credit.message(in: .feed).contains("even with a free model"))
    #expect(credit.message(in: .conversation).hasSuffix("write again to retry."))

    #expect(ModelProblem(kind: .providerDown, provider: "OpenRouter").message(in: .feed).contains("nothing on your side"))
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
