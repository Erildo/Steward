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
    /// What Steward knows, shared with Tasks and the Steward tab.
    let memory: MemoryBook
    let isSample: Bool

    private(set) var reactions: [UUID: Reaction] = [:]
    private(set) var hidden: Set<UUID> = []
    /// Findings whose charts have drawn in once this session.
    private(set) var drawn: Set<UUID> = []
    /// The finding last stopped, for a few seconds of undo.
    private(set) var lastHidden: Insight?

    init(weekOf: Date, readSummary: String?, lead: Insight?, insights: [Insight], wins: [Win],
         winsSince: Date?, memory: MemoryBook = .shared, isSample: Bool) {
        self.weekOf = weekOf
        self.readSummary = readSummary
        self.lead = lead
        self.insights = insights
        self.wins = wins
        self.winsSince = winsSince
        self.memory = memory
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

    /// Everything Steward knows, for the owner's eyes: topics turned off too.
    var known: [Known] {
        memory.memory.items.reversed().map { Known(id: $0.id, text: $0.text, source: $0.evidence, isGuess: $0.kind == .guess) }
    }

    /// The topics Steward may notice. Writing turns them on or off in memory.
    var topics: [Topic] {
        get {
            memory.memory.topics.map { Topic(name: $0.name, systemImage: Self.topicImage($0.name), allowed: $0.allowed) }
        }
        set {
            memory.update { m in for topic in newValue { m.setTopic(topic.name, allowed: topic.allowed) } }
        }
    }

    func forget(_ item: Known) {
        memory.update { $0.forget(item.id) }
    }

    /// "That's right": the owner confirms a guess, which makes it a fact.
    func confirm(_ item: Known) {
        memory.update { $0.confirm(item.id) }
    }

    func forgetEverything() {
        memory.update { $0.forgetEverything() }
    }

    var facts: [Known] { known.filter { !$0.isGuess } }
    var guesses: [Known] { known.filter(\.isGuess) }

    /// Money back across the wins, and money no longer going out each month.
    var totalBack: Decimal { wins.compactMap(\.amount).reduce(0, +) }
    var totalMonthly: Decimal { wins.compactMap(\.monthly).reduce(0, +) }

    /// Everything Steward knows, as plain text the owner can keep.
    var exportText: String { memory.memory.exportText() }

    static func topicImage(_ name: String) -> String {
        switch name {
        case "Health and sleep": "heart"
        case "Mood": "face.smiling"
        case "Relationships": "person.2"
        case "Money and spending": "creditcard"
        default: "circle"
        }
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
                      winsSince: nil, isSample: false)
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
                kind: .goal,
                title: "€3,000 for Lisbon in May",
                detail: "You've put aside €1,300. May needs about €350 a month from here, and November is at €200. Takeaways went from one a week to four since September.",
                status: "Behind",
                statusNeedsYou: true,
                chart: .init(style: .trend, unit: "euros",
                             points: [.init(label: "August", value: 400), .init(label: "September", value: 350),
                                      .init(label: "October", value: 350), .init(label: "November", value: 200)],
                             target: 350,
                             whatIf: .init(label: "Takeaways a week", current: 4, lower: 0, upper: 6,
                                           effect: -50, horizon: 5, period: "month")),
                confidence: .fairlySure,
                basis: "4 balances you shared",
                evidence: [
                    .init(source: .you, text: "You set this goal on 12 August"),
                    .init(source: .chat, text: "Savings balances you mentioned in 4 chats"),
                    .init(source: .task, text: "Takeaway orders from 3 delivery receipts Steward filed"),
                ],
                nextStep: .init(label: "Set aside €350 on payday",
                                request: "Remind me on payday to move €350 to my Lisbon savings.")
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
                kind: .change,
                title: "Less is waiting on you",
                detail: "Things that need your answer fell from 9 to 3 since you started handing errands to Steward. Most of what's left is one photo and two yeses.",
                chart: .init(style: .trend, unit: "waiting on you",
                             points: [.init(label: "5 weeks ago", value: 9), .init(label: "4 weeks ago", value: 8),
                                      .init(label: "3 weeks ago", value: 6), .init(label: "2 weeks ago", value: 6),
                                      .init(label: "Last week", value: 4), .init(label: "This week", value: 3)]),
                confidence: .sure,
                basis: "your task list",
                evidence: [
                    .init(source: .task, text: "Tasks marked \"needs you\" each Sunday, for 6 weeks"),
                ],
                nextStep: .init(label: "Clear the last three",
                                request: "Walk me through the three things waiting on me, quickest first.")
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
            Insight(
                kind: .aboutYou,
                title: "Mornings are when you answer",
                detail: "You reply to Steward within about 10 minutes before work, and after a couple of hours in the afternoon.",
                chart: .init(style: .bars, unit: "minutes to reply",
                             points: [.init(label: "Before 9 am", value: 10), .init(label: "Midday", value: 35),
                                      .init(label: "Afternoon", value: 130), .init(label: "Evening", value: 25)],
                             highlight: 0),
                confidence: .fairlySure,
                basis: "41 replies",
                evidence: [
                    .init(source: .chat, text: "41 replies to Steward's questions, timed, since 2 October"),
                ],
                nextStep: .init(label: "Ask me in the morning",
                                request: "Save questions that can wait and ask me before 9 am.")
            ),
            Insight(
                kind: .aboutYou,
                title: "You trust drafts that sound like you",
                detail: "You sent 14 of 20 drafts as written. The 5 you edited were all ones where Steward sounded too formal.",
                chart: .init(style: .bars, unit: "drafts",
                             points: [.init(label: "Sent as written", value: 14), .init(label: "Edited first", value: 5),
                                      .init(label: "Declined", value: 1)],
                             highlight: 0),
                confidence: .sure,
                basis: "20 drafts",
                evidence: [
                    .init(source: .task, text: "20 drafts you approved, edited or declined"),
                    .init(source: .task, text: "Your edits: shorter openings, fewer \"Dear\"s"),
                ],
                nextStep: .init(label: "Write more like me",
                                request: "Write my drafts shorter and less formal, like the ones I edited.")
            ),
        ]

        let wins = [
            Win(title: "Refund from Northwind Air", date: day(-11), amount: 186, proof: .owner),
            Win(title: "Cancelled StreamBox", date: day(-17), monthly: 13.99, proof: .company),
            Win(title: "Double charge at FitWorld reversed", date: day(-24), amount: 49, proof: .company),
            Win(title: "Broadband price rise reversed", date: day(-6), monthly: 8, proof: .company),
            Win(title: "Parking fine appeal accepted", date: day(-14), amount: 60, proof: .company),
            Win(title: "Headphones repaired under warranty", date: day(-20), proof: .owner),
            Win(title: "Passport appointment booked", date: day(-30), proof: .owner),
        ].sorted { $0.date > $1.date }

        return InsightsModel(
            weekOf: now.startOfWeek,
            readSummary: "Steward read 23 chats, 11 tasks and 31 Feed reactions this week.",
            lead: lead, insights: insights, wins: wins, winsSince: day(-43),
            isSample: true
        )
    }
}
