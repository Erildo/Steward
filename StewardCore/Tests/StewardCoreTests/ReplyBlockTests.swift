import Foundation
import Testing
@testable import StewardCore

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Test func blocksRoundTripWithATypeKey() throws {
    let blocks: [ReplyBlock] = [
        .choices(.init(options: ["Yes", "Not yet"])),
        .field(.init(label: "Membership email", kind: .email)),
        .steps(.init(title: "Cancel gym", steps: [.init(title: "Write", state: .done), .init(title: "Send", state: .waiting)])),
        .deadline(.init(title: "6 days left", progress: 0.8, rows: [.init(label: "Last day", value: "Nov 18")])),
        .draft(.init(to: "a@b.example", subject: "Hi", body: "Body", caseID: UUID())),
        .compare(.init(title: "Plans", options: [.init(name: "A", detail: "a", isPick: true), .init(name: "B", detail: "b")])),
        .timeline(.init(title: "Lisbon", items: [.init(when: "Day 1", title: "Alfama")])),
        .proof(.init(headline: "Cancelled", quote: "We confirm.", source: "Gym", date: Date(timeIntervalSince1970: 0))),
    ]
    let data = try JSONEncoder().encode(blocks)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains(#""type":"choices""#))
    #expect(try JSONDecoder().decode([ReplyBlock].self, from: data) == blocks)
}

@Test func modelBlocksKeepOnlyWhatAModelMayShow() throws {
    let value = try json("""
    [
      {"type": "choices", "options": ["Yes", "yes", "  ", "No", "Maybe", "Later", "Never"]},
      {"type": "draft", "to": "x@y.example", "subject": "s", "body": "b", "status": "approved"},
      {"type": "proof", "headline": "Done"},
      {"type": "nonsense"},
      {"type": "compare", "title": "Deals", "options": [
        {"name": "A", "detail": "cheap", "isPick": true},
        {"name": "B", "detail": "fast", "isPick": true}
      ]}
    ]
    """)
    let blocks = ReplyBlock.fromModel(value)
    #expect(blocks.count == 2)
    #expect(blocks.first == .choices(.init(options: ["Yes", "No", "Maybe", "Later"])))
    guard case .compare(let compare) = blocks.last else { Issue.record("expected compare"); return }
    #expect(compare.options.map(\.isPick) == [true, false])
}

@Test func modelBlocksDropEmptyOnesAndCapTheCount() throws {
    let value = try json("""
    [
      {"type": "compare", "title": "One option is not a comparison", "options": [{"name": "A", "detail": "a"}]},
      {"type": "timeline", "title": "T", "items": []},
      {"type": "field", "label": "Email", "kind": "email"},
      {"type": "choices", "options": ["A"]},
      {"type": "deadline", "title": "Soon", "progress": 4, "rows": []},
      {"type": "choices", "options": ["B"]}
    ]
    """)
    let blocks = ReplyBlock.fromModel(value)
    #expect(blocks.map(\.kind) == [.field, .choices, .deadline])
    guard case .deadline(let deadline) = blocks.last else { Issue.record("expected deadline"); return }
    #expect(deadline.progress == 1)
    #expect(ReplyBlock.fromModel(nil).isEmpty)
    #expect(ReplyBlock.fromModel(.string("x")).isEmpty)
}
