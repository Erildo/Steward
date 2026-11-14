import Foundation
import Observation
import StewardCore

/// The Insights tab's state: this week's findings, the owner's reactions to
/// them, what Steward has finished, and what it knows. No engine yet: sample
/// launches fill it, everything else starts empty.
@MainActor
@Observable
final class InsightsModel {
    enum Reaction: Hashable {
        /// "That's me": Steward builds on it.
        case confirmed
        /// "Not quite": Steward looks again.
        case corrected
    }

    /// The week these findings cover, from its Monday.
    let weekOf: Date
    /// What Steward read to reach them, said plainly.
    let readSummary: String?
    let lead: Insight?
    let insights: [Insight]
    let wins: [Win]
    let winsSince: Date?
    private(set) var known: [Known]
    var topics: [Topic]
    let isSample: Bool

    private(set) var reactions: [UUID: Reaction] = [:]
    private(set) var hidden: Set<UUID> = []
    /// Findings whose charts have drawn in once this session.
    private(set) var drawn: Set<UUID> = []
    /// The finding last stopped, for a few seconds of undo.
    private(set) var lastHidden: Insight?

    init(weekOf: Date, readSummary: String?, lead: Insight?, insights: [Insight], wins: [Win],
         winsSince: Date?, known: [Known], topics: [Topic], isSample: Bool) {
        self.weekOf = weekOf
        self.readSummary = readSummary
        self.lead = lead
        self.insights = insights
        self.wins = wins
        self.winsSince = winsSince
        self.known = known
        self.topics = topics
        self.isSample = isSample
    }

    var isEmpty: Bool { lead == nil && insights.isEmpty && wins.isEmpty }

    func insights(_ kind: Insight.Kind) -> [Insight] {
        insights.filter { $0.kind == kind && !hidden.contains($0.id) }
    }

    func isHidden(_ insight: Insight) -> Bool { hidden.contains(insight.id) }

    var hiddenCount: Int { hidden.count }

    func hasDrawn(_ insight: Insight) -> Bool { drawn.contains(insight.id) }
    func markDrawn(_ insight: Insight) { drawn.insert(insight.id) }

    func reaction(to insight: Insight) -> Reaction? { reactions[insight.id] }

    /// Tapping the same answer again takes it back.
    func react(_ reaction: Reaction, to insight: Insight) {
        reactions[insight.id] = reactions[insight.id] == reaction ? nil : reaction
    }

    func stopNoticing(_ insight: Insight) {
        hidden.insert(insight.id)
        lastHidden = insight
    }

    func undoStop() {
        guard let insight = lastHidden else { return }
        hidden.remove(insight.id)
        lastHidden = nil
    }

    func dismissUndo(_ id: UUID) {
        if lastHidden?.id == id { lastHidden = nil }
    }

    func forget(_ item: Known) {
        known.removeAll { $0.id == item.id }
    }

    var facts: [Known] { known.filter { !$0.isGuess } }
    var guesses: [Known] { known.filter(\.isGuess) }

    /// Money back across the wins, and money no longer going out each month.
    var totalBack: Decimal { wins.compactMap(\.amount).reduce(0, +) }
    var totalMonthly: Decimal { wins.compactMap(\.monthly).reduce(0, +) }

