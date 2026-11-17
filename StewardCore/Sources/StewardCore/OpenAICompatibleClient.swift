import Foundation

/// Talks to any OpenAI-compatible chat completions endpoint: OpenRouter, a
/// provider directly, or (in the app) Steward's relay, which adds its own key.
public struct OpenAICompatibleClient: ModelClient {
    /// Sorted keys, so the same tools and history encode to the same bytes on
    /// every launch: Swift dictionaries otherwise come out in a random order,
    /// and the provider's prompt cache misses on every request.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    public var session: URLSession
    /// Tools the provider runs on its own servers, sent as given, such as
    /// Groq's `{"type":"browser_search"}`. When they are the only tools, the
    /// request requires one, so the model searches rather than guesses.
    public var builtInTools: [JSONValue]

    public init(baseURL: URL, model: String, apiKey: String? = nil, builtInTools: [JSONValue] = [], session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.builtInTools = builtInTools
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
        request.httpBody = try Self.encoder.encode(Request(model: model, system: system, messages: messages, tools: tools, builtIn: builtInTools))

        let started = Date()
        let label = "\(baseURL.host() ?? "?") \(model)\(builtInTools.isEmpty ? "" : " +search")"
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.log("\(label) failed after \(Self.seconds(since: started)): \(error)")
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Self.log("\(label) HTTP \(status) in \(Self.seconds(since: started))"
                 + ((200..<300).contains(status) ? "" : ": \(String(decoding: data.prefix(400), as: UTF8.self))"))
        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // Some providers (OpenRouter among them) answer 200 with an error
        // inside, for example when the account runs out of credit mid-stream.
        if decoded.choices == nil, let error = decoded.error {
            Self.log("\(label) error inside the 200 reply: \(error.code.map(String.init) ?? "?") \(error.message ?? "")")
            throw HTTPError(status: error.code ?? 502, body: error.message ?? String(decoding: data, as: UTF8.self))
        }
        guard let message = decoded.choices?.first?.message else { return AssistantTurn() }
        let calls = try (message.tool_calls ?? []).map { call in
            let args = call.function.arguments.isEmpty
                ? [:]
                : try JSONDecoder().decode([String: JSONValue].self, from: Data(call.function.arguments.utf8))
            return ToolCall(id: call.id, name: call.function.name, arguments: args)
        }
        return AssistantTurn(text: message.content, toolCalls: calls)
    }

    /// Debug builds only: one line per call in the Xcode console, so a pasted
    /// log shows which provider and model answered and how. Never the key or
    /// the owner's messages; an error reply's first 400 characters at most.
    static func log(_ line: String) {
        #if DEBUG
        print("[Steward AI] \(line)")
        #endif
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    // MARK: Wire format

    private struct Request: Encodable {
        let model: String
        let messages: [WireMessage]
        /// Left out when empty: some providers reject an empty tool list.
        let tools: [AnyTool]?
        let tool_choice: String?

        init(model: String, system: String, messages: [ModelMessage], tools: [ToolSpec], builtIn: [JSONValue] = []) {
            self.model = model
            self.messages = [WireMessage(role: "system", content: system)] + messages.map(WireMessage.init)
            let all = tools.map { AnyTool.function(WireTool(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters))) }
                + builtIn.map(AnyTool.builtIn)
            self.tools = all.isEmpty ? nil : all
            tool_choice = tools.isEmpty && !builtIn.isEmpty ? "required" : nil
        }
    }

    private enum AnyTool: Encodable {
        case function(WireTool)
        case builtIn(JSONValue)
        func encode(to encoder: Encoder) throws {
            switch self {
            case .function(let tool): try tool.encode(to: encoder)
            case .builtIn(let value): try value.encode(to: encoder)
            }
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
                        let args = (try? OpenAICompatibleClient.encoder.encode(call.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
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
        var choices: [Choice]?
        var error: ErrorBody?
        struct ErrorBody: Decodable {
            var code: Int?
            var message: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // Usually a number, sometimes a string like "429".
                code = (try? c.decode(Int.self, forKey: .code)) ?? (try? c.decode(String.self, forKey: .code)).flatMap(Int.init)
                message = try? c.decode(String.self, forKey: .message)
            }
            enum CodingKeys: String, CodingKey { case code, message }
        }
        struct Choice: Decodable { var message: Message }
        struct Message: Decodable {
            var content: String?
            var tool_calls: [WireCall]?
        }
    }
}
