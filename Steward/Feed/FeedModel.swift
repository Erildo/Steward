import Foundation
import Observation
import StewardCore

/// The Feed tab's state: the owner's taste file, today's batch, and refreshing.
/// One new batch a day when the tab opens, or whenever the owner pulls.
@MainActor
@Observable
final class FeedModel {
    enum Status: Equatable {
        case idle
        case loading
        /// No model is set up, so the feed can't refresh.
        case noModel
        case failed(String)
    }

    private(set) var taste = TasteProfile()
    private(set) var batch: FeedBatch?
    private(set) var status: Status = .idle
    /// Items that arrived from the Share button since the owner last looked.
    private(set) var justShared: [SharedItem] = []

    private let store: FeedStore
    private let composer: FeedComposer?
    private let now: () -> Date

    init(store: FeedStore, model: (any ModelClient)?, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.composer = model.map { FeedComposer(model: $0) }
        self.now = now
        load()
    }

    var hasModel: Bool { composer != nil }

    func cards(in section: FeedCard.Section) -> [FeedCard] {
        (batch?.visibleCards ?? []).filter { $0.section == section }
    }

    func reaction(to card: FeedCard) -> Reaction.Kind? {
        taste.reactions.first { $0.cardURL == card.url }?.kind
    }

    func isSaved(_ card: FeedCard) -> Bool { taste.isSaved(card) }

    // MARK: Lifecycle

    /// When the tab appears or the app comes back: pick up shared items, and make
    /// today's batch if there isn't one.
    func appear() async {
        collectShared()
        guard !taste.isEmpty else { return }
        if let batch, Calendar.current.isDate(batch.createdAt, inSameDayAs: now()) { return }
        await refresh()
    }

