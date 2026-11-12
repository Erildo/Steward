import Foundation

/// One visual a find can carry when it says more than a sentence would: the
/// numbers at a glance, a plan in order, what's inside, options side by side,
/// or the date that matters. Most finds carry none; text stays the default.
///
/// On the wire it is one JSON object with a `type` and that type's fields.
public enum FeedLens: Codable, Sendable, Equatable {
    /// Two to four short facts: "3 h", "Free", "Beginner".
    case facts([Fact])
    /// Steps or stages in order, such as weeks of a training plan.
    case plan(Plan)
    /// What's inside, numbered: the records in a guide, the episodes in a series.
    case list(ItemList)
    /// Two or three options side by side, with Steward's pick.
    case compare(Compare)
    /// A day that matters: a release, an event, a closing date.
    case date(DateSpot)

    public struct Fact: Codable, Sendable, Equatable {
        public var label: String
        public var value: String
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Plan: Codable, Sendable, Equatable {
        public struct Step: Codable, Sendable, Equatable {
            /// "Week 1", "Sat", "Day 3". Optional.
            public var when: String?
            public var title: String
            public init(when: String? = nil, title: String) {
                self.when = when
                self.title = title
            }
        }
        public var title: String
        public var steps: [Step]
        public init(title: String, steps: [Step]) {
            self.title = title
            self.steps = steps
        }
    }

    public struct ItemList: Codable, Sendable, Equatable {
        public var title: String
        public var items: [String]
        public init(title: String, items: [String]) {
            self.title = title
            self.items = items
        }
    }

    public struct Compare: Codable, Sendable, Equatable {
        public struct Option: Codable, Sendable, Equatable {
            public var name: String
            public var detail: String
            public var pick: Bool
            public init(name: String, detail: String, pick: Bool = false) {
                self.name = name
                self.detail = detail
                self.pick = pick
            }
            private enum CodingKeys: String, CodingKey { case name, detail, pick }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
                pick = try c.decodeIfPresent(Bool.self, forKey: .pick) ?? false
            }
        }
        public var title: String
        public var options: [Option]
        public init(title: String, options: [Option]) {
            self.title = title
            self.options = options
        }
    }

    public struct DateSpot: Codable, Sendable, Equatable {
        /// The calendar day, as "YYYY-MM-DD" on the wire.
        public var day: String
        /// What happens that day: "Tickets go on sale".
        public var title: String
        public init(day: String, title: String) {
            self.day = day
            self.title = title
        }

        /// The day at noon in the owner's calendar, or nil if `day` isn't one.
        public var date: Date? {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let calendar = Calendar.current
            // The calendar rolls "month 13" into next year; refuse instead.
            guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
                  calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: parts[0], month: parts[1], day: parts[2])
            else { return nil }
            return date
        }
    }

    // MARK: Checking

    /// The lens trimmed to what can be drawn well, or nil when there is too
    /// little to be worth drawing. A model's lens goes through this first.
    public var usable: FeedLens? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch self {
        case .facts(let facts):
            let kept = facts.map { Fact(label: clean($0.label), value: clean($0.value)) }
                .filter { !$0.label.isEmpty && !$0.value.isEmpty && $0.value.count <= 14 }
            return kept.count >= 2 ? .facts(Array(kept.prefix(4))) : nil
        case .plan(let plan):
            let steps = plan.steps.map { Plan.Step(when: $0.when.map(clean).flatMap { $0.isEmpty ? nil : $0 }, title: clean($0.title)) }
                .filter { !$0.title.isEmpty }
            return steps.count >= 2 ? .plan(Plan(title: clean(plan.title), steps: Array(steps.prefix(6)))) : nil
        case .list(let list):
            let items = list.items.map(clean).filter { !$0.isEmpty }
            return items.count >= 2 ? .list(ItemList(title: clean(list.title), items: Array(items.prefix(12)))) : nil
        case .compare(let compare):
            var options = compare.options.map { Compare.Option(name: clean($0.name), detail: clean($0.detail), pick: $0.pick) }
                .filter { !$0.name.isEmpty }
            guard (2...3).contains(options.count) else { return nil }
            // At most one pick.
            var picked = false
            for index in options.indices where options[index].pick {
                if picked { options[index].pick = false }
                picked = true
            }
            return .compare(Compare(title: clean(compare.title), options: options))
        case .date(let spot):
            let title = clean(spot.title)
            guard spot.date != nil, !title.isEmpty else { return nil }
            return .date(DateSpot(day: clean(spot.day), title: title))
        }
    }

    // MARK: Coding

    private enum Kind: String, Codable { case facts, plan, list, compare, date }
    private enum CodingKeys: String, CodingKey { case type, items, title, steps, options, day }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        switch try c.decode(Kind.self, forKey: .type) {
        case .facts: self = .facts(try c.decode([Fact].self, forKey: .items))
        case .plan: self = .plan(Plan(title: title, steps: try c.decode([Plan.Step].self, forKey: .steps)))
        case .list: self = .list(ItemList(title: title, items: try c.decode([String].self, forKey: .items)))
        case .compare: self = .compare(Compare(title: title, options: try c.decode([Compare.Option].self, forKey: .options)))
        case .date: self = .date(DateSpot(day: try c.decode(String.self, forKey: .day), title: title))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .facts(let facts):
            try c.encode(Kind.facts, forKey: .type)
            try c.encode(facts, forKey: .items)
        case .plan(let plan):
            try c.encode(Kind.plan, forKey: .type)
            try c.encode(plan.title, forKey: .title)
            try c.encode(plan.steps, forKey: .steps)
        case .list(let list):
            try c.encode(Kind.list, forKey: .type)
            try c.encode(list.title, forKey: .title)
            try c.encode(list.items, forKey: .items)
        case .compare(let compare):
            try c.encode(Kind.compare, forKey: .type)
            try c.encode(compare.title, forKey: .title)
            try c.encode(compare.options, forKey: .options)
        case .date(let spot):
            try c.encode(Kind.date, forKey: .type)
            try c.encode(spot.title, forKey: .title)
            try c.encode(spot.day, forKey: .day)
        }
    }
}
