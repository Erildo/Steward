import Foundation

/// The spec for Steward's general work (anything that isn't a company case),
/// loaded from `TaskSpec/`:
///
/// - `task_system.txt`: the system prompt. It has no placeholders and never
///   changes between turns, so the model provider's prompt cache holds.
/// - `task_context.txt`: the first message of every turn, with `{name}`
///   placeholders: the date, the task and anything else that changes.
/// - `memory.json`: the headings memory is shown under.
/// - `task_tools.json`: the tools as the model sees them, as JSON Schema.
///   The tools that end a turn also get the optional `blocks` field
///   (`ReplyBlock.modelSchema`).
///
/// Kept apart from `Spec/` on purpose: `Spec/` is the errand agent the Stage 0
/// harness measures, and any change there marks its results out of date.
/// Like `Spec/`, nothing the model is told is written in Swift.
public enum TaskSpec {
    public struct Tool: Decodable, Sendable {
        public var name: String
        public var description: String
        public var parameters: JSONValue
    }

    public static let system: String = text("task_system.txt")
    public static let tools: [Tool] = decode("task_tools.json")

    /// The tools to offer, in file order; the ones that end a turn also take
    /// the optional `blocks`. `only` limits them to these names, so a tool the
    /// owner turned off is never offered rather than forbidden in the prompt.
    public static func toolSpecs(only names: Set<String>? = nil) -> [ToolSpec] {
        tools
            .filter { names?.contains($0.name) ?? true }
            .map { ToolSpec(name: $0.name, description: $0.description,
                            parameters: blockTools.contains($0.name) ? withBlocks($0.parameters) : $0.parameters) }
    }

    /// How memory is introduced to the model (`memory.json`).
    public struct MemoryWording: Decodable, Sendable {
        public var facts: String
        public var guesses: String
        public var offLimits: String
        public var nothing: String

        enum CodingKeys: String, CodingKey {
            case facts, guesses, nothing
            case offLimits = "off_limits"
        }
    }

    public static let memoryWording: MemoryWording = decode("memory.json")

    /// Tools that end the turn. Any other tool returns a result and the model
    /// carries on in the same turn.
    public static let finalTools: Set<String> = Set(["ask_owner", "finish", "wait", "hand_back"]).union(ActionProposal.tools)

    /// The tools that end a turn with words, which may carry blocks. A
    /// proposal draws its own card instead.
    public static var blockTools: Set<String> { finalTools.subtracting(ActionProposal.tools) }

    public static let contextTemplate: String = text("task_context.txt")

    /// Every `{name}` the context message expects.
    public static let placeholders = ["today", "goal", "memory", "topics"]

    /// The first message of a turn, its placeholders filled.
    public static func context(_ values: [String: String]) -> String {
        Spec.render(contextTemplate, values)
    }

    // MARK: The daily review

    /// The review's system prompt (`review_system.txt`). Stable, like
    /// `system`: the date and the owner's data go in the context message.
    public static let reviewSystem: String = text("review_system.txt")
    /// The review's one message, with `{name}` placeholders (`review_context.txt`).
    public static let reviewContextTemplate: String = text("review_context.txt")
    public static let reviewPlaceholders = ["now", "memory", "closed", "goals", "tasks", "chats", "calendar",
                                            "reminders", "stopped", "corrected"]

    /// Words for empty and unconnected sections of the review's context.
    public struct ReviewWording: Decodable, Sendable {
        public var none: String
        public var notConnected: String
        public var noTopics: String

        enum CodingKeys: String, CodingKey {
            case none
            case notConnected = "not_connected"
            case noTopics = "no_topics"
        }
    }

    public static let reviewWording: ReviewWording = decode("review_wording.json")

    /// The one tool the review answers with. Each insight's optional `chart`
    /// is the shared block schema narrowed to charts, so it can't drift from
    /// what Chat accepts.
    public static let reviewTool: ToolSpec = {
        let tool: Tool = decode("review_tool.json")
        return ToolSpec(name: tool.name, description: tool.description, parameters: withInsightChart(tool.parameters))
    }()

    /// Words that mark a sensitive topic (`topic_words.json`), so a finding
    /// the model forgot to label is still kept out when the topic is off.
    public static let topicWords: [String: [String]] = decode("topic_words.json")

    static func withInsightChart(_ parameters: JSONValue) -> JSONValue {
        guard case .object(let list) = ReplyBlock.modelSchema, case .object(var block)? = list["items"],
              case .object(var blockProperties)? = block["properties"] else { return parameters }
        let chartKeys: Set<String> = ["type", "title", "style", "unit", "points", "highlight", "target"]
        blockProperties = blockProperties.filter { chartKeys.contains($0.key) }
        blockProperties["type"] = .object(["type": .string("string"), "enum": .array([.string("chart")])])
        block["properties"] = .object(blockProperties)
        block["required"] = .array(["type", "style", "unit", "points"].map { .string($0) })
        block["description"] = .string("Optional. Real numbers from the context, drawn as a chart. Never estimates.")
        guard case .object(var schema) = parameters, case .object(var properties)? = schema["properties"],
              case .object(var insights)? = properties["insights"], case .object(var item)? = insights["items"],
              case .object(var itemProperties)? = item["properties"] else { return parameters }
        itemProperties["chart"] = .object(block)
        item["properties"] = .object(itemProperties)
        insights["items"] = .object(item)
        properties["insights"] = .object(insights)
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    static func withBlocks(_ parameters: JSONValue) -> JSONValue {
        guard case .object(var schema) = parameters, case .object(var properties)? = schema["properties"] else {
            return parameters
        }
        properties["blocks"] = ReplyBlock.modelSchema
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    private static let folder: URL = {
        guard let url = Bundle.module.url(forResource: "TaskSpec", withExtension: nil) else {
            preconditionFailure("The TaskSpec folder is missing from the StewardCore bundle.")
        }
        return url
    }()

    private static func data(_ name: String) -> Data {
        do { return try Data(contentsOf: folder.appending(path: name)) }
        catch { preconditionFailure("Can't read TaskSpec/\(name): \(error)") }
    }

    private static func text(_ name: String) -> String {
        let text = String(decoding: data(name), as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    private static func decode<T: Decodable>(_ name: String) -> T {
        do { return try JSONDecoder().decode(T.self, from: data(name)) }
        catch { preconditionFailure("TaskSpec/\(name) doesn't match what the core expects: \(error)") }
    }
}
