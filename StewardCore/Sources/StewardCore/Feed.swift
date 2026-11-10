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

    public init(id: UUID = UUID(), section: Section, title: String, summary: String, why: String, url: URL, source: String, topic: String) {
        self.id = id
        self.section = section
        self.title = title
        self.summary = summary
        self.why = why
        self.url = url
        self.source = source
        self.topic = topic
    }
}

/// One day's feed.
public struct FeedBatch: Codable, Sendable, Equatable {
    public var createdAt: Date
    public var cards: [FeedCard]
    /// Cards the owner said "not for me" to, hidden from this batch.
    public var hidden: Set<UUID>

    public init(createdAt: Date, cards: [FeedCard], hidden: Set<UUID> = []) {
        self.createdAt = createdAt
        self.cards = cards
        self.hidden = hidden
    }

    public var visibleCards: [FeedCard] {
        cards.filter { !hidden.contains($0.id) }
    }
}
