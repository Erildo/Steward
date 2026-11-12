import Foundation

/// A piece of interface inside one of Steward's replies, shown natively in
/// chat: tap-to-answer prompts, plans, comparisons, deadlines, drafts to
/// approve and proof that an errand is done.
///
/// Text stays the default. A block earns its place when it saves the owner a
/// tap or a misreading, and every block ends in a fact or an action.
///
/// On the wire each block is one JSON object with a `type` and that type's
/// fields, so stored threads stay readable.
public enum ReplyBlock: Codable, Sendable, Equatable {
    /// Up to four short answers the owner can tap instead of typing.
    case choices(Choices)
    /// One value the owner types in place, such as an email address.
    case field(Field)
    /// Where an errand stands, step by step.
    case steps(Steps)
    /// A date that matters and what happens around it.
    case deadline(Deadline)
    /// A message Steward will send only with the owner's yes.
    case draft(Draft)
    /// A few options side by side, with Steward's pick.
    case compare(Compare)
    /// A plan in order: days, times or steps.
    case timeline(Timeline)
    /// The outcome of an errand, with the company's own words.
    case proof(Proof)

    // MARK: Payloads

    public struct Choices: Codable, Sendable, Equatable {
        public var options: [String]
        public init(options: [String]) { self.options = options }
    }

