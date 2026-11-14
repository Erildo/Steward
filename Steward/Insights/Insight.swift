import Foundation
import StewardCore

/// Something Steward noticed about the owner's life, with the evidence that
/// backs it and how sure Steward is. Observations, never diagnoses.
struct Insight: Identifiable, Equatable {
    enum Kind: Hashable {
        case goal, change, aboutYou

        var label: String {
            switch self {
            case .goal: "Goal"
            case .change: "Change"
            case .aboutYou: "About you"
            }
        }
    }

    /// How sure Steward is. Said plainly on every finding.
    enum Confidence: Hashable {
        case sure, fairlySure, hunch

        var label: String {
            switch self {
            case .sure: "Sure"
            case .fairlySure: "Fairly sure"
            case .hunch: "A hunch"
            }
        }
    }

    /// Where a finding came from, so the owner can check it.
    struct Evidence: Hashable {
        enum Source: Hashable {
            case chat, task, feed, you

            var systemImage: String {
                switch self {
                case .chat: "bubble.left"
                case .task: "checkmark.square"
                case .feed: "newspaper"
                case .you: "person"
                }
            }
        }

        let source: Source
        let text: String
    }

    /// A next step Steward could take, written as the owner would ask it.
    struct NextStep: Hashable {
        let label: String
        let request: String
    }

    var id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    /// For goals: on pace or slipping.
    var status: String?
    var statusNeedsYou = false
    /// The picture that proves it, from the same block library Chat uses.
    /// `nil` when words say it better, such as a hunch with little to plot.
    var chart: ReplyBlock.Chart?
    let confidence: Confidence
    /// What the confidence rests on, briefly: "14 tasks".
    let basis: String
    let evidence: [Evidence]
    var nextStep: NextStep?
}

/// Something Steward finished for the owner, and who confirmed it.
struct Win: Identifiable, Hashable {
    enum Proof: Hashable {
        /// The company said so in writing.
        case company
        /// The owner checked and said so. Counts more.
        case owner

        var label: String {
            switch self {
            case .company: "Company confirmed"
            case .owner: "You confirmed"
            }
        }

        var systemImage: String {
            switch self {
            case .company: "checkmark.seal"
            case .owner: "person.crop.circle.badge.checkmark"
            }
        }
    }

    var id = UUID()
    let title: String
    let date: Date
    /// Money back, in the owner's currency, if any.
    var amount: Decimal?
    /// Money no longer going out each month, if any.
    var monthly: Decimal?
    let proof: Proof
}

/// One line in "What Steward knows": a fact the owner said, or a guess
/// Steward made, with where it came from.
struct Known: Identifiable, Hashable {
    var id = UUID()
    let text: String
    let source: String
    let isGuess: Bool
}

/// Parts of life Steward leaves alone unless the owner turns them on.
struct Topic: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let systemImage: String
    var allowed: Bool
}
