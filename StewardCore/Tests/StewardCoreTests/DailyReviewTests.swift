import Foundation
import Testing
@testable import StewardCore

private let berlin: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}()

/// Saturday 14 November 2026, 09:00 in Berlin.
private let now = berlin.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9))!

private func insight(_ title: String, kind: String = "about_you", evidence: [JSONValue]? = nil,
                     extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = [
        "kind": .string(kind),
        "title": .string(title),
        "detail": .string("Something specific about \(title.lowercased())."),
        "confidence": .string("fairly_sure"),
        "basis": .string("9 tasks"),
        "evidence": .array(evidence ?? [.object(["source": .string("task"), "text": .string("9 of 14 tasks on a Sunday")])]),
    ]
    object.merge(extra) { $1 }
    return .object(object)
}

private func submit(insights: [JSONValue], nudges: [JSONValue] = []) -> AssistantTurn {
    AssistantTurn(toolCalls: [ToolCall(id: "r1", name: "submit_review",
                                       arguments: ["insights": .array(insights), "nudges": .array(nudges)])])
}

@Test func reviewMakesOneCallWithAStableSystemPromptAndTheReviewTool() async throws {
    let model = ReviewRecordingModel(turn: submit(insights: [insight("Sunday evening is when you get things done", extra: [
        "lead": .bool(true),
        "offer": .object(["label": .string("Line up Sundays"), "request": .string("Every Sunday at 6 pm, show me what's waiting.")]),
        "remember": .string("Gets admin done on Sunday evenings"),
    ])]))
    let review = DailyReview(model: model, calendar: berlin, now: { now })
    let input = DailyReview.Input(memory: Memory(), goals: ["Half marathon in April"], openTasks: ["Plan dinner: Steward asks: how many?"],
                             chats: ["Plan dinner for 6"], calendar: nil, reminders: ["Passport form, due Fri 21 Nov"])
    let result = try await review.run(input)

    #expect(await model.calls == 1)
    let seen = try #require(await model.seen.first)
    #expect(seen.system == TaskSpec.reviewSystem)
    #expect(!seen.system.contains("2026"))
    #expect(seen.tools == ["submit_review"])
    #expect(seen.message.contains("Saturday 2026-11-14T09:00 (Europe/Berlin)"))
    #expect(seen.message.contains("- Half marathon in April"))
    #expect(seen.message.contains("Calendar, next 14 days:\n" + TaskSpec.reviewWording.notConnected))
    #expect(seen.message.contains("Health and sleep, Mood, Relationships"))

    #expect(result.ranAt == now)
    #expect(result.read == .init(chats: 1, tasks: 1, calendar: nil, reminders: 1))
    let found = try #require(result.insights.first)
    #expect(found.kind == .aboutYou)
    #expect(found.lead)
    #expect(found.confidence == .fairlySure)
    #expect(found.offer?.label == "Line up Sundays")
    #expect(found.memoryNote == "Gets admin done on Sunday evenings")
}

@Test func theReviewToolOffersOnlyChartsInsideInsights() throws {
    guard case .object(let schema) = TaskSpec.reviewTool.parameters,
          case .object(let properties)? = schema["properties"],
          case .object(let insights)? = properties["insights"],
          case .object(let item)? = insights["items"],
          case .object(let itemProperties)? = item["properties"],
          case .object(let chart)? = itemProperties["chart"],
          case .object(let chartProperties)? = chart["properties"],
          case .object(let type)? = chartProperties["type"]
    else { Issue.record("schema shape"); return }
    #expect(type["enum"] == .array([.string("chart")]))
    #expect(chartProperties["options"] == nil)
    #expect(chartProperties["points"] != nil)
}

@Test func insightsWithoutEvidenceOrWithUnknownFieldsAreDropped() {
    let answer: JSONValue = .object(["insights": .array([
        insight("No evidence at all", evidence: []),
        insight("Evidence with a made-up source", evidence: [.object(["source": .string("rumour"), "text": .string("x")])]),
        insight("Unknown kind", kind: "prophecy"),
        insight("Blank evidence", evidence: [.object(["source": .string("chat"), "text": .string("   ")])]),
        .object(["kind": .string("goal"), "title": .string("No confidence"), "detail": .string("d"), "basis": .string("b"),
                 "evidence": .array([.object(["source": .string("you"), "text": .string("You said so")])])]),
        insight("Kept"),
        .string("not even an object"),
    ])])
    let parsed = DailyReview.parse(answer, memory: Memory(), now: now, calendar: berlin)
    #expect(parsed.insights.map(\.title) == ["Kept"])
}

