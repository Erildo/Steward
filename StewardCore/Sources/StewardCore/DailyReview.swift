import Foundation

/// Steward's daily look over the owner's life: one model call, not a loop.
/// The model reads one context message (memory, goals, open tasks, the last
/// week's chats, the next two weeks of calendar and reminders) and answers
/// with `submit_review`: findings for Insights, each with evidence and an
/// optional offer, and nudges for things coming due.
///
/// It only proposes. Nothing it returns starts anything: an offer is a button
/// the owner taps to open Chat, a nudge is a notification. Everything the
/// model sends is checked here, in code, before the app sees it.
public struct DailyReview: Sendable {
    /// What the review reads, already in plain lines. A `nil` calendar or
    /// reminders list means not connected, which the model is told.
    public struct Input: Sendable {
        public var memory: Memory
        public var goals: [String]
        public var openTasks: [String]
        public var chats: [String]
        public var calendar: [String]?
        public var reminders: [String]?
        /// Titles the owner asked Steward to stop noticing.
        public var stopped: [String]
        /// Titles the owner said were not quite right.
        public var corrected: [String]

        public init(memory: Memory, goals: [String] = [], openTasks: [String] = [], chats: [String] = [],
                    calendar: [String]? = nil, reminders: [String]? = nil, stopped: [String] = [], corrected: [String] = []) {
            self.memory = memory
            self.goals = goals
            self.openTasks = openTasks
            self.chats = chats
            self.calendar = calendar
            self.reminders = reminders
            self.stopped = stopped
            self.corrected = corrected
        }
    }

    /// The model answered with nothing the review could read.
    public struct NothingUsable: Error, CustomStringConvertible {
        public var raw: String
        public var description: String { "The review returned nothing readable: \(raw.prefix(300))" }
    }

    public static let maxInsights = 6
    public static let maxNudges = 3
    public static let maxEvidence = 4
    /// How far ahead the review looks, and how far ahead a nudge may be.
    public static let horizon: TimeInterval = 14 * 86_400

    public var model: any ModelClient
    public var now: @Sendable () -> Date
    public var calendar: Calendar

    public init(model: any ModelClient, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { .now }) {
        self.model = model
        self.calendar = calendar
        self.now = now
    }

    public func run(_ input: Input) async throws -> ReviewResult {
        let date = now()
        let turn = try await model.complete(
            system: TaskSpec.reviewSystem,
            messages: [.user(Self.context(input, now: date, calendar: calendar))],
            tools: [TaskSpec.reviewTool]
        )
        guard let answer = Self.answer(in: turn) else { throw NothingUsable(raw: turn.text ?? "") }
        let parsed = Self.parse(answer, memory: input.memory, stopped: input.stopped, now: date, calendar: calendar)
        return ReviewResult(
            ranAt: date, insights: parsed.insights, nudges: parsed.nudges,
            read: .init(chats: input.chats.count, tasks: input.openTasks.count,
                        calendar: input.calendar?.count, reminders: input.reminders?.count)
        )
    }

    // MARK: Context

    /// The one message: everything that changes from day to day, so the
    /// system prompt and the tool stay cached.
    public static func context(_ input: Input, now: Date, calendar: Calendar = .current) -> String {
        let wording = TaskSpec.reviewWording
        func list(_ lines: [String]?) -> String {
            guard let lines else { return wording.notConnected }
            let shown = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return shown.isEmpty ? wording.none : shown.map { "- \($0)" }.joined(separator: "\n")
        }
        let closed = input.memory.topics.filter { !$0.allowed }.map(\.name)
        return Spec.render(TaskSpec.reviewContextTemplate, [
            "now": stamp(now, calendar: calendar),
            "memory": input.memory.brief(),
            "closed": closed.isEmpty ? wording.noTopics : closed.joined(separator: ", "),
            "goals": list(input.goals),
            "tasks": list(input.openTasks),
            "chats": list(input.chats),
            "calendar": list(input.calendar),
            "reminders": list(input.reminders),
            "stopped": list(input.stopped),
            "corrected": list(input.corrected),
        ])
    }

    /// "Saturday 2026-11-14T09:12 (Europe/Berlin)": the weekday helps the model,
    /// and the format is the one nudges answer in.
    static func stamp(_ date: Date, calendar: Calendar) -> String {
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEEE"
        return "\(weekday.string(from: date)) \(localFormatter(calendar).string(from: date)) (\(calendar.timeZone.identifier))"
    }

