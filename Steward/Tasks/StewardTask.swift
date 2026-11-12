import Foundation
import StewardCore

/// Anything the owner hands Steward: research, a plan, a comparison, a
/// reminder, a complaint. Each task keeps its own conversation, so ten tasks
/// never share one thread.
///
/// A company errand (emails and proof of the outcome) is one kind of work a
/// task can carry, through `caseID`; most tasks never need one.
struct StewardTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var goal: String
    var createdAt: Date = .now
    var messages: [Message] = []
    var state: State = .working
    /// What Steward came back with, once it's done.
    var result: String?
    /// A company case this task runs, when it needs one.
    var caseID: UUID?

    struct Message: Codable, Identifiable, Equatable {
        enum Author: String, Codable { case owner, steward }
        var id = UUID()
        var author: Author
        var text: String
        var date: Date = .now
    }

    /// Where the task stands. Every waiting state says who moves next.
    enum State: Codable, Equatable {
        /// Steward has the next move.
        case working
        /// Steward asked the owner something and waits for the answer.
        case needsAnswer(question: String)
        /// Steward comes back to it on a date.
        case waiting(until: Date, note: String)
        /// The owner has it now: Steward handed it back, or they took it over.
        case handedBack(note: String, date: Date)
        case done(date: Date, confirmedByOwner: Bool)
        case stopped(date: Date)
    }

    var isFinished: Bool {
        switch state {
        case .done, .stopped: true
        default: false
        }
    }

    var finishedAt: Date? {
        switch state {
        case .done(let date, _), .stopped(let date): date
        default: nil
        }
    }

    var isOverdue: Bool {
        if case .waiting(let until, _) = state { return until < .now }
        return false
    }

    /// One line on where it stands. `connected` is false while no model can work on it.
    func statusLine(connected: Bool) -> String {
        switch state {
        case .working:
            return connected ? "Steward is working on it" : "Waits for Steward to be connected"
        case .needsAnswer(let question):
            return "Steward asks: \(question)"
        case .waiting(let until, let note):
            let when = until < .now ? "was due back \(until.taskDay)" : "back \(until.taskDay)"
            return note.isEmpty ? "Steward is \(when)" : "\(note) · \(when)"
        case .handedBack(let note, let date):
            return "\(note) · \(date.taskDay)"
        case .done(let date, let confirmed):
            if confirmed { return "Confirmed by you · \(date.taskDay)" }
            if let result, let first = result.split(separator: "\n").first { return "Done: \(first)" }
            return "Done · \(date.taskDay)"
        case .stopped(let date):
            return "You stopped this · \(date.taskDay)"
        }
    }

    mutating func say(_ author: Message.Author, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(Message(author: author, text: text))
    }
}

/// What moves a Steward task forward.
enum TaskWake: Equatable {
    /// A new task, or picking it back up.
    case start
    /// The owner wrote in the task's thread (an answer, or anything else).
    case message
    /// A date Steward asked to come back on has passed.
    case timer
}

/// Works on a task and returns it with Steward's reply and new state.
protocol TaskAgent: Sendable {
    func work(on task: StewardTask, wake: TaskWake) async throws -> StewardTask
}

/// Keeps a list as one readable JSON file in the owner's documents.
struct JSONListStore<Item: Codable> {
    var url: URL

