import Foundation

extension ReplyBlock {
    /// Something Steward will do outside the conversation only with the
    /// owner's yes: put an event in their calendar, add a reminder, or start
    /// an errand with a company. Built by `ActionProposal` from a checked tool
    /// call, never from a model's `blocks`, so a model can't draw an Approve
    /// button for something it didn't propose through a tool.
    ///
    /// The `id` is the action's one-time token: once approved it is done at
    /// most once, however many times Approve is tapped.
    public struct Action: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            case pending, approved, declined, done, failed
        }

        public enum Payload: Codable, Sendable, Equatable {
            case event(Event)
            case reminder(Reminder)
            case errand(Errand)

            public var kind: String {
                switch self {
                case .event: "event"
                case .reminder: "reminder"
                case .errand: "errand"
                }
            }
        }

        public struct Event: Codable, Sendable, Equatable {
            public var title: String
            public var start: Date
            public var end: Date
            public var allDay: Bool
            public var location: String?
            public var notes: String?

            public init(title: String, start: Date, end: Date, allDay: Bool, location: String? = nil, notes: String? = nil) {
                self.title = title
                self.start = start
                self.end = end
                self.allDay = allDay
                self.location = location
                self.notes = notes
            }
        }

        public struct Reminder: Codable, Sendable, Equatable {
            public var title: String
            public var due: Date?
            /// The due date has a time, not just a day.
            public var dueHasTime: Bool
            public var notes: String?

            public init(title: String, due: Date? = nil, dueHasTime: Bool = false, notes: String? = nil) {
                self.title = title
                self.due = due
                self.dueHasTime = dueHasTime
                self.notes = notes
            }
        }

        public struct Errand: Codable, Sendable, Equatable {
            /// cancel, refund, dispute, complain or other.
            public var errand: String
            public var companyName: String
            public var companyEmail: String
            public var goal: String
            /// What the owner knows that helps, in their words.
            public var facts: String
            /// An account, member or order number the company will ask for.
            public var accountRef: String
            /// What the owner won't accept ("a discount instead").
            public var willNot: [String]

            public init(errand: String, companyName: String, companyEmail: String, goal: String,
                        facts: String = "", accountRef: String = "", willNot: [String] = []) {
                self.errand = errand
                self.companyName = companyName
                self.companyEmail = companyEmail
                self.goal = goal
                self.facts = facts
                self.accountRef = accountRef
                self.willNot = willNot
            }
        }

        public var id: UUID
        public var payload: Payload
        public var status: Status
        /// What happened, in plain words, once done or failed.
        public var outcome: String?

        public init(id: UUID = UUID(), payload: Payload, status: Status = .pending, outcome: String? = nil) {
            self.id = id
            self.payload = payload
            self.status = status
            self.outcome = outcome
        }

        /// The question put to the owner while it waits.
        public var question: String {
            switch payload {
            case .event(let e): "Add “\(e.title)” to your calendar?"
            case .reminder(let r): "Add a reminder to “\(r.title)”?"
            case .errand(let e): "Start an errand with \(e.companyName)?"
            }
        }

        /// The action in words, for a model reading the thread back.
        public var plainText: String {
            let what: String
            switch payload {
            case .event(let e):
                what = "Proposed calendar event “\(e.title)”, \(Self.wire(e.start)) to \(Self.wire(e.end))\(e.location.map { " at \($0)" } ?? "")"
            case .reminder(let r):
                what = "Proposed reminder “\(r.title)”\(r.due.map { ", due \(Self.wire($0))" } ?? "")"
            case .errand(let e):
                what = "Proposed errand (\(e.errand)) with \(e.companyName) <\(e.companyEmail)>: \(e.goal)"
            }
            let state: String
            switch status {
            case .pending: state = "waiting for the owner's yes"
            case .approved: state = "approved, in progress"
            case .declined: state = "the owner declined it"
            case .done: state = "done" + (outcome.map { ": \($0)" } ?? "")
            case .failed: state = "it failed" + (outcome.map { ": \($0)" } ?? "")
            }
            return "\(what). Status: \(state)."
        }

        /// "2026-11-20T19:00:00", the owner's local time, as the model wrote it.
        static func wire(_ date: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
            f.timeZone = .current
            return f.string(from: date)
        }
    }
}

/// Turns a proposing tool call (`propose_event`, `propose_reminder`,
/// `propose_errand`) into an action for the owner's yes, or says what's wrong
/// so the model can fix it. The checks are code, not prompt.
public enum ActionProposal {
    public static let tools: Set<String> = ["propose_event", "propose_reminder", "propose_errand"]

