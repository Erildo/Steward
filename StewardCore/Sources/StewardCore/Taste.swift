import Foundation

/// What the owner loves, is curious about and is working toward, plus what they
/// shared and how they reacted to the feed. One readable JSON file the owner can
/// edit, export or delete. It is the only thing the feed knows about them.
public struct TasteProfile: Codable, Sendable, Equatable {
    public var loves: [String]
    public var curious: [String]
    public var goals: [String]
    /// Newest first, capped at `reactionLimit`.
    public var reactions: [Reaction]
    /// Things the owner sent from other apps with the Share button. Newest first.
    public var shared: [SharedItem]
    /// Cards the owner saved, kept so they survive the next batch. Newest first.
    public var saved: [FeedCard]

    public static let reactionLimit = 80
    public static let sharedLimit = 60

    public init(loves: [String] = [], curious: [String] = [], goals: [String] = [],
                reactions: [Reaction] = [], shared: [SharedItem] = [], saved: [FeedCard] = []) {
        self.loves = loves
        self.curious = curious
        self.goals = goals
        self.reactions = reactions
        self.shared = shared
        self.saved = saved
    }

    /// True when there is nothing to build a feed from.
    public var isEmpty: Bool {
        loves.isEmpty && curious.isEmpty && goals.isEmpty && shared.isEmpty
    }

    public mutating func record(_ reaction: Reaction) {
        reactions.removeAll { $0.cardURL == reaction.cardURL }
        reactions.insert(reaction, at: 0)
        if reactions.count > Self.reactionLimit { reactions.removeLast(reactions.count - Self.reactionLimit) }
    }

    public mutating func add(shared items: [SharedItem]) {
        for item in items.sorted(by: { $0.date < $1.date }) {
            shared.removeAll { $0.id == item.id || ($0.url != nil && $0.url == item.url) }
            shared.insert(item, at: 0)
        }
        if shared.count > Self.sharedLimit { shared.removeLast(shared.count - Self.sharedLimit) }
    }

    public mutating func toggleSaved(_ card: FeedCard) {
        if let index = saved.firstIndex(where: { $0.url == card.url }) {
            saved.remove(at: index)
        } else {
            saved.insert(card, at: 0)
        }
    }

    public func isSaved(_ card: FeedCard) -> Bool {
        saved.contains { $0.url == card.url }
    }
}

public struct Reaction: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case more, less }

    public var kind: Kind
    public var cardTitle: String
    public var topic: String
    public var cardURL: URL
    public var date: Date

    public init(kind: Kind, card: FeedCard, date: Date) {
        self.kind = kind
        self.cardTitle = card.title
        self.topic = card.topic
        self.cardURL = card.url
        self.date = date
    }
}

/// Something the owner sent to Steward from another app.
public struct SharedItem: Codable, Sendable, Equatable, Identifiable {
    /// Why the owner shared it, if they said.
    public enum Feeling: String, Codable, Sendable, CaseIterable {
        case love, curious, goal

        /// How the app and the Share sheet name it.
        public var label: String {
            switch self {
            case .love: "Love it"
            case .curious: "Curious"
            case .goal: "For a goal"
            }
        }
    }

    public var id: UUID
    public var url: URL?
    public var title: String
    public var note: String
    public var feeling: Feeling?
    public var date: Date

    public init(id: UUID = UUID(), url: URL?, title: String, note: String = "", feeling: Feeling? = nil, date: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.note = note
        self.feeling = feeling
        self.date = date
    }
}
