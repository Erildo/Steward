import Foundation
import Testing
@testable import StewardCore

private let day = Date(timeIntervalSince1970: 1_794_268_800)

private func taste() -> TasteProfile {
    TasteProfile(loves: ["Denis Villeneuve films"], curious: ["home espresso"], goals: ["Run a half marathon in spring"])
}

private func card(_ url: String, section: FeedCard.Section = .forYou) -> FeedCard {
    FeedCard(section: section, title: "T \(url)", summary: "", why: "", url: URL(string: url)!, source: "s", topic: "films")
}

@Test func parsesCardsFromFencedReplyAndDropsBadLinks() {
    let raw = """
    Here you go:
    ```json
    {"cards":[
      {"section":"for_you","title":"Villeneuve's next film","summary":"A first look.","why":"You loved Dune.","url":"https://example.com/a","source":"Example","topic":"Villeneuve"},
      {"section":"toward_goals","title":"12-week plan","url":"https://www.runs.example/plan"},
      {"section":"for_you","title":"No link"},
      {"section":"for_you","title":"Not web","url":"javascript:alert(1)"},
      {"section":"sideways","title":"Bad section","url":"https://example.com/b"},
      {"section":"worth_a_look","title":"Duplicate","url":"https://example.com/a"},
      {"section":"worth_a_look","title":"Seen before","url":"https://example.com/old"}
    ]}
    ```
    """
    let cards = FeedComposer.parse(raw, excluding: [URL(string: "https://example.com/old")!])
    #expect(cards.map(\.title) == ["Villeneuve's next film", "12-week plan"])
    #expect(cards[1].source == "runs.example")
    #expect(cards[1].topic == "12-week plan")
    #expect(cards[1].section == .towardGoals)
}

@Test func garbageReplyGivesNoCards() {
    #expect(FeedComposer.parse("Sorry, I can't browse right now.").isEmpty)
    #expect(FeedComposer.parse("{not json}").isEmpty)
}

@Test func briefCarriesTasteSharedReactionsAndShownLinks() {
    var t = taste()
    t.add(shared: [SharedItem(url: URL(string: "https://video.example/v1"), title: "Latte art basics", note: "want to learn this", feeling: .curious, date: day)])
    t.record(Reaction(kind: .less, card: card("https://example.com/x"), date: day))
    let brief = FeedComposer.brief(taste: t, previous: FeedBatch(createdAt: day, cards: [card("https://example.com/y")]))
    #expect(brief.contains("Loves:\n- Denis Villeneuve films"))
    #expect(brief.contains("Goals:\n- Run a half marathon in spring"))
    #expect(brief.contains("Latte art basics [curious] — want to learn this (https://video.example/v1)"))
    #expect(brief.contains("less: T https://example.com/x (films)"))
    #expect(brief.contains("- https://example.com/y"))
}

@Test func composeBuildsBatchAndSkipsWhatWasShown() async throws {
    let reply = #"{"cards":[{"section":"for_you","title":"Old","url":"https://example.com/y"},{"section":"for_you","title":"New","url":"https://example.com/z"}]}"#
    let composer = FeedComposer(model: ScriptedModelClient([AssistantTurn(text: reply)]), now: { day })
    let batch = try await composer.compose(for: taste(), after: FeedBatch(createdAt: day, cards: [card("https://example.com/y")]))
    #expect(batch.cards.map(\.title) == ["New"])
    #expect(batch.createdAt == day)
}

@Test func composeFailsLoudlyWhenNothingUsable() async {
    let composer = FeedComposer(model: ScriptedModelClient([AssistantTurn(text: "no")]), now: { day })
    await #expect(throws: FeedComposer.NothingUsable.self) {
        try await composer.compose(for: taste(), after: nil)
    }
}

@Test func reactionsReplaceEarlierOnesForTheSameCardAndStayCapped() {
    var t = TasteProfile()
    let c = card("https://example.com/a")
    t.record(Reaction(kind: .more, card: c, date: day))
    t.record(Reaction(kind: .less, card: c, date: day))
    #expect(t.reactions.count == 1)
    #expect(t.reactions[0].kind == .less)
    for i in 0..<(TasteProfile.reactionLimit + 5) {
        t.record(Reaction(kind: .more, card: card("https://example.com/\(i)"), date: day))
    }
    #expect(t.reactions.count == TasteProfile.reactionLimit)
}

@Test func savingTogglesByLink() {
    var t = TasteProfile()
    let c = card("https://example.com/a")
    t.toggleSaved(c)
    #expect(t.isSaved(c))
    t.toggleSaved(card("https://example.com/a"))
    #expect(!t.isSaved(c))
}

@Test func inboxMergesIntoTasteOnceAndEverythingCanBeDeleted() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "feed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = FeedStore(folder: folder)
    try store.save(taste())
    let link = URL(string: "https://music.example/album")!
    try store.enqueue(SharedItem(url: link, title: "An album", feeling: .love, date: day))
    try store.enqueue(SharedItem(url: link, title: "Same album again", feeling: .love, date: day.addingTimeInterval(60)))

    #expect(try store.mergeInbox().count == 2)
    let merged = try store.loadTaste()
    #expect(merged.shared.map(\.title) == ["Same album again"])
    #expect(merged.loves == ["Denis Villeneuve films"])
    #expect(try store.mergeInbox().isEmpty)

    try store.save(FeedBatch(createdAt: day, cards: [card("https://example.com/a")]))
    #expect(try store.loadFeed()?.cards.count == 1)
    try store.deleteEverything()
    #expect(try store.loadTaste() == TasteProfile())
    #expect(try store.loadFeed() == nil)
}

@Test func batchSavedBeforeOpenedExistedStillLoads() throws {
    let old = #"{"createdAt":0,"cards":[],"hidden":[]}"#
    let batch = try JSONDecoder().decode(FeedBatch.self, from: Data(old.utf8))
    #expect(batch.opened.isEmpty)

    var opened = FeedBatch(createdAt: day, cards: [card("https://example.com/a")])
    opened.opened.insert(opened.cards[0].id)
    let roundTrip = try JSONDecoder().decode(FeedBatch.self, from: JSONEncoder().encode(opened))
    #expect(roundTrip == opened)
}