    public static let errands: Set<String> = ["cancel", "refund", "dispute", "complain", "other"]

    public static func parse(_ call: ToolCall, now: Date = .now, timeZone: TimeZone = .current) -> Result<ReplyBlock.Action, ProposalError> {
        func text(_ key: String, _ limit: Int) -> String {
            String((call.arguments[key]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        func optional(_ key: String, _ limit: Int) -> String? {
            let value = text(key, limit)
            return value.isEmpty ? nil : value
        }
        switch call.name {
        case "propose_event":
            let title = text("title", 120)
            guard !title.isEmpty else { return .failure(.init("An event needs a title.")) }
            guard let (start, startHasTime) = date(text("start", 40), timeZone: timeZone) else {
                return .failure(.init("start must be a date like 2026-11-20 or 2026-11-20T19:00."))
            }
            let allDay = !startHasTime || call.arguments["all_day"] == .bool(true)
            var end: Date
            if let (parsed, _) = date(text("end", 40), timeZone: timeZone) {
                end = parsed
            } else {
                end = allDay ? start.addingTimeInterval(86_400) : start.addingTimeInterval(3_600)
            }
            if allDay, end <= start { end = start.addingTimeInterval(86_400) }
            guard end > start else { return .failure(.init("end must be after start.")) }
            guard end > now.addingTimeInterval(-86_400) else { return .failure(.init("That event is in the past.")) }
            guard end.timeIntervalSince(start) <= 31 * 86_400 else { return .failure(.init("An event can't run longer than a month.")) }
            return .success(.init(payload: .event(.init(title: title, start: start, end: end, allDay: allDay,
                                                        location: optional("location", 160), notes: optional("notes", 600)))))
        case "propose_reminder":
            let title = text("title", 120)
            guard !title.isEmpty else { return .failure(.init("A reminder needs a title.")) }
            let dueText = text("due", 40)
            var due: Date?
            var hasTime = false
            if !dueText.isEmpty {
                guard let (parsed, withTime) = date(dueText, timeZone: timeZone) else {
                    return .failure(.init("due must be a date like 2026-11-20 or 2026-11-20T09:00, or left out."))
                }
                due = parsed
                hasTime = withTime
            }
            return .success(.init(payload: .reminder(.init(title: title, due: due, dueHasTime: hasTime, notes: optional("notes", 600)))))
        case "propose_errand":
            let errand = text("errand", 20).lowercased()
            let company = text("company_name", 80)
            let email = text("company_email", 120).lowercased()
            let goal = text("goal", 400)
            guard errands.contains(errand) else { return .failure(.init("errand must be one of: \(errands.sorted().joined(separator: ", ")).")) }
            guard !company.isEmpty else { return .failure(.init("Name the company.")) }
            guard isEmail(email) else { return .failure(.init("company_email must be the company's own email address. If you don't know it, ask the owner.")) }
            guard !goal.isEmpty else { return .failure(.init("Say what counts as done, in goal.")) }
            var willNot: [String] = []
            if case .array(let items)? = call.arguments["will_not"] {
                willNot = items.compactMap(\.string).map { String($0.prefix(120)) }.filter { !$0.isEmpty }.prefix(5).map { $0 }
            }
            return .success(.init(payload: .errand(.init(errand: errand, companyName: company, companyEmail: email, goal: goal,
                                                         facts: text("facts", 800), accountRef: text("account_ref", 80),
                                                         willNot: willNot))))
        default:
            return .failure(.init("\(call.name) doesn't propose anything."))
        }
    }

    public struct ProposalError: Error, Equatable, Sendable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    /// "2026-11-20" (a day) or "2026-11-20T19:00" / with seconds or an offset
    /// (a time). Times without an offset are the owner's local time.
    static func date(_ text: String, timeZone: TimeZone) -> (Date, Bool)? {
        guard !text.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard day.count == 3, (1...12).contains(day[1]), (1...31).contains(day[2]) else { return nil }
        guard text.count > 10 else {
            return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2])).map { ($0, false) }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let withOffset = iso.date(from: text) { return (withOffset, true) }
        let time = text.dropFirst(11).prefix(8).split(separator: ":").compactMap { Int($0) }
        guard text.dropFirst(10).first == "T" || text.dropFirst(10).first == " ",
              time.count >= 2, (0...23).contains(time[0]), (0...59).contains(time[1]) else { return nil }
        return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1],
                                                  second: time.count > 2 ? time[2] : 0)).map { ($0, true) }
    }

    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
            && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }
}
