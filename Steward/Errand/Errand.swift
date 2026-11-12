import Foundation
import StewardCore

/// The errand under way in chat: its steps and who moves next. It drives the
/// Steward pill and the Live Activity; the conversation keeps the record, as
/// reply blocks in its messages.
struct Errand: Identifiable {
    enum Phase { case running, needsYou, finished, stopped }
    typealias StepState = ReplyBlock.Steps.State

    struct Step: Identifiable {
        let id = UUID()
        let title: String
        let activeTitle: String
        var state: StepState = .pending
    }

    var id = UUID()
    let title: String
    var steps: [Step]
    var phase: Phase = .running
    /// Shown while nothing is really sent: "Demo" or "Simulated".
    var label: String? = "Demo"

    /// The steps as a block for the conversation.
    var stepsBlock: ReplyBlock {
        .steps(.init(title: title, steps: steps.map { .init(title: $0.title, state: $0.state) }))
    }

    /// A real errand run by the agent.
    static func agentErrand(id: UUID, title: String, label: String?) -> Errand {
        Errand(
            id: id,
            title: title,
            steps: [
                Step(title: "Write the email", activeTitle: "Writing the email"),
                Step(title: "Send it, with your OK", activeTitle: "Sending the email"),
                Step(title: "Wait for their reply", activeTitle: "Waiting for their reply"),
                Step(title: "Get it confirmed in writing", activeTitle: "Reading their reply"),
            ],
            label: label
        )
    }

    /// The scripted errand that runs while no agent is connected.
    static func demoGymCancellation() -> Errand {
        Errand(
            title: "Cancel gym membership",
            steps: [
                Step(title: "Find your membership", activeTitle: "Finding your membership"),
                Step(title: "Read the cancellation terms", activeTitle: "Reading the terms"),
                Step(title: "Write the cancellation email", activeTitle: "Writing the email"),
                Step(title: "Send it, with your OK", activeTitle: "Sending the email"),
                Step(title: "Get confirmation", activeTitle: "Getting confirmation"),
            ]
        )
    }
}

/// What the Steward pill at the top of chat is showing.
enum StewardActivity: Equatable {
    case idle
    case working(step: String, number: Int, total: Int)
    case needsYou
    case done
}
