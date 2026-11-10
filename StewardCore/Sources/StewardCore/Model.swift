import Foundation

/// A JSON value, for tool arguments and schemas.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? {
        switch self {
        case .string(let v): v
        case .number(let v): v == v.rounded() ? String(Int(v)) : String(v)
        case .bool(let v): String(v)
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case .number(let v): Int(v)
        case .string(let v): Int(v)
        default: nil
        }
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: [String: JSONValue]

    public init(id: String, name: String, arguments: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One message in the agent's conversation with the model.
public enum ModelMessage: Codable, Sendable, Equatable {
    case user(String)
    case assistant(text: String?, toolCalls: [ToolCall])
    case tool(callID: String, content: String)
}

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
}

public struct AssistantTurn: Sendable, Equatable {
    public var text: String?
    public var toolCalls: [ToolCall]

    public init(text: String? = nil, toolCalls: [ToolCall] = []) {
        self.text = text
        self.toolCalls = toolCalls
    }
}

/// Anything that can think: a provider through the relay's proxy, a user's own
/// key, or a scripted stand-in for tests.
public protocol ModelClient: Sendable {
    func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn
}

/// Replays fixed turns. For tests and previews.
public actor ScriptedModelClient: ModelClient {
    private var turns: [AssistantTurn]
    public private(set) var calls = 0

    public init(_ turns: [AssistantTurn]) {
        self.turns = turns
    }

    public func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        calls += 1
        guard !turns.isEmpty else { throw ScriptExhausted() }
        return turns.removeFirst()
    }

    public struct ScriptExhausted: Error {}
}