    static func localFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }

    // MARK: Reading the answer

    /// The `submit_review` arguments, or failing that a JSON object in the
    /// text (some providers answer in words despite the tool).
    static func answer(in turn: AssistantTurn) -> JSONValue? {
        if let call = turn.toolCalls.first(where: { $0.name == TaskSpec.reviewTool.name }) {
            return .object(call.arguments)
        }
        guard let raw = turn.text, let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw[start...end].utf8)),
              case .object(let object) = value, object["insights"] != nil || object["nudges"] != nil
        else { return nil }
        return value
    }

    /// The findings and nudges that survive the checks. Each insight needs a
    /// known kind and confidence, a title, a basis and at least one piece of
    /// evidence; anything touching a topic the owner turned off, or a finding
    /// they asked Steward to stop noticing, is dropped.
    public static func parse(_ answer: JSONValue, memory: Memory, stopped: [String] = [], now: Date,
                             calendar: Calendar = .current) -> (insights: [ReviewInsight], nudges: [ReviewNudge]) {
        guard case .object(let object) = answer else { return ([], []) }
        var insights: [ReviewInsight] = []
        var hasLead = false
        for value in items(object["insights"]) {
            guard var insight = insight(from: value, memory: memory),
                  !stopped.contains(where: { Memory.same($0, insight.title) }),
                  !insights.contains(where: { Memory.same($0.title, insight.title) })
            else { continue }
            // One lead at most: the first one marked.
            if insight.lead { if hasLead { insight.lead = false } else { hasLead = true } }
            insights.append(insight)
            if insights.count == maxInsights { break }
        }
        var nudges: [ReviewNudge] = []
        for value in items(object["nudges"]) {
            guard let nudge = nudge(from: value, memory: memory, now: now, calendar: calendar),
                  !nudges.contains(where: { Memory.same($0.title, nudge.title) })
            else { continue }
            nudges.append(nudge)
            if nudges.count == maxNudges { break }
        }
        return (insights, nudges)
    }

    static func insight(from value: JSONValue, memory: Memory) -> ReviewInsight? {
        guard case .object(let o) = value,
              let kind = o["kind"]?.string.flatMap(ReviewInsight.Kind.init(rawValue:)),
              let confidence = o["confidence"]?.string.flatMap(Memory.Confidence.init(rawValue:)),
              let title = text(o["title"], 80), let detail = text(o["detail"], 320), let basis = text(o["basis"], 40)
        else { return nil }
        let evidence: [ReviewInsight.Evidence] = items(o["evidence"]).compactMap { item in
            guard case .object(let e) = item,
                  let source = e["source"]?.string.flatMap(ReviewInsight.Evidence.Source.init(rawValue:)),
                  let line = text(e["text"], 160)
            else { return nil }
            return .init(source: source, text: line)
        }.prefix(maxEvidence).map { $0 }
        // No evidence, no finding.
        guard !evidence.isEmpty else { return nil }

        let topic = text(o["topic"], 40)
        let remember = text(o["remember"], Memory.maxItemChars)
        var offer: ReviewInsight.Offer?
        if case .object(let f)? = o["offer"], let label = text(f["label"], 40), let request = text(f["request"], 280) {
            offer = .init(label: label, request: request)
        }
        // Topics the owner turned off: by the model's own label, then by the
        // words themselves, in case the label was missing or wrong.
        let words = [title, detail, remember, offer?.label, offer?.request].compactMap { $0 } + evidence.map(\.text)
        guard memory.isAllowed(topic), !words.contains(where: memory.touchesClosedTopic) else { return nil }

        return ReviewInsight(
            kind: kind, title: title, detail: detail,
            status: kind == .goal ? text(o["status"], 24) : nil,
            statusNeedsYou: kind == .goal && o["status_needs_you"] == .bool(true),
            lead: o["lead"] == .bool(true),
            confidence: confidence, basis: basis, evidence: evidence,
            topic: topic, remember: remember, chart: chart(o["chart"]), offer: offer
        )
    }

    /// A chart through the same checks as one in a chat reply.
    static func chart(_ value: JSONValue?) -> ReplyBlock.Chart? {
        guard case .object(var object)? = value else { return nil }
        if object["type"] == nil { object["type"] = .string(ReplyBlock.Kind.chart.rawValue) }
        guard case .chart(let chart)? = ReplyBlock.fromModel(.array([.object(object)])).first else { return nil }
        return chart
    }

    static func nudge(from value: JSONValue, memory: Memory, now: Date, calendar: Calendar) -> ReviewNudge? {
        guard case .object(let o) = value, let title = text(o["title"], 60), let at = text(o["at"], 40),
              let date = localFormatter(calendar).date(from: String(at.prefix(16)))
                ?? ISO8601DateFormatter().date(from: at),
              date > now, date <= now.addingTimeInterval(horizon)
        else { return nil }
        let body = text(o["body"], 160) ?? ""
        guard !memory.touchesClosedTopic(title), !memory.touchesClosedTopic(body) else { return nil }
        return ReviewNudge(title: title, body: body, at: date)
    }

    static func items(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let items)? = value else { return [] }
        return items
    }

    /// Trimmed, one line, cut to `limit`; `nil` when empty.
    static func text(_ value: JSONValue?, _ limit: Int) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : String(flat.prefix(limit))
    }
}

