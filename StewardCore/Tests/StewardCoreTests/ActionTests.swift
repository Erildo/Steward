import Foundation
import Testing
@testable import StewardCore

private let berlin = TimeZone(identifier: "Europe/Berlin")!
private let now = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!

private func call(_ name: String, _ args: [String: JSONValue]) -> ToolCall {
    ToolCall(id: UUID().uuidString, name: name, arguments: args)
}

private func parse(_ name: String, _ args: [String: JSONValue]) -> Result<ReplyBlock.Action, ActionProposal.ProposalError> {
    ActionProposal.parse(call(name, args), now: now, timeZone: berlin)
}

@Test func anEventAtLocalTimeDefaultsToOneHour() throws {
    let action = try parse("propose_event", ["title": .string("Dinner with Ana"), "start": .string("2026-11-20T19:00")]).get()
    guard case .event(let e) = action.payload else { Issue.record("not an event"); return }
    #expect(e.start == ISO8601DateFormatter().date(from: "2026-11-20T18:00:00Z"))
    #expect(e.end.timeIntervalSince(e.start) == 3_600)
    #expect(!e.allDay)
    #expect(action.status == .pending)
}

@Test func aDateAloneIsAnAllDayEvent() throws {
    let action = try parse("propose_event", ["title": .string("Lisbon"), "start": .string("2026-12-01"), "end": .string("2026-12-04")]).get()
    guard case .event(let e) = action.payload else { Issue.record("not an event"); return }
    #expect(e.allDay)
    #expect(e.end.timeIntervalSince(e.start) == 3 * 86_400)
}

@Test func badEventsAreRefusedWithAReason() {
    for args: [String: JSONValue] in [
        ["title": .string(""), "start": .string("2026-11-20T19:00")],
        ["title": .string("x"), "start": .string("next Friday")],
        ["title": .string("x"), "start": .string("2026-11-20T19:00"), "end": .string("2026-11-20T18:00")],
        ["title": .string("x"), "start": .string("2025-01-01T10:00")],
    ] {
        guard case .failure(let error) = parse("propose_event", args) else { Issue.record("accepted \(args)"); continue }
        #expect(!error.message.isEmpty)
    }
}

@Test func anErrandNeedsTheCompanysOwnAddressAndAGoal() throws {
    let ok = try parse("propose_errand", [
        "errand": .string("cancel"), "company_name": .string("FitWorld"), "company_email": .string("Members@FitWorld.example"),
        "goal": .string("Cancelled, in writing"), "will_not": .array([.string("a pause")]),
    ]).get()
    guard case .errand(let e) = ok.payload else { Issue.record("not an errand"); return }
    #expect(e.companyEmail == "members@fitworld.example")
    #expect(e.willNot == ["a pause"])
    #expect(throws: ActionProposal.ProposalError.self) {
        try parse("propose_errand", ["errand": .string("cancel"), "company_name": .string("FitWorld"),
                                     "company_email": .string("fitworld website"), "goal": .string("x")]).get()
    }
    #expect(throws: ActionProposal.ProposalError.self) {
        try parse("propose_errand", ["errand": .string("buy"), "company_name": .string("A"), "company_email": .string("a@b.co"), "goal": .string("x")]).get()
    }
}

@Test func anActionRoundTripsAsABlockAndReadsBackInWords() throws {
    let action = try parse("propose_reminder", ["title": .string("Book Sintra tickets"), "due": .string("2026-11-25")]).get()
    let block = ReplyBlock.action(action)
    let data = try JSONEncoder().encode(block)
    #expect(try JSONDecoder().decode(ReplyBlock.self, from: data) == block)
    #expect(block.plainText.contains("Book Sintra tickets"))
    #expect(block.plainText.contains("waiting for the owner's yes"))
}

@Test func aModelCantSendAnActionBlockItself() throws {
    let action = try parse("propose_reminder", ["title": .string("x")]).get()
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ReplyBlock.action(action)))
    #expect(ReplyBlock.fromModel(.array([json])).isEmpty)
}

@Test func aProposalEndsTheTurnOnlyWhenAllowedAndValid() async throws {
    let model = ScriptedModelClient([
        // Not allowed on this phone: goes back to the model.
        AssistantTurn(toolCalls: [call("propose_errand", ["errand": .string("cancel"), "company_name": .string("A"), "company_email": .string("a@b.co"), "goal": .string("x")])]),
        // Allowed but malformed: goes back too.
        AssistantTurn(toolCalls: [call("propose_event", ["title": .string("Dinner"), "start": .string("Friday")])]),
        AssistantTurn(text: "Shall I block it?", toolCalls: [call("propose_event", ["title": .string("Dinner"), "start": .string("2026-11-20T19:00")])]),
    ])
    var memory: Memory? = nil
    let outcome = try await TaskLoop(model: model).run(messages: [.user("go")], memory: &memory, ownerJustSpoke: true,
                                                       proposals: ["propose_event"], now: now)
    guard case .proposal(let action, let text) = outcome.end else { Issue.record("no proposal: \(outcome.end)"); return }
    #expect(action.payload.kind == "event")
    #expect(text == "Shall I block it?")
    #expect(await model.calls == 3)
    #expect(!TaskLoop.tools(withMemory: false, proposals: ["propose_event"]).map(\.name).contains("propose_errand"))
}
