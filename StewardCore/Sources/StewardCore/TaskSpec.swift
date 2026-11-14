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