    /// Everything Steward knows, as plain text the owner can keep.
    var exportText: String {
        var lines = ["What Steward knows about you", ""]
        lines.append("You told Steward:")
        lines += facts.map { "- \($0.text) (\($0.source))" }
        lines.append("")
        lines.append("Steward's guesses:")
        lines += guesses.map { "- \($0.text) (\($0.source))" }
        lines.append("")
        lines.append("Off limits: " + topics.filter { !$0.allowed }.map(\.name).joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    static var defaultTopics: [Topic] {
        [
            Topic(name: "Health and sleep", systemImage: "heart", allowed: false),
            Topic(name: "Mood", systemImage: "face.smiling", allowed: false),
            Topic(name: "Relationships", systemImage: "person.2", allowed: false),
            Topic(name: "Money and spending", systemImage: "creditcard", allowed: true),
        ]
    }
}

extension InsightsModel {
    /// Launch states, like the other tabs: `-uiState insights` (and the debug
    /// demo) shows sample findings, `-uiState insightsEmpty` the first run.
    /// Real launches start empty until Steward has something to say.
    static func launch() -> InsightsModel {
        switch UserDefaults.standard.string(forKey: "uiState") {
        case "insights", "demo": InsightsSample.model()
        default: empty()
        }
    }

    static func empty() -> InsightsModel {
        InsightsModel(weekOf: Date.now.startOfWeek, readSummary: nil, lead: nil, insights: [], wins: [],
                      winsSince: nil, known: [], topics: defaultTopics, isSample: false)
    }
}

extension Date {
    /// The Monday this date falls in.
    var startOfWeek: Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: self)?.start ?? self
    }
}

