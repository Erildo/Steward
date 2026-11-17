import Foundation
import Testing
@testable import StewardCore

private func call(_ name: String, _ args: [String: JSONValue], id: String = UUID().uuidString) -> ToolCall {
    ToolCall(id: id, name: name, arguments: args)
}

@Test func rememberRunsThenTheTurnEndsOnAFinalTool() async throws {
    let model = ScriptedModelClient([
        AssistantTurn(toolCalls: [call("remember", ["text": .string("Lives in Lisbon"), "kind": .string("fact"), "evidence": .string("You said so")])]),
        AssistantTurn(text: "Here you go.", toolCalls: [call("finish", ["result": .string("A plan")])]),
    ])
    var memory: Memory? = Memory()
    let outcome = try await TaskLoop(model: model).run(messages: [.user("go")], memory: &memory, ownerJustSpoke: true)
    #expect(outcome.kept.map(\.text) == ["Lives in Lisbon"])
    #expect(outcome.kept.first?.kind == .fact)
    guard case .call(let final?, let text) = outcome.end else { Issue.record("no final call"); return }
    #expect(final.name == "finish")
    #expect(text == "Here you go.")
    #expect(await model.calls == 2)
}

@Test func withoutTheOwnersWordAFactIsKeptAsAGuess() async throws {
    let model = ScriptedModelClient([
        AssistantTurn(toolCalls: [
            call("remember", ["text": .string("Prefers trains"), "kind": .string("fact"), "evidence": .string("x")]),
            call("wait", ["days": .number(2), "note": .string("check again")]),
        ]),
    ])
    var memory: Memory? = Memory()
    let outcome = try await TaskLoop(model: model).run(messages: [.user("go")], memory: &memory, ownerJustSpoke: false)
    #expect(outcome.kept.first?.kind == .guess)
    #expect(memory?.guesses.map(\.text) == ["Prefers trains"])
}

@Test func aTurnThatNeverEndsStopsAfterMaxSteps() async throws {
    let looping = (0..<3).map { i in AssistantTurn(toolCalls: [call("remember", ["text": .string("Thing \(i)"), "kind": .string("guess"), "evidence": .string("x")])]) }
    var memory: Memory? = Memory()
    let outcome = try await TaskLoop(model: ScriptedModelClient(looping), maxSteps: 3).run(messages: [.user("go")], memory: &memory, ownerJustSpoke: true)
    #expect(outcome.end == .stuck)
}

@Test func rememberIsNotOfferedWithoutMemory() async throws {
    #expect(!TaskLoop.tools(withMemory: false).map(\.name).contains("remember"))
    #expect(TaskLoop.tools(withMemory: true).map(\.name).contains("remember"))
}

@Test func plainWordsEndTheTurn() async throws {
    var memory: Memory? = nil
    let outcome = try await TaskLoop(model: ScriptedModelClient([AssistantTurn(text: "Hi")])).run(messages: [.user("go")], memory: &memory, ownerJustSpoke: true)
    #expect(outcome.end == .call(nil, text: "Hi"))
}

@Test func trackTaskNamesTheOutcomeAndTheTurnCarriesOn() async throws {
    let model = ScriptedModelClient([
        AssistantTurn(toolCalls: [call("track_task", ["title": .string("Find a dentist that takes my insurance")])]),
        AssistantTurn(toolCalls: [call("ask_owner", ["question": .string("Which insurer?")])]),
    ])
    var memory: Memory? = nil
    let outcome = try await TaskLoop(model: model).run(messages: [.user("go")], memory: &memory, ownerJustSpoke: true)
    #expect(outcome.tracked == "Find a dentist that takes my insurance")
    guard case .call(let final?, _) = outcome.end else { Issue.record("no final call"); return }
    #expect(final.name == "ask_owner")
    #expect(await model.calls == 2)
}

@Test func aPlainAnswerTracksNothing() async throws {
    var memory: Memory? = nil
    let outcome = try await TaskLoop(model: ScriptedModelClient([AssistantTurn(text: "About 10%.")])).run(messages: [.user("tip?")], memory: &memory, ownerJustSpoke: true)
    #expect(outcome.tracked == nil)
}

@Test func trackTaskIsAlwaysOffered() {
    #expect(TaskLoop.tools(withMemory: false).map(\.name).contains("track_task"))
}
