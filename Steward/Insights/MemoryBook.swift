import Foundation
import Observation
import StewardCore

/// The app's one copy of what Steward knows about the owner, kept in
/// `Memory.json` in their documents. Tasks read and add to it; Insights and
/// the Steward tab show it, and the owner confirms, forgets or exports it.
@MainActor
@Observable
final class MemoryBook {
    private(set) var memory: Memory
    private let store: MemoryStore?

    init(memory: Memory, store: MemoryStore?) {
        self.memory = memory
        self.store = store
    }

    /// Changes the memory and writes the file at once, so nothing the owner
    /// forgot can come back after a crash.
    func update(_ change: (inout Memory) -> Void) {
        change(&memory)
        try? store?.save(memory)
    }

    @discardableResult
    func remember(_ item: Memory.Item) -> Memory.RememberOutcome {
        var outcome = Memory.RememberOutcome.refused
        update { outcome = $0.remember(item) }
        return outcome
    }

    /// One shared book for the whole run.
    static let shared: MemoryBook = launch()

    /// Sample launches get the sample memory, kept in memory only; debug
    /// launches with scratch files start empty; real launches read the file.
    private static func launch() -> MemoryBook {
        let state = UserDefaults.standard.string(forKey: "uiState")
        if state == "insights" || state == "demo" || CaseService.isChatSample || CaseService.isTasksSample {
            return MemoryBook(memory: MemorySample.memory(), store: nil)
        }
        if CaseService.usesScratchFiles || state == "insightsEmpty" {
            return MemoryBook(memory: Memory(), store: nil)
        }
        let store = MemoryStore(url: URL.documentsDirectory.appending(path: "Memory.json"))
        return MemoryBook(memory: (try? store.load()) ?? Memory(), store: store)
    }
}

/// The sample owner's memory, matching the Insights and Feed samples.
enum MemorySample {
    static func memory() -> Memory {
        func fact(_ text: String, _ source: Memory.Source, _ evidence: String) -> Memory.Item {
            .init(text: text, kind: .fact, source: source, evidence: evidence)
        }
        func guess(_ text: String, _ source: Memory.Source, _ evidence: String, _ confidence: Memory.Confidence) -> Memory.Item {
            .init(text: text, kind: .guess, source: source, evidence: evidence, confidence: confidence)
        }
        return Memory(items: [
            fact("Training for a half marathon in April", .chat, "You said in a chat"),
            fact("Learning Italian", .chat, "You said in a chat"),
            fact("Lives in Berlin", .task, "From your gym task"),
            fact("Started a new job on 19 October", .chat, "From a chat that day"),
            fact("Saving €3,000 for Lisbon in May", .chat, "You said in a chat"),
            guess("Gets admin done on Sunday evenings", .task, "From 14 tasks", .fairlySure),
            guess("Prefers email to phone calls", .task, "From 18 tasks", .sure),
            guess("Cooking more at home", .feed, "From 15 Feed saves", .fairlySure),
            guess("Answers fastest before 9 am", .chat, "From 41 replies", .fairlySure),
            guess("Likes short, informal emails", .task, "From 5 drafts you edited", .hunch),
        ])
    }
}
