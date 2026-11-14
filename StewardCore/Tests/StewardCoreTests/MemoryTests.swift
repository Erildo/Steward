import Foundation
import Testing
@testable import StewardCore

@Test func memoryKeepsFactsAndGuessesApart() {
    var memory = Memory()
    memory.remember(.init(text: "Lives in Berlin", kind: .fact, source: .task, evidence: "You said so in a task"))
    memory.remember(.init(text: "Prefers email to phone calls", kind: .guess, source: .task, evidence: "From 3 tasks", confidence: .fairlySure))
    #expect(memory.facts.map(\.text) == ["Lives in Berlin"])
    #expect(memory.guesses.map(\.text) == ["Prefers email to phone calls"])
    let brief = memory.brief()
    let factsAt = try! #require(brief.range(of: TaskSpec.memoryWording.facts))
    let guessesAt = try! #require(brief.range(of: TaskSpec.memoryWording.guesses))
    #expect(factsAt.upperBound < guessesAt.lowerBound)
    #expect(brief.contains("- Prefers email to phone calls (fairly sure; From 3 tasks)"))
}

@Test func aGuessBecomesAFactOnlyOnTheOwnersWord() {
    var memory = Memory()
    guard case .added(let guess) = memory.remember(.init(text: "Training for a half marathon", kind: .guess, source: .chat, evidence: "From runs you mentioned")) else {
        Issue.record("not added"); return
    }
    // Another guess of the same thing changes nothing.
    #expect(memory.remember(.init(text: "training for a half-marathon", kind: .guess, source: .chat, evidence: "again")) == .alreadyKnown(guess))
    #expect(memory.items.count == 1)
    memory.confirm(guess.id)
    #expect(memory.facts.count == 1)
    #expect(memory.items[0].confirmedAt != nil)
    #expect(memory.items[0].confidence == nil)
}

@Test func topicsTurnedOffAreNeitherStoredNorShown() {
    var memory = Memory()
    #expect(memory.remember(.init(text: "Sleeps badly before deadlines", kind: .guess, source: .chat, evidence: "x", topic: "health and sleep")) == .refused)
    memory.setTopic("Mood", allowed: true)
    memory.remember(.init(text: "Happier after weekend hikes", kind: .guess, source: .chat, evidence: "x", topic: "Mood"))
    #expect(memory.brief().contains("Happier after weekend hikes"))
    memory.setTopic("Mood", allowed: false)
    #expect(!memory.brief().contains("Happier after weekend hikes"))
    #expect(memory.brief().contains("Mood"))
    // Still in the owner's own file and export.
    #expect(memory.exportText().contains("Happier after weekend hikes"))
}

@Test func numbersThatLookLikeCardsOrAccountsAreRefused() {
    var memory = Memory()
    #expect(memory.remember(.init(text: "Card 4111 1111 1111 1111", kind: .fact, source: .chat, evidence: "x")) == .refused)
    #expect(memory.remember(.init(text: "IBAN DE89-3704-0044-0532", kind: .fact, source: .chat, evidence: "x")) == .refused)
    if case .added = memory.remember(.init(text: "Born in 1990, has 2 kids", kind: .fact, source: .chat, evidence: "x")) {} else {
        Issue.record("an ordinary fact was refused")
    }
}

@Test func memoryRoundTripsThroughItsFile() throws {
    let url = URL.temporaryDirectory.appending(path: "memory-\(UUID()).json")
    var memory = Memory()
    memory.remember(.init(text: "Learning Italian", kind: .fact, source: .chat, evidence: "You said in a chat", createdAt: Date(timeIntervalSince1970: 1_794_700_800)))
    memory.setTopic("Mood", allowed: true)
    let store = MemoryStore(url: url)
    try store.save(memory)
    #expect(try store.load() == memory)
    #expect(try MemoryStore(url: url.appending(path: "missing")).load() == Memory())
}