    func all() throws -> [Item] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Item].self, from: Data(contentsOf: url))
    }

    func save(_ items: [Item]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

// MARK: Agents

/// A real model working on a general task. It can think, research (when the
/// model searches the web) and draft; it can't act outside the phone yet, so
/// it tells the owner what to do or hands the step back.
struct ModelTaskAgent: TaskAgent {
    let model: any ModelClient

    private static let system = """
    You are Steward, a personal agent working for one person (the owner) on one task.
    You can think, research and draft. You cannot yet send messages, pay, sign in, book or change anything outside this conversation, so never claim you did. When a step needs that, say exactly what the owner should do, or hand it back.
    Be brief and concrete. Write in the owner's language. No jargon.
    End every turn with exactly one tool call:
    - ask_owner: you need something only the owner knows (one short question).
    - finish: the task is done; put the full answer in `result`.
    - wait: there's nothing to do until a later date (a reminder, a deadline).
    - hand_back: the rest needs the owner; say why and what to do.
    """

    private static let tools: [ToolSpec] = [
        ToolSpec(name: "ask_owner", description: "Ask the owner one short question and wait for the answer.",
                 parameters: schema(["question": "The question, in one sentence."])),
        ToolSpec(name: "finish", description: "The task is done. Give the owner the full result.",
                 parameters: schema(["result": "The answer, plan, shortlist or draft, ready to use."])),
        ToolSpec(name: "wait", description: "Come back to the task after some days.",
                 parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "days": .object(["type": .string("number"), "description": .string("Days from now.")]),
                        "note": .object(["type": .string("string"), "description": .string("What happens then, in a few words.")]),
                    ]),
                    "required": .array([.string("days"), .string("note")]),
                 ])),
        ToolSpec(name: "hand_back", description: "The rest needs the owner. Say why and what to do.",
                 parameters: schema(["reason": "Why, and the owner's next step."])),
    ]

    private static func schema(_ fields: [String: String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(fields.mapValues { .object(["type": .string("string"), "description": .string($0)]) }),
            "required": .array(fields.keys.map { .string($0) }),
        ])
    }

    func work(on task: StewardTask, wake: TaskWake) async throws -> StewardTask {
        var messages: [ModelMessage] = [.user("The task: \(task.goal)")]
        for message in task.messages {
            switch message.author {
            case .owner: messages.append(.user(message.text))
            case .steward: messages.append(.assistant(text: message.text, toolCalls: []))
            }
        }
        if wake == .timer { messages.append(.user("The date you waited for has come. Carry on.")) }

        let turn = try await model.complete(system: Self.system, messages: messages, tools: Self.tools)
        var next = task
        let call = turn.toolCalls.first
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func argument(_ key: String) -> String { call?.arguments[key]?.string ?? "" }

        switch call?.name {
        case "ask_owner":
            next.say(.steward, text)
            let question = argument("question").isEmpty ? text : argument("question")
            next.say(.steward, question)
            next.state = .needsAnswer(question: question)
        case "finish":
            let result = argument("result").isEmpty ? text : argument("result")
            next.say(.steward, result)
            next.result = result
            next.state = .done(date: .now, confirmedByOwner: false)
        case "wait":
            let days = call?.arguments["days"]?.int ?? 1
            next.say(.steward, text.isEmpty ? argument("note") : text)
            next.state = .waiting(until: .now.addingTimeInterval(Double(max(days, 1)) * 86_400), note: argument("note"))
        case "hand_back":
            let reason = argument("reason").isEmpty ? text : argument("reason")
            next.say(.steward, reason)
            next.state = .handedBack(note: "Over to you", date: .now)
        default:
            // A plain reply: treat it as a question back to the owner, so the
            // task never sits "working" with nothing to wake it.
            let reply = text.isEmpty ? "What should I do next?" : text
            next.say(.steward, reply)
            next.state = .needsAnswer(question: reply)
        }
        return next
    }
}

/// The stand-in for sample launches: asks one question, then comes back with
/// a placeholder result, so the whole flow can be tried without a model.
struct SampleTaskAgent: TaskAgent {
    func work(on task: StewardTask, wake: TaskWake) async throws -> StewardTask {
        try await Task.sleep(for: .seconds(1.2))
        var next = task
        switch (task.state, wake) {
        case (.working, .start):
            let question = "Before I start: anything I should know, like a budget, a date or a place?"
            next.say(.steward, question)
            next.state = .needsAnswer(question: question)
        case (.needsAnswer, .message), (.working, .message), (.waiting, .timer):
            let result = "Sample result for “\(task.goal)”. Steward's real answer lands here: what it found, what it suggests, and what's left for you. Nothing here is real."
            next.say(.steward, result)
            next.result = result
            next.state = .done(date: .now, confirmedByOwner: false)
        default:
            next.say(.steward, "Noted. (Sample reply.)")
        }
        return next
    }
}

extension StewardTask {
    /// Sample tasks for `-uiState tasks`, beside the sample errands.
    static func samples(now: Date = .now) -> [StewardTask] {
        func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86_400) }

        var dentist = StewardTask(goal: "Find a dentist near me that takes my insurance", createdAt: day(-0.2))
        dentist.messages = [
            .init(author: .owner, text: "Find a dentist near me that takes my insurance", date: day(-0.2)),
            .init(author: .steward, text: "Which insurer are you with, and which area should I search?", date: day(-0.19)),
        ]
        dentist.state = .needsAnswer(question: "Which insurer are you with, and which area should I search?")

        var lisbon = StewardTask(goal: "Plan 3 days in Lisbon in March", createdAt: day(-4))
        let plan = "A 3-day Lisbon plan: Alfama and the castle on day 1, Belém on day 2, Sintra by train on day 3. Book the Sintra palace tickets a week ahead."
        lisbon.messages = [
            .init(author: .owner, text: "Plan 3 days in Lisbon in March", date: day(-4)),
            .init(author: .steward, text: "Any must-sees, or a pace you prefer?", date: day(-4)),
            .init(author: .owner, text: "Relaxed, lots of food, one day trip.", date: day(-3.9)),
            .init(author: .steward, text: plan, date: day(-3.8)),
        ]
        lisbon.result = plan
        lisbon.state = .done(date: day(-3.8), confirmedByOwner: false)

        var plans = StewardTask(goal: "Compare my phone plan with the two cheapest SIM-only deals", createdAt: day(-0.05))
        plans.messages = [.init(author: .owner, text: "Compare my phone plan with the two cheapest SIM-only deals", date: day(-0.05))]
        plans.state = .working

        var insurance = StewardTask(goal: "Remind me before the car insurance renews", createdAt: day(-2))
        insurance.messages = [
            .init(author: .owner, text: "Remind me before the car insurance renews", date: day(-2)),
            .init(author: .steward, text: "It renews on 15 December. I'll come back two weeks before with cheaper quotes to compare.", date: day(-2)),
        ]
        insurance.state = .waiting(until: day(19), note: "Quotes before renewal")

        return [dentist, lisbon, plans, insurance]
    }
}
