import Foundation

/// One turn of Steward's general work: call the model, run any side tools it
/// asks for (`remember`, …), give it the results, and stop when it calls a
/// tool that ends the turn or answers in plain words. The app turns the
/// outcome into messages and task state.
///
/// Rules held in code, not in the prompt:
/// - a model may file a **fact** only when the owner's own message started
///   this turn; anything else it remembers is kept as a guess;
/// - after `maxSteps` model calls the turn stops (`.stuck`), so a model that
///   never ends can't spin or spend without limit.
public struct TaskLoop: Sendable {
    public struct Outcome: Sendable, Equatable {
        public enum End: Sendable, Equatable {
            /// A tool from `TaskSpec.finalTools`, or nil for plain words.
            case call(ToolCall?, text: String)
            case stuck
        }
        public var end: End
        /// What the model asked to keep this turn, as kept in the working copy.
        /// Apply these with `Memory.remember` to the live memory, never the
        /// copy itself: the owner may have forgotten something meanwhile.
        public var kept: [Memory.Item]
    }

    public let model: any ModelClient
    public let maxSteps: Int

    public init(model: any ModelClient, maxSteps: Int = 6) {
        self.model = model
        self.maxSteps = maxSteps
    }

    /// The tools offered: the ones that end a turn, plus `remember` when there is memory.
    public static func tools(withMemory: Bool) -> [ToolSpec] {
        var names = TaskSpec.finalTools
        if withMemory { names.insert("remember") }
        return TaskSpec.toolSpecs(only: names)
    }

    public func run(messages start: [ModelMessage], memory: inout Memory?, ownerJustSpoke: Bool) async throws -> Outcome {
        var messages = start
        var kept: [Memory.Item] = []
        let tools = Self.tools(withMemory: memory != nil)
        for _ in 0..<maxSteps {
            let turn = try await model.complete(system: TaskSpec.system, messages: messages, tools: tools)
            let final = turn.toolCalls.first { TaskSpec.finalTools.contains($0.name) }
            let side = turn.toolCalls.filter { !TaskSpec.finalTools.contains($0.name) }
            // Side tools run even when the turn also ends, so a fact said
            // alongside the answer is still kept.
            var results: [(String, String)] = []
            for call in side {
                let (result, note) = Self.run(call, memory: &memory, ownerJustSpoke: ownerJustSpoke)
                if let note { kept.append(note) }
                results.append((call.id, result))
            }
            if final != nil || side.isEmpty {
                let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Outcome(end: .call(final, text: text), kept: kept)
            }
            messages.append(.assistant(text: turn.text, toolCalls: side))
            for (id, result) in results { messages.append(.tool(callID: id, content: result)) }
        }
        return Outcome(end: .stuck, kept: kept)
    }

    static func run(_ call: ToolCall, memory: inout Memory?, ownerJustSpoke: Bool) -> (String, Memory.Item?) {
        func argument(_ key: String) -> String { call.arguments[key]?.string ?? "" }
        switch call.name {
        case "remember":
            guard memory != nil else { return ("Memory isn't available.", nil) }
            let asFact = argument("kind") == "fact" && ownerJustSpoke
            let item = Memory.Item(
                text: argument("text"),
                kind: asFact ? .fact : .guess,
                source: .task,
                evidence: argument("evidence").isEmpty ? "From a task" : argument("evidence"),
                confidence: Memory.Confidence(rawValue: argument("confidence")) ?? .hunch,
                topic: argument("topic").isEmpty ? nil : argument("topic"))
            switch memory!.remember(item) {
            case .added(let added): return ("Kept as a \(added.kind.rawValue).", added)
            case .alreadyKnown(let known):
                // A fact repeating a guess promotes it: that counts as kept.
                return ("Already known.", asFact && known.kind == .fact ? item : nil)
            case .refused:
                return ("Not kept: it's empty, under a topic the owner turned off, or looks like a number that must never be kept.", nil)
            }
        default:
            return ("There is no tool called \(call.name).", nil)
        }
    }
}
