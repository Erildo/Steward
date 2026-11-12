import Foundation

/// One thing Steward thinks the owner would care about, with a real link and the
/// reason in one line.
public struct FeedCard: Codable, Sendable, Equatable, Identifiable {
    public enum Section: String, Codable, Sendable, CaseIterable {
        /// More of what the owner already loves.
        case forYou = "for_you"
        /// Next to their interests, likely to catch their curiosity.
        case worthALook = "worth_a_look"
        /// A step, resource or opportunity for one of their goals.
        case towardGoals = "toward_goals"
    }

    public var id: UUID
    public var section: Section
    public var title: String
    public var summary: String
    /// Why this owner in particular would care, in Steward's words.
    public var why: String
    public var url: URL
    public var source: String
    /// A short label for what the card is about, used to learn from reactions.
    public var topic: String
    /// A visual that shows what the find is, when one helps.
    public var lens: FeedLens?

    public init(id: UUID = UUID(), section: Section, title: String, summary: String, why: String, url: URL, source: String, topic: String, lens: FeedLens? = nil) {
        self.id = id
        self.section = section
        self.title = title
        self.summary = summary
        self.why = why
        self.url = url
        self.source = source
        self.topic = topic
        self.lens = lens
    }
}

/// One day's feed.
public struct FeedBatch: Codable, Sendable, Equatable {
    public var createdAt: Date
    public var cards: [FeedCard]
    /// Cards the owner said "not for me" to, hidden from this batch.
    public var hidden: Set<UUID>
    /// Cards the owner opened, so a return visit shows what is still new.
    public var opened: Set<UUID>

    public init(createdAt: Date, cards: [FeedCard], hidden: Set<UUID> = [], opened: Set<UUID> = []) {
        self.createdAt = createdAt
        self.cards = cards
        self.hidden = hidden
        self.opened = opened
    }

    /// Feeds saved before `opened` existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        cards = try container.decode([FeedCard].self, forKey: .cards)
        hidden = try container.decodeIfPresent(Set<UUID>.self, forKey: .hidden) ?? []
        opened = try container.decodeIfPresent(Set<UUID>.self, forKey: .opened) ?? []
    }

    public var visibleCards: [FeedCard] {
        cards.filter { !hidden.contains($0.id) }
    }
}
