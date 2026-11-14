import Foundation

/// What Steward knows about its owner: one readable JSON file on the phone,
/// which the owner can read, export and delete. It never leaves the device
/// except inside a model request, and never reaches the relay.
///
/// Two kinds of item, never mixed:
/// - a **fact** is something the owner said, or a guess they confirmed;
/// - a **guess** is Steward's own reading of a pattern, with its evidence and
///   how sure it is. A guess becomes a fact only on the owner's word.
///
/// Topics the owner turned off are enforced here, not in a prompt: nothing is
/// stored under them, and nothing already stored under them reaches a model.
public struct Memory: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case fact, guess }

    public enum Confidence: String, Codable, Sendable, CaseIterable {
        case sure, fairlySure = "fairly_sure", hunch
    }

    /// Where an item came from, so the owner can check it.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case owner, chat, task, feed, calendar, review
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var text: String
        public var kind: Kind
        public var source: Source
        /// In plain words: "You said in a chat", "From 14 tasks".
        public var evidence: String
        /// Guesses only.
        public var confidence: Confidence?
        /// One of `Memory.topics`, or nil for everyday things.
        public var topic: String?
        public var createdAt: Date
        /// When the owner said a guess was right.
        public var confirmedAt: Date?

        public init(id: UUID = UUID(), text: String, kind: Kind, source: Source, evidence: String,
                    confidence: Confidence? = nil, topic: String? = nil, createdAt: Date = .now, confirmedAt: Date? = nil) {
            self.id = id
            self.text = text
            self.kind = kind
            self.source = source
            self.evidence = evidence
            self.confidence = kind == .guess ? (confidence ?? .hunch) : nil
            self.topic = topic
            self.createdAt = createdAt
            self.confirmedAt = confirmedAt
        }
    }

    /// Parts of life Steward leaves alone unless the owner turns them on.
    public struct Topic: Codable, Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var allowed: Bool

        public init(name: String, allowed: Bool) {
            self.name = name
            self.allowed = allowed
        }
    }

    public var items: [Item]
    public var topics: [Topic]

    /// The sensitive topics, off until the owner turns them on.
    public static let defaultTopics: [Topic] = [
        Topic(name: "Health and sleep", allowed: false),
        Topic(name: "Mood", allowed: false),
        Topic(name: "Relationships", allowed: false),
        Topic(name: "Money and spending", allowed: true),
    ]

    public static let maxItemChars = 200
    public static let maxItems = 300

    public init(items: [Item] = [], topics: [Topic] = Memory.defaultTopics) {
        self.items = items
        self.topics = topics
    }

    public var facts: [Item] { items.filter { $0.kind == .fact } }
    public var guesses: [Item] { items.filter { $0.kind == .guess } }

    public func isAllowed(_ topic: String?) -> Bool {
        guard let topic else { return true }
        return topics.first { $0.name.caseInsensitiveCompare(topic) == .orderedSame }?.allowed ?? true
    }

    /// Items a model may see: everything outside the topics turned off.
    public var visible: [Item] { items.filter { isAllowed($0.topic) } }

    public enum RememberOutcome: Equatable, Sendable {
        case added(Item)
        /// The same thing was already known; a fact replaces a guess.
        case alreadyKnown(Item)
        /// Under a topic the owner turned off, or empty: nothing stored.
        case refused
    }

    /// Adds an item, or strengthens one already there. A repeated guess
    /// leaves the earlier one; the same text as a fact turns the guess into a fact.
    @discardableResult
    public mutating func remember(_ item: Item) -> RememberOutcome {
        var item = item
        item.text = Self.clean(item.text)
        guard !item.text.isEmpty, isAllowed(item.topic), !Self.looksSecret(item.text) else { return .refused }
        item.topic = item.topic.flatMap { topic in topics.first { $0.name.caseInsensitiveCompare(topic) == .orderedSame }?.name }
        if let index = items.firstIndex(where: { Self.same($0.text, item.text) }) {
            if item.kind == .fact, items[index].kind == .guess {
                items[index].kind = .fact
                items[index].confidence = nil
                items[index].evidence = item.evidence
                items[index].source = item.source
            }
            return .alreadyKnown(items[index])
        }
        items.append(item)
        // The oldest guesses go first when the file is full; facts stay.
        while items.count > Self.maxItems, let oldest = items.firstIndex(where: { $0.kind == .guess }) {
            items.remove(at: oldest)
        }
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        return .added(item)
    }

    public mutating func forget(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// "That's me": the owner says a guess is right.
    public mutating func confirm(_ id: UUID, at date: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].kind = .fact
        items[index].confidence = nil
        items[index].confirmedAt = date
    }

    /// "Not quite": the owner says a guess is off. Steward trusts it one step
    /// less, and a hunch they doubt is gone. Facts are the owner's own word
    /// and stay as they are.
    public mutating func doubt(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .guess else { return }
        switch items[index].confidence ?? .hunch {
        case .sure: items[index].confidence = .fairlySure
        case .fairlySure: items[index].confidence = .hunch
        case .hunch: items.remove(at: index)
        }
    }

    /// The item that says the same thing as `text`, if any.
    public func item(matching text: String) -> Item? {
        items.first { Self.same($0.text, text) }
    }

    /// Whether `text` touches a topic the owner turned off, by the topic's
    /// marker words (`TaskSpec/topic_words.json`). Whole words only, so
    /// "ill" doesn't catch "still".
    public func touchesClosedTopic(_ text: String) -> Bool {
        let closed = topics.filter { !$0.allowed }.map(\.name)
        guard !closed.isEmpty else { return false }
        let words = " " + text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ") + " "
        for name in closed {
            let markers = TaskSpec.topicWords.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? []
            if markers.contains(where: { words.contains(" \($0.lowercased()) ") }) { return true }
        }
        return false
    }

    public mutating func setTopic(_ name: String, allowed: Bool) {
        guard let index = topics.firstIndex(where: { $0.name == name }) else { return }
        topics[index].allowed = allowed
    }

    public mutating func forgetEverything() {
        items = []
    }

    /// What a model is told, filled into the `memory` placeholder. Facts and
    /// guesses stay apart, so a guess is never read as something the owner said.
    public func brief(maxFacts: Int = 40, maxGuesses: Int = 20) -> String {
        let shown = visible
        let facts = shown.filter { $0.kind == .fact }.suffix(maxFacts)
        let guesses = shown.filter { $0.kind == .guess }.suffix(maxGuesses)
        let wording = TaskSpec.memoryWording
        var lines: [String] = []
        if facts.isEmpty && guesses.isEmpty {
            lines.append(wording.nothing)
        }
        if !facts.isEmpty {
            lines.append(wording.facts)
            lines += facts.map { "- \($0.text)" }
        }
        if !guesses.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(wording.guesses)
            lines += guesses.map { "- \($0.text) (\($0.confidence?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "hunch"); \($0.evidence))" }
        }
        let closed = topics.filter { !$0.allowed }.map(\.name)
        if !closed.isEmpty {
            lines.append("")
            lines.append(Spec.render(wording.offLimits, ["topics": closed.joined(separator: ", ")]))
        }
        return lines.joined(separator: "\n")
    }

    /// Plain text the owner can keep: everything, including topics turned off.
    public func exportText() -> String {
        var lines = ["What Steward knows about you", "", "You told Steward:"]
        lines += facts.map { "- \($0.text) (\($0.evidence))" }
        lines += ["", "Steward's guesses:"]
        lines += guesses.map { "- \($0.text) (\($0.evidence))" }
        lines += ["", "Off limits: " + topics.filter { !$0.allowed }.map(\.name).joined(separator: ", ")]
        return lines.joined(separator: "\n")
    }

    static func clean(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(maxItemChars))
    }

    /// Card, account and phone-length numbers are never kept, whatever a model
    /// was told: eight or more digits in a row, spaces and dashes ignored.
    static func looksSecret(_ text: String) -> Bool {
        var run = 0
        for character in text {
            if character.isNumber { run += 1; if run >= 8 { return true } }
            else if character != " " && character != "-" { run = 0 }
        }
        return false
    }

    static func same(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return key(a) == key(b)
    }
}

/// Reads and writes the memory file. Pretty, sorted JSON, so the owner (or any
/// computer) can read it, and protected while the phone is locked.
public struct MemoryStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Memory {
        guard FileManager.default.fileExists(atPath: url.path) else { return Memory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Memory.self, from: Data(contentsOf: url))
    }

    public func save(_ memory: Memory) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        #if os(iOS)
        try encoder.encode(memory).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encoder.encode(memory).write(to: url, options: [.atomic])
        #endif
    }
}
