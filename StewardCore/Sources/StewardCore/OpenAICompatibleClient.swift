import Foundation

/// Talks to any OpenAI-compatible chat completions endpoint: OpenRouter, a
/// provider directly, or (in the app) Steward's relay, which adds its own key.
public struct OpenAICompatibleClient: ModelClient {
    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    public var session: URLSession

    public init(baseURL: URL, model: String, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public struct HTTPError: Error, CustomStringConvertible {
        public var status: Int
        public var body: String
        public var description: String { "HTTP \(status): \(body.prefix(300))" }
    }

    public func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        // Web search plus writing can take well over the default minute.
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Request(model: model, system: system, messages: messages, tools: tools))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let message = decoded.choices.first?.message else { return AssistantTurn() }
        let calls = try (message.tool_calls ?? []).map { call in
            let args = call.function.arguments.isEmpty
                ? [:]
                : try JSONDecoder().decode([String: JSONValue].self, from: Data(call.function.arguments.utf8))
            return ToolCall(id: call.id, name: call.function.name, arguments: args)
        }
        return AssistantTurn(text: message.content, toolCalls: calls)
    }

    // MARK: Wire format

    private struct Request: Encodable {
        let model: String
        let messages: [WireMessage]
        /// Left out when empty: some providers reject an empty tool list.
        let tools: [WireTool]?

        init(model: String, system: String, messages: [ModelMessage], tools: [ToolSpec]) {
            self.model = model
            self.messages = [WireMessage(role: "system", content: system)] + messages.map(WireMessage.init)
            self.tools = tools.isEmpty ? nil : tools.map { WireTool(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters)) }
        }
    }

    private struct WireMessage: Encodable {
        var role: String
        var content: String?
        var tool_calls: [WireCall]?
        var tool_call_id: String?

        init(role: String, content: String?) {
            self.role = role
            self.content = content
        }

        init(_ message: ModelMessage) {
            switch message {
            case .user(let text):
                self.init(role: "user", content: text)
            case .assistant(let text, let calls):
                self.init(role: "assistant", content: text)
                if !calls.isEmpty {
                    tool_calls = calls.map { call in
                        let args = (try? JSONEncoder().encode(call.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        return WireCall(id: call.id, function: .init(name: call.name, arguments: args))
                    }
                }
            case .tool(let id, let content):
                self.init(role: "tool", content: content)
                tool_call_id = id
            }
        }
    }

    private struct WireCall: Codable {
        var id: String
        var type = "function"
        var function: Function
        struct Function: Codable {
            var name: String
            var arguments: String
        }
    }

    private struct WireTool: Encodable {
        var type = "function"
        var function: Function
        struct Function: Encodable {
            var name: String
            var description: String
            var parameters: JSONValue
        }
    }

    private struct Response: Decodable {
        var choices: [Choice]
        struct Choice: Decodable { var message: Message }
        struct Message: Decodable {
            var content: String?
            var tool_calls: [WireCall]?
        }
    }
}