    public struct Field: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case text, email, phone, number, date }
        /// What is asked for, as a label: "Membership email".
        public var label: String
        public var kind: Kind
        public var placeholder: String?
        public init(label: String, kind: Kind = .text, placeholder: String? = nil) {
            self.label = label
            self.kind = kind
            self.placeholder = placeholder
        }
    }

    public struct Steps: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable { case pending, active, waiting, done }
        public struct Step: Codable, Sendable, Equatable {
            public var title: String
            public var state: State
            public init(title: String, state: State = .pending) {
                self.title = title
                self.state = state
            }
        }
        public var title: String
        public var steps: [Step]
        public init(title: String, steps: [Step]) {
            self.title = title
            self.steps = steps
        }
    }

    public struct Row: Codable, Sendable, Equatable {
        public var label: String
        public var value: String
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Deadline: Codable, Sendable, Equatable {
        /// The headline, already in words: "6 days left to cancel".
        public var title: String
        /// How much of the window has passed, 0 to 1, when known.
        public var progress: Double?
        public var rows: [Row]
        public init(title: String, progress: Double? = nil, rows: [Row]) {
            self.title = title
            self.progress = progress
            self.rows = rows
        }
    }

    public struct Draft: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case pending, approved, declined }
        public var to: String
        public var subject: String
        public var body: String
        public var status: Status
        /// The company case this draft belongs to, when there is one.
        public var caseID: UUID?
        public init(to: String, subject: String, body: String, status: Status = .pending, caseID: UUID? = nil) {
            self.to = to
            self.subject = subject
            self.body = body
            self.status = status
            self.caseID = caseID
        }
    }

    public struct Compare: Codable, Sendable, Equatable {
        public struct Option: Codable, Sendable, Equatable {
            public var name: String
            public var detail: String
            public var price: String?
            public var isPick: Bool
            public init(name: String, detail: String, price: String? = nil, isPick: Bool = false) {
                self.name = name
                self.detail = detail
                self.price = price
                self.isPick = isPick
            }
        }
        public var title: String
        public var options: [Option]
        public init(title: String, options: [Option]) {
            self.title = title
            self.options = options
        }
    }

    public struct Timeline: Codable, Sendable, Equatable {
        public struct Item: Codable, Sendable, Equatable {
            /// "Day 1", "12:30", "Sat". Optional.
            public var when: String?
            public var title: String
            public var detail: String?
            public init(when: String? = nil, title: String, detail: String? = nil) {
                self.when = when
                self.title = title
                self.detail = detail
            }
        }
        public var title: String
        public var items: [Item]
        public init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public struct Proof: Codable, Sendable, Equatable {
        public var headline: String
        public var detail: String?
        /// The company's own words, quoted.
        public var quote: String?
        /// Who said it: the company's name or address.
        public var source: String?
        public var date: Date?
        public init(headline: String, detail: String? = nil, quote: String? = nil, source: String? = nil, date: Date? = nil) {
            self.headline = headline
            self.detail = detail
            self.quote = quote
            self.source = source
            self.date = date
        }
    }

    // MARK: Coding

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case choices, field, steps, deadline, draft, compare, timeline, proof
    }

    public var kind: Kind {
        switch self {
        case .choices: .choices
        case .field: .field
        case .steps: .steps
        case .deadline: .deadline
        case .draft: .draft
        case .compare: .compare
        case .timeline: .timeline
        case .proof: .proof
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .choices: self = .choices(try Choices(from: decoder))
        case .field: self = .field(try Field(from: decoder))
        case .steps: self = .steps(try Steps(from: decoder))
        case .deadline: self = .deadline(try Deadline(from: decoder))
        case .draft: self = .draft(try Draft(from: decoder))
        case .compare: self = .compare(try Compare(from: decoder))
        case .timeline: self = .timeline(try Timeline(from: decoder))
        case .proof: self = .proof(try Proof(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .choices(let v): try v.encode(to: encoder)
        case .field(let v): try v.encode(to: encoder)
        case .steps(let v): try v.encode(to: encoder)
        case .deadline(let v): try v.encode(to: encoder)
        case .draft(let v): try v.encode(to: encoder)
        case .compare(let v): try v.encode(to: encoder)
        case .timeline(let v): try v.encode(to: encoder)
        case .proof(let v): try v.encode(to: encoder)
        }
    }
}

// MARK: From the model

extension ReplyBlock {
    /// What a model may show on its own. Drafts and proof only ever come from
    /// a real case (an email waiting for approval, a company's confirmation),
    /// so a model can't put an Approve button or a "Done" stamp on screen.
    public static let modelKinds: [Kind] = [.choices, .field, .deadline, .compare, .timeline]

    /// Most blocks one reply carries. More than this is a page, not a reply.
    public static let maxPerReply = 3

    /// Reads the `blocks` a model sent with a tool call. Anything malformed,
    /// empty or not allowed is dropped rather than shown half-broken.
    public static func fromModel(_ value: JSONValue?) -> [ReplyBlock] {
        guard case .array(let items) = value else { return [] }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var blocks: [ReplyBlock] = []
        for item in items {
            guard let data = try? encoder.encode(item),
                  let block = try? decoder.decode(ReplyBlock.self, from: data),
                  modelKinds.contains(block.kind),
                  let clean = block.sanitized
            else { continue }
            blocks.append(clean)
            if blocks.count == maxPerReply { break }
        }
        return blocks
    }

    /// The block trimmed to what reads well on a phone, or `nil` when nothing
    /// useful is left.
    public var sanitized: ReplyBlock? {
        func clean(_ text: String, _ limit: Int) -> String {
            String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        func cleanOptional(_ text: String?, _ limit: Int) -> String? {
            guard let text else { return nil }
            let cleaned = clean(text, limit)
            return cleaned.isEmpty ? nil : cleaned
        }
        switch self {
        case .choices(var v):
            var seen = Set<String>()
            v.options = v.options.map { clean($0, 40) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            v.options = Array(v.options.prefix(4))
            return v.options.isEmpty ? nil : .choices(v)
        case .field(var v):
            v.label = clean(v.label, 60)
            v.placeholder = cleanOptional(v.placeholder, 60)
            return v.label.isEmpty ? nil : .field(v)
        case .steps(var v):
            v.title = clean(v.title, 80)
            v.steps = Array(v.steps.map { .init(title: clean($0.title, 80), state: $0.state) }.filter { !$0.title.isEmpty }.prefix(8))
            return v.steps.isEmpty ? nil : .steps(v)
        case .deadline(var v):
            v.title = clean(v.title, 80)
            v.progress = v.progress.map { min(max($0, 0), 1) }
            v.rows = Array(v.rows.map { .init(label: clean($0.label, 60), value: clean($0.value, 40)) }.filter { !$0.label.isEmpty }.prefix(4))
            return v.title.isEmpty ? nil : .deadline(v)
        case .draft(var v):
            v.subject = clean(v.subject, 200)
            return v.body.isEmpty ? nil : .draft(v)
        case .compare(var v):
            v.title = clean(v.title, 80)
            v.options = Array(v.options.map {
                .init(name: clean($0.name, 60), detail: clean($0.detail, 160), price: cleanOptional($0.price, 24), isPick: $0.isPick)
            }.filter { !$0.name.isEmpty }.prefix(4))
            // One pick at most: the first one marked.
            if let first = v.options.firstIndex(where: \.isPick) {
                for index in v.options.indices where index != first { v.options[index].isPick = false }
            }
            return v.options.count < 2 ? nil : .compare(v)
        case .timeline(var v):
            v.title = clean(v.title, 80)
            v.items = Array(v.items.map {
                .init(when: cleanOptional($0.when, 20), title: clean($0.title, 80), detail: cleanOptional($0.detail, 200))
            }.filter { !$0.title.isEmpty }.prefix(10))
            return v.items.isEmpty ? nil : .timeline(v)
        case .proof(var v):
            v.headline = clean(v.headline, 80)
            return v.headline.isEmpty ? nil : .proof(v)
        }
    }

    /// The JSON schema for a `blocks` tool parameter. One flat object with a
    /// `type`, because many OpenAI-compatible servers reject `oneOf`.
    public static let modelSchema: JSONValue = {
        func string(_ description: String) -> JSONValue {
            .object(["type": .string("string"), "description": .string(description)])
        }
        func array(of item: JSONValue, _ description: String) -> JSONValue {
            .object(["type": .string("array"), "items": item, "description": .string(description)])
        }
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ])
        }
        let row = object(["label": string("What it is."), "value": string("Short value, such as a date or amount.")], required: ["label", "value"])
        let option = object([
            "name": string("The option's name."),
            "detail": string("One line on why it fits or not."),
            "price": string("Price as the owner would read it, such as \"£12/mo\"."),
            "isPick": .object(["type": .string("boolean"), "description": .string("True for the one you recommend.")]),
        ], required: ["name", "detail"])
        let item = object([
            "when": string("Day, date or time, such as \"Day 1\" or \"12:30\"."),
            "title": string("What happens."),
            "detail": string("One optional line of detail."),
        ], required: ["title"])
        let block = object([
            "type": .object([
                "type": .string("string"),
                "enum": .array(modelKinds.map { .string($0.rawValue) }),
                "description": .string("choices: short answers to tap. field: one value to type. deadline: a date that matters. compare: 2 to 4 options side by side. timeline: a plan in order."),
            ]),
            "options": .object([
                "type": .string("array"),
                "description": .string("choices: up to 4 short answers. compare: 2 to 4 options."),
                "items": .object(["anyOf": .array([.object(["type": .string("string")]), option])]),
            ]),
            "label": string("field: what you ask for, such as \"Membership email\"."),
            "kind": .object(["type": .string("string"), "enum": .array(["text", "email", "phone", "number", "date"].map { .string($0) })]),
            "placeholder": string("field: an example value."),
            "title": string("deadline, compare, timeline: the headline."),
            "progress": .object(["type": .string("number"), "description": .string("deadline: share of the time already passed, 0 to 1.")]),
            "rows": array(of: row, "deadline: up to 4 dated facts."),
            "items": array(of: item, "timeline: the steps in order."),
        ], required: ["type"])
        return array(of: block, "Optional. Interface to show with your words, only when it saves the owner typing or reading. Most replies need none.")
    }()
}