@Test func insightsTouchingATopicTurnedOffAreDropped() {
    var memory = Memory()
    memory.setTopic("Money and spending", allowed: false)
    let answer: JSONValue = .object(["insights": .array([
        // Labelled by the model.
        insight("Late nights before deadlines", extra: ["topic": .string("health and sleep")]),
        // Not labelled, but the words give it away.
        insight("You sleep less after late meetings"),
        insight("Takeaways ate your Lisbon savings"),
        insight("Offer gives it away", extra: ["offer": .object(["label": .string("Track my mood"), "request": .string("Ask how I feel")])]),
        insight("Still on pace for April", kind: "goal"),
    ])])
    let parsed = DailyReview.parse(answer, memory: memory, now: now, calendar: berlin)
    #expect(parsed.insights.map(\.title) == ["Still on pace for April"])

    // Turned on, the same finding stays.
    memory.setTopic("Health and sleep", allowed: true)
    let again = DailyReview.parse(.object(["insights": .array([insight("You sleep less after late meetings")])]), memory: memory, now: now)
    #expect(again.insights.count == 1)
}

@Test func reviewSanitizesTextChartsOffersAndLeads() {
    let long = String(repeating: "a", count: 500)
    let answer: JSONValue = .object(["insights": .array([
        insight("First\nlead", extra: [
            "lead": .bool(true), "status": .string("On pace"),
            "chart": .object(["style": .string("columns"), "unit": .string("tasks"),
                              "points": .array([.object(["label": .string("Sat"), "value": .number(1)]),
                                                .object(["label": .string("Sun"), "value": .number(9)])]),
                              "highlight": .number(1)]),
            "offer": .object(["label": .string("Only a label")]),
        ]),
        insight("Second lead", kind: "goal", extra: [
            "lead": .bool(true), "status": .string("Slipping"), "status_needs_you": .bool(true), "detail": .string(long),
            "chart": .object(["style": .string("trend"), "unit": .string("km"), "points": .array([.object(["label": .string("Only one"), "value": .number(3)])])]),
        ]),
        insight("first lead"),
    ])])
    let parsed = DailyReview.parse(answer, memory: Memory(), now: now, calendar: berlin)
    #expect(parsed.insights.map(\.title) == ["First lead", "Second lead"])
    let first = parsed.insights[0], second = parsed.insights[1]
    #expect(first.lead && !second.lead)
    // Status is for goals only.
    #expect(first.status == nil)
    #expect(second.status == "Slipping" && second.statusNeedsYou)
    #expect(first.chart?.points.count == 2 && first.chart?.highlight == 1)
    // A one-point chart isn't a chart.
    #expect(second.chart == nil)
    #expect(first.offer == nil)
    #expect(second.detail.count == 320)
}

@Test func stoppedFindingsDoNotComeBack() {
    let answer: JSONValue = .object(["insights": .array([insight("You keep more than you read"), insight("Mornings are when you answer")])])
    let parsed = DailyReview.parse(answer, memory: Memory(), stopped: ["You keep more than you read."], now: now, calendar: berlin)
    #expect(parsed.insights.map(\.title) == ["Mornings are when you answer"])
}

@Test func nudgesMustFallWithinTheNextTwoWeeks() {
    func nudge(_ title: String, _ at: String) -> JSONValue {
        .object(["title": .string(title), "body": .string("Fill it in tonight."), "at": .string(at)])
    }
    let answer: JSONValue = .object(["insights": .array([]), "nudges": .array([
        nudge("Passport form due Friday", "2026-11-20T18:00"),
        nudge("Already past", "2026-11-13T18:00"),
        nudge("Too far ahead", "2026-12-20T18:00"),
        nudge("Not a date", "next Tuesday"),
        nudge("Therapist appointment", "2026-11-18T08:00"),
        nudge("Book the dinner table", "2026-11-15T10:30"),
        nudge("Renew the parking permit", "2026-11-16T10:30"),
        nudge("One too many", "2026-11-17T10:30"),
    ])])
    let parsed = DailyReview.parse(answer, memory: Memory(), now: now, calendar: berlin)
    #expect(parsed.nudges.map(\.title) == ["Passport form due Friday", "Book the dinner table", "Renew the parking permit"])
    let at = berlin.dateComponents([.day, .hour, .minute], from: parsed.nudges[0].at)
    #expect(at.day == 20 && at.hour == 18 && at.minute == 0)
}

@Test func aReviewAnsweredInWordsStillReadsAndNothingReadableFails() async throws {
    let words = AssistantTurn(text: "Here you go: {\"insights\": [], \"nudges\": []}")
    let empty = try await DailyReview(model: ScriptedModelClient([words]), calendar: berlin, now: { now }).run(DailyReview.Input(memory: Memory()))
    #expect(empty.insights.isEmpty)

    await #expect(throws: DailyReview.NothingUsable.self) {
        _ = try await DailyReview(model: ScriptedModelClient([AssistantTurn(text: "I noticed nothing much.")]), now: { now })
            .run(DailyReview.Input(memory: Memory()))
    }
}

