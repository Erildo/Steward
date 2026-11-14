import Foundation
import Testing
@testable import StewardCore

@Test func taskSpecGivesBlocksToTheToolsThatEndATurn() {
    let specs = TaskSpec.toolSpecs()
    #expect(specs.map(\.name) == TaskSpec.tools.map(\.name))
    #expect(Set(specs.map(\.name)).isSuperset(of: TaskSpec.finalTools))
    for spec in specs where !TaskSpec.blockTools.contains(spec.name) {
        guard case .object(let schema) = spec.parameters, case .object(let properties)? = schema["properties"] else { continue }
        #expect(properties["blocks"] == nil, "\(spec.name) shouldn't take blocks")
    }
    for spec in specs where TaskSpec.blockTools.contains(spec.name) {
        guard case .object(let schema) = spec.parameters, case .object(let properties)? = schema["properties"] else {
            Issue.record("\(spec.name) has no properties")
            continue
        }
        #expect(properties["blocks"] == ReplyBlock.modelSchema, "\(spec.name) lacks blocks")
    }
}

@Test func taskSpecLeavesOutToolsNotOffered() {
    let names = TaskSpec.toolSpecs(only: ["ask_owner", "finish"]).map(\.name)
    #expect(names == ["ask_owner", "finish"])
}

@Test func taskSystemPromptIsStableForTheCache() {
    #expect(!TaskSpec.system.contains("{"))
}

@Test func taskContextFillsEveryPlaceholder() {
    let values = TaskSpec.placeholders.reduce(into: [String: String]()) { $0[$1] = "<\($1)>" }
    let text = TaskSpec.context(values)
    #expect(!text.contains("{"))
    for key in TaskSpec.placeholders { #expect(text.contains("<\(key)>")) }
}