// MARK: Results

/// One review, as stored in the owner's documents and drawn by Insights.
public struct ReviewResult: Codable, Sendable, Equatable {
    /// How much the review read, so Insights can say so plainly.
    public struct Read: Codable, Sendable, Equatable {
        public var chats: Int
        public var tasks: Int
        /// `nil` when not connected.
        public var calendar: Int?
        public var reminders: Int?

        public init(chats: Int, tasks: Int, calendar: Int? = nil, reminders: Int? = nil) {
            self.chats = chats
            self.tasks = tasks
            self.calendar = calendar
            self.reminders = reminders
        }
    }

    public var ranAt: Date
    public var insights: [ReviewInsight]
    public var nudges: [ReviewNudge]
    public var read: Read

    public init(ranAt: Date, insights: [ReviewInsight], nudges: [ReviewNudge], read: Read) {
        self.ranAt = ranAt
        self.insights = insights
        self.nudges = nudges
        self.read = read
    }
}

/// A finding: what Steward noticed, what it rests on, how sure it is, and
/// one next step the owner can take.
public struct ReviewInsight: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case goal, change, aboutYou = "about_you" }

    public struct Evidence: Codable, Sendable, Equatable, Hashable {
        public enum Source: String, Codable, Sendable { case chat, task, calendar, reminders, you, memory }
        public var source: Source
        public var text: String
        public init(source: Source, text: String) {
            self.source = source
            self.text = text
        }
    }

    /// A suggested task, written as the owner would ask it. Tapping it opens
    /// Chat with `request` ready to send; nothing starts without that.
    public struct Offer: Codable, Sendable, Equatable {
        public var label: String
        public var request: String
        public init(label: String, request: String) {
            self.label = label
            self.request = request
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var detail: String
    public var status: String?
    public var statusNeedsYou: Bool
    public var lead: Bool
    public var confidence: Memory.Confidence
    public var basis: String
    public var evidence: [Evidence]
    public var topic: String?
    /// The finding as a note for memory, kept if the owner says "That's me".
    public var remember: String?
    public var chart: ReplyBlock.Chart?
    public var offer: Offer?

    public init(id: UUID = UUID(), kind: Kind, title: String, detail: String, status: String? = nil,
                statusNeedsYou: Bool = false, lead: Bool = false, confidence: Memory.Confidence, basis: String,
                evidence: [Evidence], topic: String? = nil, remember: String? = nil,
                chart: ReplyBlock.Chart? = nil, offer: Offer? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.statusNeedsYou = statusNeedsYou
        self.lead = lead
        self.confidence = confidence
        self.basis = basis
        self.evidence = evidence
        self.topic = topic
        self.remember = remember
        self.chart = chart
        self.offer = offer
    }

    /// What memory keeps when the owner says "That's me".
    public var memoryNote: String { remember ?? title }
}

/// A heads-up for something coming due, shown as a visible notification.
public struct ReviewNudge: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var at: Date

    public init(id: UUID = UUID(), title: String, body: String, at: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.at = at
    }
}

// MARK: Schedule

/// When the review may run, kept with its results. Once a day at most, never
/// within 20 hours of the last try, and a circuit breaker: three failures in
/// a row pause it for a week instead of retrying into a broken model.
public struct ReviewSchedule: Codable, Sendable, Equatable {
    public static let minimumGap: TimeInterval = 20 * 3_600
    public static let maxFailures = 3
    public static let pause: TimeInterval = 7 * 86_400

    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var failures: Int
    public var pausedUntil: Date?

    public init(lastAttempt: Date? = nil, lastSuccess: Date? = nil, failures: Int = 0, pausedUntil: Date? = nil) {
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.failures = failures
        self.pausedUntil = pausedUntil
    }

