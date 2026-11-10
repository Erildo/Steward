import Foundation

struct DeadlineInfo: Equatable {
    let daysLeft: Int
    let elapsedFraction: Double
    let lastDay: Date
    let nextPayment: Date
    let amount: String
}

struct Errand: Identifiable {
    enum Phase { case running, needsYou, finished, stopped }
    enum Approval { case notAsked, pending, approved, declined }
    enum StepState { case pending, active, waiting, done }

    struct Step: Identifiable {
        let id = UUID()
        let title: String
        let activeTitle: String
        var state: StepState = .pending
    }

    let id = UUID()
    let title: String
    var steps: [Step]
    var phase: Phase = .running
    var approval: Approval = .notAsked
    let recipient: String
    let subject: String
    var messageBody: String

    static func demoGymCancellation() -> Errand {
        Errand(
            title: "Cancel gym membership",
            steps: [
                Step(title: "Find your membership", activeTitle: "Finding your membership"),
                Step(title: "Read the cancellation terms", activeTitle: "Reading the terms"),
                Step(title: "Write the cancellation email", activeTitle: "Writing the email"),
                Step(title: "Send it, with your OK", activeTitle: "Sending the email"),
                Step(title: "Get confirmation", activeTitle: "Getting confirmation"),
            ],
            recipient: "members@northside-gym.example",
            subject: "Please cancel my membership",
            messageBody: "Hello,\n\nPlease cancel my membership and confirm the date it ends. I'm giving notice within the period in your terms.\n\nThank you."
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