/// Demo content for `-uiState insights`. Made up and labelled "Sample"; the
/// goals match the Feed sample's taste file.
enum InsightsSample {
    static func model(now: Date = .now) -> InsightsModel {
        func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86_400) }
        /// Monday first, in the owner's language.
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let weekdays = Array(symbols[1...] + symbols[..<1])
        /// Weekly values, oldest first, labelled from "5 weeks ago" to "This week".
        func weeks(_ values: [Double]) -> [ReplyBlock.Chart.Point] {
            values.enumerated().map { index, value in
                let ago = values.count - 1 - index
                return .init(label: ago == 0 ? "This week" : ago == 1 ? "Last week" : "\(ago) weeks ago", value: value)
            }
        }

        let lead = Insight(
            kind: .aboutYou,
            title: "Sunday evening is when you get things done",
            detail: "You started 9 of your last 14 tasks on a Sunday between 6 and 10 pm. On weekdays you rarely start anything.",
            chart: .init(style: .columns, unit: "tasks started",
                         points: zip(weekdays, [1.0, 0, 2, 1, 0, 1, 9]).map { .init(label: $0, value: $1) },
                         highlight: 6),
            confidence: .sure,
            basis: "14 tasks",
            evidence: [
                .init(source: .task, text: "9 of 14 tasks started on a Sunday evening, since 2 October"),
                .init(source: .chat, text: "\"I'll deal with it at the weekend\", in 5 chats"),
            ],
            nextStep: .init(label: "Line up Sundays",
                            request: "Every Sunday at 6 pm, show me what's waiting for me this week.")
        )

        let insights = [
            Insight(
                kind: .goal,
                title: "Half marathon in April",
                detail: "Your weekly distance went from 8 to 14 km in six weeks. Two of your three missed runs came after a meeting that ran past 7 pm.",
                status: "On pace",
                chart: .init(style: .trend, unit: "km",
                             points: weeks([8, 11, 12, 10, 13, 14]), target: 20,
                             whatIf: .init(label: "Runs a week", current: 3, lower: 2, upper: 5,
                                           effect: 5, drift: 1, horizon: 8)),
                confidence: .fairlySure,
                basis: "9 runs you mentioned",
                evidence: [
                    .init(source: .you, text: "You set this goal on 2 October"),
                    .init(source: .chat, text: "Runs you mentioned in 9 chats"),
                    .init(source: .chat, text: "Late meetings mentioned on 3 missed days"),
                ],
                nextStep: .init(label: "Plan around late meetings",
                                request: "When I have a meeting after 7 pm, move that day's run to the morning and remind me the night before.")
            ),
            Insight(
                kind: .goal,
                title: "Conversational Italian",
                detail: "Practice fell from about an hour a week to 15 minutes after your new job started on 19 October.",
                status: "Slipping",
                statusNeedsYou: true,
                chart: .init(style: .trend, unit: "min",
                             points: weeks([60, 55, 40, 20, 10, 15]), target: 60,
                             whatIf: .init(label: "Lessons a week", current: 1, lower: 0, upper: 5,
                                           effect: 15, horizon: 6)),
                confidence: .fairlySure,
                basis: "11 chats",
                evidence: [
                    .init(source: .you, text: "You set this goal on 2 October"),
                    .init(source: .chat, text: "Lessons you mentioned in 11 chats"),
                    .init(source: .chat, text: "New job started 19 October, from a chat that day"),
                ],
                nextStep: .init(label: "Find two short slots",
                                request: "Find me two 20-minute slots a week for Italian and remind me before each one.")
            ),
            Insight(
                kind: .change,
                title: "You've started cooking",
                detail: "Recipes went from 3 saves in September to 12 so far in November, and you asked twice about kitchen knives.",
                confidence: .hunch,
                basis: "15 saves",
                evidence: [
                    .init(source: .feed, text: "15 recipes saved from Feed since 1 September"),
                    .init(source: .chat, text: "Two chats about kitchen knives"),
                ],
                nextStep: .init(label: "More weeknight recipes",
                                request: "Add quick weeknight cooking to my Feed.")
            ),
            Insight(
                kind: .aboutYou,
                title: "Phone calls are where things stall",
                detail: "Tasks that need a call wait about six times longer than ones done by email. Money tasks are the ones you finish fastest.",
                chart: .init(style: .bars, unit: "days to finish",
                             points: [.init(label: "Email", value: 1.5), .init(label: "Online form", value: 2),
                                      .init(label: "Phone call", value: 9)],
                             highlight: 2,
                             whatIf: .init(label: "Calls Steward tries by email first", current: 0,
                                           lower: 0, upper: 4, effect: -1.875)),
                confidence: .sure,
                basis: "18 tasks",
                evidence: [
                    .init(source: .task, text: "18 finished tasks, timed from start to done"),
                    .init(source: .task, text: "4 of them needed a phone call"),
                ],
                nextStep: .init(label: "Try email first",
                                request: "When a task needs a phone call, try email first for me.")
            ),
            Insight(
                kind: .aboutYou,
                title: "You keep more than you read",
                detail: "You saved 23 finds since October and opened 4. All four were under 10 minutes long.",
                chart: .init(style: .bars, unit: "finds",
                             points: [.init(label: "Saved", value: 23), .init(label: "Opened", value: 4)],
                             highlight: 1),
                confidence: .sure,
                basis: "23 saves",
                evidence: [
                    .init(source: .feed, text: "23 finds saved, 4 opened, since 2 October"),
                ],
                nextStep: .init(label: "Shorter reads",
                                request: "Keep my Feed finds under 10 minutes.")
            ),
        ]

        let wins = [
            Win(title: "Refund from Northwind Air", date: day(-11), amount: 186, proof: .owner),
            Win(title: "Cancelled StreamBox", date: day(-17), monthly: 13.99, proof: .company),
            Win(title: "Double charge at FitWorld reversed", date: day(-24), amount: 49, proof: .company),
            Win(title: "Passport appointment booked", date: day(-30), proof: .owner),
        ]

        let known = [
            Known(text: "Training for a half marathon in April", source: "You said in a chat", isGuess: false),
            Known(text: "Learning Italian", source: "You said in a chat", isGuess: false),
            Known(text: "Lives in Berlin", source: "From your gym task", isGuess: false),
            Known(text: "Started a new job on 19 October", source: "From a chat that day", isGuess: false),
            Known(text: "Gets admin done on Sunday evenings", source: "From 14 tasks", isGuess: true),
            Known(text: "Prefers email to phone calls", source: "From 18 tasks", isGuess: true),
            Known(text: "Cooking more at home", source: "From 15 Feed saves", isGuess: true),
        ]

        return InsightsModel(
            weekOf: now.startOfWeek,
            readSummary: "Steward read 14 chats, 9 tasks and 31 Feed reactions this week.",
            lead: lead, insights: insights, wins: wins, winsSince: day(-43),
            known: known, topics: InsightsModel.defaultTopics, isSample: true
        )
    }
}
