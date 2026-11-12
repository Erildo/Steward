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
    /// Kept at the top of Chats. Optional so older files still read.
    var pinned: Bool?

    var isPinned: Bool { pinned ?? false }
    var lastActivity: Date { messages.last?.date ?? createdAt }

    struct Message: Codable, Identifiable, Equatable {
        enum Author: String, Codable { case owner, steward }
        var id = UUID()
        var author: Author
        var text: String
        var date: Date = .now
        /// Interface shown with Steward's words. Optional so older files still read.
        var blocks: [ReplyBlock]?

        var allBlocks: [ReplyBlock] { blocks ?? [] }
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

    /// Adds a message. A reply may be blocks alone; nothing at all is dropped.
    @discardableResult
    mutating func say(_ author: Message.Author, _ text: String, blocks: [ReplyBlock] = []) -> UUID? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !blocks.isEmpty else { return nil }
        let message = Message(author: author, text: text, blocks: blocks.isEmpty ? nil : blocks)
        messages.append(message)
        return message.id
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
    Every tool takes optional `blocks`: interface shown with your words on the owner's phone. Use one only when it saves typing or reading:
    - choices: when the answer is one of a few, offer up to 4 short answers to tap.
    - field: when you need one value (an email, a date, a number).
    - compare: 2 to 4 options side by side, marking your pick.
    - timeline: a plan in order (days, times, steps).
    - deadline: a date that matters and what happens around it.
    - checklist: things only the owner can do; they tick them off, and you'll see which are done.
    Never repeat a block's content in your words; say the one line that matters and let the block carry the rest.
    Short replies are one or two plain sentences. For a longer answer, use light Markdown: ## headings, - bullets, 1. numbered steps, **bold** for the few words that matter. No tables.
    """

    private static let tools: [ToolSpec] = [
        ToolSpec(name: "ask_owner", description: "Ask the owner one short question and wait for the answer.",
                 parameters: schema(["question": "The question, in one sentence."])),
        ToolSpec(name: "finish", description: "The task is done. Give the owner the full result.",
                 parameters: schema(["result": "The answer, plan, shortlist or draft, ready to use."])),
        ToolSpec(name: "wait", description: "Come back to the task after some days.",
                 parameters: schema(["note": "What happens then, in a few words."],
                                    extra: ["days": .object(["type": .string("number"), "description": .string("Days from now.")])])),
        ToolSpec(name: "hand_back", description: "The rest needs the owner. Say why and what to do.",
                 parameters: schema(["reason": "Why, and the owner's next step."])),
    ]

    /// Required string fields, any other required fields, and the optional blocks.
    private static func schema(_ fields: [String: String], extra: [String: JSONValue] = [:]) -> JSONValue {
        var properties = fields.mapValues { JSONValue.object(["type": .string("string"), "description": .string($0)]) }
        properties.merge(extra) { $1 }
        properties["blocks"] = ReplyBlock.modelSchema
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array((Array(fields.keys) + Array(extra.keys)).sorted().map { .string($0) }),
        ])
    }

    func work(on task: StewardTask, wake: TaskWake) async throws -> StewardTask {
        var messages: [ModelMessage] = [.user("The task: \(task.goal)")]
        for message in task.messages {
            switch message.author {
            case .owner: messages.append(.user(message.text))
            case .steward:
                // What was shown, in words, so the model knows what the owner saw and ticked.
                let shown = message.allBlocks.map(\.plainText)
                messages.append(.assistant(text: ([message.text] + shown).filter { !$0.isEmpty }.joined(separator: "\n"), toolCalls: []))
            }
        }
        if wake == .timer { messages.append(.user("The date you waited for has come. Carry on.")) }

        let turn = try await model.complete(system: Self.system, messages: messages, tools: Self.tools)
        var next = task
        let call = turn.toolCalls.first
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func argument(_ key: String) -> String { call?.arguments[key]?.string ?? "" }
        let blocks = ReplyBlock.fromModel(call?.arguments["blocks"])

        switch call?.name {
        case "ask_owner":
            let question = argument("question").isEmpty ? text : argument("question")
            if text != question { next.say(.steward, text) }
            next.say(.steward, question, blocks: blocks)
            next.state = .needsAnswer(question: question)
        case "finish":
            let result = argument("result").isEmpty ? text : argument("result")
            next.say(.steward, result, blocks: blocks)
            next.result = result
            next.state = .done(date: .now, confirmedByOwner: false)
        case "wait":
            let days = call?.arguments["days"]?.int ?? 1
            next.say(.steward, text.isEmpty ? argument("note") : text, blocks: blocks)
            next.state = .waiting(until: .now.addingTimeInterval(Double(max(days, 1)) * 86_400), note: argument("note"))
        case "hand_back":
            let reason = argument("reason").isEmpty ? text : argument("reason")
            next.say(.steward, reason, blocks: blocks)
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
            next.say(.steward, question, blocks: [.choices(.init(options: ["No, go ahead", "Keep it cheap", "It's urgent"]))])
            next.state = .needsAnswer(question: question)
        case (.needsAnswer, .message), (.working, .message), (.waiting, .timer):
            let (result, blocks) = Self.sampleResult(for: task.goal)
            next.say(.steward, result, blocks: blocks)
            next.result = result
            next.state = .done(date: .now, confirmedByOwner: false)
        default:
            next.say(.steward, "Noted. (Sample reply.)")
        }
        return next
    }

    /// A placeholder answer shaped like the real one would be: a comparison
    /// for "compare", a plan for "plan", words otherwise. Labeled as sample.
    static func sampleResult(for goal: String) -> (String, [ReplyBlock]) {
        let lower = goal.lowercased()
        if lower.contains("compare") || lower.contains("cheapest") || lower.contains("best price") {
            return ("Sample comparison: the middle one is my pick. Nothing here is real.", [
                .compare(.init(title: "Sample options", options: [
                    .init(name: "Option A", detail: "Cheapest, but a 24-month contract.", price: "£8/mo"),
                    .init(name: "Option B", detail: "Monthly rolling, cancel any time.", price: "£10/mo", isPick: true),
                    .init(name: "What you have", detail: "Same data, no contract left.", price: "£22/mo"),
                ])),
            ])
        }
        if lower.contains("plan") || lower.contains("trip") || lower.contains("days") {
            return ("Sample plan, in order. Nothing here is real.", [
                .timeline(.init(title: "Sample plan", items: [
                    .init(when: "First", title: "The thing that unblocks the rest", detail: "Book or confirm early."),
                    .init(when: "Then", title: "The main part"),
                    .init(when: "Last", title: "Wrap up", detail: "What to keep, and where."),
                ])),
            ])
        }
        return ("Sample result for “\(goal)”. Steward's real answer lands here: what it found, what it suggests, and what's left for you. Nothing here is real.", [])
    }
}

extension StewardTask {
    /// Sample tasks for `-uiState tasks`, beside the sample errands.
    static func samples(now: Date = .now) -> [StewardTask] {
        func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86_400) }

        var dentist = StewardTask(goal: "Find a dentist near me that takes my insurance", createdAt: day(-0.2))
        dentist.messages = [
            .init(author: .owner, text: "Find a dentist near me that takes my insurance", date: day(-0.2)),
            .init(author: .steward, text: "Which insurer are you with, and which area should I search?", date: day(-0.19), blocks: [
                .choices(.init(options: ["Near home", "Near work"])),
            ]),
        ]
        dentist.state = .needsAnswer(question: "Which insurer are you with, and which area should I search?")

        var lisbon = StewardTask(goal: "Plan 3 days in Lisbon in March", createdAt: day(-4))
        let plan = "A 3-day Lisbon plan: Alfama and the castle on day 1, Belém on day 2, Sintra by train on day 3. Book the Sintra palace tickets a week ahead."
        lisbon.messages = [
            .init(author: .owner, text: "Plan 3 days in Lisbon in March", date: day(-4)),
            .init(author: .steward, text: "Any must-sees, or a pace you prefer?", date: day(-4)),
            .init(author: .owner, text: "Relaxed, lots of food, one day trip.", date: day(-3.9)),
            .init(author: .steward, text: "Three relaxed days, one train trip. Book the Sintra palace a week ahead.", date: day(-3.8), blocks: [
                .timeline(.init(title: "3 days in Lisbon", items: [
                    .init(when: "Day 1", title: "Alfama and the castle", detail: "Lunch at a tasca, sunset at Miradouro de Santa Luzia."),
                    .init(when: "Day 2", title: "Belém", detail: "Pastéis de nata early, before the queue."),
                    .init(when: "Day 3", title: "Sintra by train", detail: "40 min from Rossio. Palace tickets a week ahead."),
                ])),
            ]),
        ]
        lisbon.result = plan
        lisbon.state = .done(date: day(-3.8), confirmedByOwner: false)

        var plans = StewardTask(goal: "Compare my phone plan with the two cheapest SIM-only deals", createdAt: day(-0.05))
        plans.messages = [.init(author: .owner, text: "Compare my phone plan with the two cheapest SIM-only deals", date: day(-0.05))]
        plans.state = .working

        var insurance = StewardTask(goal: "Remind me before the car insurance renews", createdAt: day(-2))
        insurance.messages = [
            .init(author: .owner, text: "Remind me before the car insurance renews", date: day(-2)),
            .init(author: .steward, text: "I'll come back two weeks before it renews, with cheaper quotes to compare.", date: day(-2), blocks: [
                .deadline(.init(title: "Renews in 21 days", progress: 0.94, rows: [
                    .init(label: "Quotes from Steward", value: day(19).formatted(.dateTime.month(.abbreviated).day())),
                    .init(label: "Renews automatically", value: day(21).formatted(.dateTime.month(.abbreviated).day())),
                ])),
            ]),
        ]
        insurance.state = .waiting(until: day(19), note: "Quotes before renewal")

        return [dentist, lisbon, plans, insurance]
    }
}