    func refresh() async {
        guard status != .loading else { return }
        guard let composer else { status = .noModel; return }
        guard !taste.isEmpty else { return }
        status = .loading
        do {
            let next = try await composer.compose(for: taste, after: batch)
            batch = next
            try? store.save(next)
            status = .idle
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    func collectShared() {
        guard let items = try? store.mergeInbox(), !items.isEmpty else { return }
        justShared = items + justShared
        taste = (try? store.loadTaste()) ?? taste
    }

    func dismissJustShared() { justShared = [] }

    // MARK: Owner actions

    func react(_ kind: Reaction.Kind, to card: FeedCard) {
        if reaction(to: card) == kind {
            taste.reactions.removeAll { $0.cardURL == card.url }
        } else {
            taste.record(Reaction(kind: kind, card: card, date: now()))
        }
        if kind == .less, var batch {
            batch.hidden.insert(card.id)
            self.batch = batch
            try? store.save(batch)
        }
        saveTaste()
    }

    /// Brings back a card the owner just said "not for me" to.
    func undoHide(_ card: FeedCard) {
        guard var batch else { return }
        batch.hidden.remove(card.id)
        self.batch = batch
        try? store.save(batch)
        taste.reactions.removeAll { $0.cardURL == card.url && $0.kind == .less }
        saveTaste()
    }

    func toggleSaved(_ card: FeedCard) {
        taste.toggleSaved(card)
        saveTaste()
    }

    /// Edits the taste file. It never starts a batch: the first one waits until
    /// the owner closes Your Taste (`appear()`), so it isn't built from a
    /// single word typed while they are still adding things.
    func update(_ edit: (inout TasteProfile) -> Void) {
        edit(&taste)
        saveTaste()
    }

    func markOpened(_ card: FeedCard) {
        guard var batch, !batch.opened.contains(card.id) else { return }
        batch.opened.insert(card.id)
        self.batch = batch
        try? store.save(batch)
    }

    func isOpened(_ card: FeedCard) -> Bool { batch?.opened.contains(card.id) ?? false }

    func deleteEverything() {
        try? store.deleteEverything()
        taste = TasteProfile()
        batch = nil
        justShared = []
        status = .idle
    }

    // MARK: Private

    private func load() {
        taste = (try? store.loadTaste()) ?? TasteProfile()
        batch = try? store.loadFeed()
    }

    private func saveTaste() {
        try? store.save(taste)
    }

    private static func message(for error: Error) -> String {
        if error is FeedComposer.NothingUsable {
            return "Steward looked but found nothing worth showing. Pull to try again."
        }
        if let http = error as? OpenAICompatibleClient.HTTPError {
            return http.status == 401 || http.status == 403
                ? "Steward wasn't allowed to search just now. Your taste is safe. Pull to try again later."
                : "Steward's search service had a problem. Pull to try again."
        }
        if (error as? URLError) != nil {
            return "Steward couldn't reach the internet. Pull to try again."
        }
        return "Something went wrong. Pull to try again."
    }
}

extension FeedModel {
    /// Launch states, like chat's: `-uiState feed` shows sample cards and
    /// `-uiState feedEmpty` the first run. Both keep their files in a temporary
    /// folder and never call a model.
    static func launch() -> FeedModel {
        switch UserDefaults.standard.string(forKey: "uiState") {
        case "feed":
            let store = temporaryStore()
            try? store.save(FeedSample.taste)
            try? store.save(FeedBatch(createdAt: .now, cards: FeedSample.cards, opened: [FeedSample.cards[1].id]))
            return FeedModel(store: store, model: nil)
        case "feedEmpty":
            return FeedModel(store: temporaryStore(), model: nil)
        default:
            return FeedModel(store: FeedStore(folder: FeedFolder.url), model: ModelAccess.feedModel())
        }
    }

    private static func temporaryStore() -> FeedStore {
        FeedStore(folder: URL.temporaryDirectory.appending(path: "feed-sample-\(UUID().uuidString)"))
    }
}

/// Demo content for `-uiState feed`. Links point at example.com on purpose.
enum FeedSample {
    static let taste = TasteProfile(
        loves: ["Denis Villeneuve films", "Long-form tech interviews", "Japanese city pop"],
        curious: ["Home espresso", "How chips are made"],
        goals: ["Run a half marathon in April", "Get conversational in Italian"]
    )

    static let cards: [FeedCard] = [
        card(.forYou, "A first look at Villeneuve's next project", "Production notes and the first official stills.", "You love his films; this is the clearest look yet at what's next.", "Sample Film Weekly", "Villeneuve"),
        card(.forYou, "Three hours with a chip designer", "A long conversation on why the next generation of chips is so hard to build.", "Your kind of interview, and it touches the chip-making you're curious about.", "Sample Podcast", "Tech interviews"),
        card(.forYou, "The 1980s Tokyo albums that shaped city pop", "A listening guide to ten records, with where to stream them.", "You love city pop; three of these are rarely on playlists.", "Sample Music Review", "City pop"),
        card(.worthALook, "Why your espresso tastes sour, explained with charts", "Extraction, grind size and temperature, without the jargon.", "You're curious about espresso; this is the one guide that makes it click.", "Sample Coffee Lab", "Home espresso"),
        card(.worthALook, "Inside a factory that makes the machines that make chips", "A photo essay from the cleanest rooms on earth.", "Next door to your interest in how chips are made.", "Sample Science Mag", "Chipmaking"),
        card(.towardGoals, "A 16-week half marathon plan for April races", "Three runs a week, built for first-timers.", "Starting this week lines up with an April race.", "Sample Running Club", "Half marathon"),
        card(.towardGoals, "Italian podcast for learners, slowly spoken", "Twenty-minute episodes on everyday topics.", "Fits your commute and your goal to get conversational.", "Sample Language School", "Italian"),
    ]

    private static func card(_ section: FeedCard.Section, _ title: String, _ summary: String, _ why: String, _ source: String, _ topic: String) -> FeedCard {
        FeedCard(section: section, title: title, summary: summary, why: why,
                 url: URL(string: "https://example.com/\(topic.lowercased().replacingOccurrences(of: " ", with: "-"))")!,
                 source: source, topic: topic)
    }
}