    public func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        if let pausedUntil, now < pausedUntil { return false }
        guard let lastAttempt else { return true }
        return !calendar.isDate(lastAttempt, inSameDayAs: now) && now.timeIntervalSince(lastAttempt) >= Self.minimumGap
    }

    /// The earliest the next review may run, for the background refresh.
    public func nextDue(after now: Date) -> Date {
        let gap = lastAttempt.map { $0.addingTimeInterval(Self.minimumGap) } ?? now
        return max(now, gap, pausedUntil ?? now)
    }

    public mutating func started(at now: Date) {
        lastAttempt = now
    }

    public mutating func succeeded(at now: Date) {
        lastSuccess = now
        failures = 0
        pausedUntil = nil
    }

    public mutating func failed(at now: Date) {
        failures += 1
        if failures >= Self.maxFailures {
            pausedUntil = now.addingTimeInterval(Self.pause)
            failures = 0
        }
    }
}

/// Everything the review keeps between runs: the latest result, the schedule,
/// and the owner's reactions, which also go back to the model next time.
public struct ReviewRecord: Codable, Sendable, Equatable {
    public enum Reaction: String, Codable, Sendable { case confirmed, corrected }

    public static let rememberedTitles = 50

    public var result: ReviewResult?
    public var schedule: ReviewSchedule
    /// By insight id (as a string, so the file stays readable).
    public var reactions: [String: Reaction]
    /// Insights the owner stopped, by id, so they stay hidden.
    public var hidden: Set<UUID>
    /// Titles of findings the owner stopped: never shown again.
    public var stopped: [String]
    /// Titles of findings the owner said were not quite right.
    public var corrected: [String]
    /// Memory items a "That's me" added, so taking it back removes them.
    public var added: [String: UUID]

    public init(result: ReviewResult? = nil, schedule: ReviewSchedule = .init(), reactions: [String: Reaction] = [:],
                hidden: Set<UUID> = [], stopped: [String] = [], corrected: [String] = [], added: [String: UUID] = [:]) {
        self.result = result
        self.schedule = schedule
        self.reactions = reactions
        self.hidden = hidden
        self.stopped = stopped
        self.corrected = corrected
        self.added = added
    }

    public mutating func stop(_ insight: ReviewInsight) {
        hidden.insert(insight.id)
        Self.note(insight.title, in: &stopped)
    }

    public mutating func unstop(_ insight: ReviewInsight) {
        hidden.remove(insight.id)
        stopped.removeAll { Memory.same($0, insight.title) }
    }

    /// A new result: reactions and hidden ids only matter for the one shown.
    public mutating func show(_ result: ReviewResult) {
        self.result = result
        let ids = Set(result.insights.map(\.id))
        let keys = Set(ids.map(\.uuidString))
        reactions = reactions.filter { keys.contains($0.key) }
        hidden = hidden.intersection(ids)
        added = added.filter { keys.contains($0.key) }
    }

    static func note(_ title: String, in list: inout [String]) {
        list.removeAll { Memory.same($0, title) }
        list.append(title)
        if list.count > rememberedTitles { list.removeFirst(list.count - rememberedTitles) }
    }

    public mutating func noteCorrected(_ title: String) { Self.note(title, in: &corrected) }
    public mutating func unnoteCorrected(_ title: String) { corrected.removeAll { Memory.same($0, title) } }
}

/// Reads and writes `DailyReview.json`: pretty, sorted JSON the owner can read,
/// protected while the phone is locked.
public struct ReviewStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> ReviewRecord {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReviewRecord() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReviewRecord.self, from: Data(contentsOf: url))
    }

    public func save(_ record: ReviewRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        #if os(iOS)
        try encoder.encode(record).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encoder.encode(record).write(to: url, options: [.atomic])
        #endif
    }
}

// MARK: Quiet hours

/// The owner's quiet hours from the Steward tab, as minutes after midnight.
/// A window may cross midnight (22:00 to 08:00).
public struct QuietHours: Sendable, Equatable {
    public var from: Int
    public var to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if from == to { return false }
        return from < to ? (minute >= from && minute < to) : (minute >= from || minute < to)
    }

    /// `date`, or the end of the quiet window it falls in.
    public func deliveryTime(for date: Date, calendar: Calendar = .current) -> Date {
        guard contains(date, calendar: calendar) else { return date }
        let start = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // Before midnight in a window that crosses it: the end is tomorrow.
        let day = from > to && minute >= from ? calendar.date(byAdding: .day, value: 1, to: start) ?? start : start
        return calendar.date(byAdding: .minute, value: to, to: day) ?? date
    }
}