@Test func theScheduleRunsOnceADayAndBreaksAfterThreeFailures() {
    var schedule = ReviewSchedule()
    #expect(schedule.isDue(at: now, calendar: berlin))
    schedule.started(at: now)
    // Same day, and too soon.
    #expect(!schedule.isDue(at: now.addingTimeInterval(10 * 3_600), calendar: berlin))
    // The next day but under 20 hours: still not.
    #expect(!schedule.isDue(at: now.addingTimeInterval(19 * 3_600), calendar: berlin))
    #expect(schedule.isDue(at: now.addingTimeInterval(21 * 3_600), calendar: berlin))

    var day = now
    for _ in 0..<3 {
        day = day.addingTimeInterval(86_400)
        #expect(schedule.isDue(at: day, calendar: berlin))
        schedule.started(at: day)
        schedule.failed(at: day)
    }
    let tomorrow = day.addingTimeInterval(86_400)
    #expect(!schedule.isDue(at: tomorrow, calendar: berlin))
    #expect(schedule.nextDue(after: tomorrow) == day.addingTimeInterval(ReviewSchedule.pause))
    #expect(schedule.isDue(at: day.addingTimeInterval(ReviewSchedule.pause + 3_600), calendar: berlin))
    schedule.succeeded(at: day)
    #expect(schedule.failures == 0 && schedule.pausedUntil == nil)
}

@Test func quietHoursHoldNudgesUntilTheWindowEnds() {
    let quiet = QuietHours(from: 22 * 60, to: 8 * 60)
    func at(_ day: Int, _ hour: Int) -> Date { berlin.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
    #expect(quiet.deliveryTime(for: at(14, 12), calendar: berlin) == at(14, 12))
    #expect(quiet.deliveryTime(for: at(14, 23), calendar: berlin) == at(15, 8))
    #expect(quiet.deliveryTime(for: at(15, 6), calendar: berlin) == at(15, 8))
    let afternoon = QuietHours(from: 13 * 60, to: 15 * 60)
    #expect(afternoon.deliveryTime(for: at(14, 14), calendar: berlin) == at(14, 15))
}

@Test func reactionsFeedMemory() {
    var memory = Memory()
    guard case .added(let guess) = memory.remember(.init(text: "Prefers email to calls", kind: .guess, source: .task, evidence: "From 18 tasks", confidence: .sure)) else {
        Issue.record("not added"); return
    }
    memory.doubt(guess.id)
    #expect(memory.items[0].confidence == .fairlySure)
    memory.doubt(guess.id)
    memory.doubt(guess.id)
    #expect(memory.items.isEmpty)
    memory.remember(.init(text: "Lives in Berlin", kind: .fact, source: .owner, evidence: "You said"))
    memory.doubt(memory.items[0].id)
    #expect(memory.facts.count == 1)
    #expect(memory.item(matching: "lives in berlin.")?.text == "Lives in Berlin")
}

@Test func theReviewRecordStaysReadableAndForgetsOldReactions() throws {
    let first = ReviewInsight(kind: .change, title: "You've started cooking", detail: "d", confidence: .hunch, basis: "b",
                              evidence: [.init(source: .chat, text: "t")])
    var record = ReviewRecord(result: ReviewResult(ranAt: now, insights: [first], nudges: [], read: .init(chats: 1, tasks: 0)))
    record.reactions[first.id.uuidString] = .confirmed
    record.stop(first)
    let url = FileManager.default.temporaryDirectory.appending(path: "review-\(UUID().uuidString).json")
    let store = ReviewStore(url: url)
    try store.save(record)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"\(first.id.uuidString)\" : \"confirmed\""))
    #expect(try store.load() == record)

    record.show(ReviewResult(ranAt: now, insights: [], nudges: [], read: .init(chats: 0, tasks: 0)))
    #expect(record.reactions.isEmpty && record.hidden.isEmpty)
    #expect(record.stopped == ["You've started cooking"])
}

/// Records what the review sent, and answers once.
private actor ReviewRecordingModel: ModelClient {
    struct Seen { var system: String; var message: String; var tools: [String] }
    let turn: AssistantTurn
    private(set) var seen: [Seen] = []
    var calls: Int { seen.count }

    init(turn: AssistantTurn) { self.turn = turn }

    func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        guard case .user(let message)? = messages.first else { throw ScriptedModelClient.ScriptExhausted() }
        seen.append(Seen(system: system, message: message, tools: tools.map(\.name)))
        return turn
    }
}
