import Foundation
import Testing
@testable import StewardCore

@Test func parsesHeadingsListsQuotesAndParagraphs() {
    let text = """
    ## Before you move

    Give notice first.
    It sets every other date.

    **What to pack:**
    - Documents
    - Keys
      for the garage
    1. Book the van
    2) Tell the landlord
    > Deposit back within 10 days.
    """
    #expect(ReplyText.parse(text) == [
        .heading(level: 2, text: "Before you move"),
        .paragraph("Give notice first.\nIt sets every other date."),
        .heading(level: 3, text: "What to pack"),
        .bullets(["Documents", "Keys for the garage"]),
        .numbered(["Book the van", "Tell the landlord"]),
        .quote("Deposit back within 10 days."),
    ])
}

@Test func shortFlatRepliesStayBubbles() {
    #expect(!ReplyText.isStructured("On it. I'll check your notice period first."))
    #expect(!ReplyText.isStructured("I paid **£39** on 4 Nov."))
    #expect(!ReplyText.isStructured("-5 degrees tomorrow, so take a coat."))
    #expect(ReplyText.isStructured("Three things:\n- One\n- Two"))
    let long = String(repeating: "A sentence that goes on. ", count: 10)
    #expect(ReplyText.isStructured("\(long)\n\n\(long)"))
    #expect(!ReplyText.isStructured(long))
}

@Test func plainDropsMarks() {
    #expect(ReplyText.plain("## Plan\n- **Book** the [van](https://example.com)\n- Pack") == "Plan Book the van, Pack")
}

@Test func checklistFromAModelStartsUnticked() throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data("""
    [{"type": "checklist", "title": "Before you move", "items": [
      {"title": "Book the van", "done": true}, {"title": "  "}, {"title": "Give notice", "when": "now"}
    ]}]
    """.utf8))
    let blocks = ReplyBlock.fromModel(value)
    #expect(blocks == [.checklist(.init(title: "Before you move", items: [.init(title: "Book the van"), .init(title: "Give notice")]))])
}

@Test func blocksReadAsWordsForTheModel() {
    let list = ReplyBlock.checklist(.init(title: "Move", items: [.init(title: "Van", done: true), .init(title: "Keys")]))
    #expect(list.plainText == "[Move, 1 of 2 done: [x] Van; [ ] Keys]")
    let data = try? JSONEncoder().encode(list)
    #expect(data.flatMap { try? JSONDecoder().decode(ReplyBlock.self, from: $0) } == list)
}
