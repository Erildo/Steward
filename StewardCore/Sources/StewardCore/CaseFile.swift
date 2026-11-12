import Foundation

/// The central object: one errand, kept until the outcome is confirmed.
///
/// Stored as a readable JSON file on the owner's device. It is also the export
/// format, and it mirrors the Stage 0 harness `Case` so results stay comparable.
public struct CaseFile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var errand: String
    public var createdAt: Date
    public var owner: Owner
    public var company: Company
    public var playbook: String?

    public var emails: [Email] = []
    public var events: [Event] = []

    /// Replies that arrived while the agent wasn't waiting for one.
    public var inbox: [Email] = []

    /// The model conversation, so the agent can pick up where it left off
    /// after the app was suspended for days.
    public var transcript: [ModelMessage] = []

    public var state: State = .new
    public var closure: Closure?

    public init(
        id: UUID = UUID(),
        errand: String,
        createdAt: Date,
        owner: Owner,
        company: Company,
        playbook: String? = nil
    ) {
        self.id = id
        self.errand = errand
        self.createdAt = createdAt
        self.owner = owner
        self.company = company
        self.playbook = playbook
    }

    public struct Owner: Codable, Sendable, Equatable {
        public var name: String
        /// The address this case sends from: the case's own mailbox.
        public var caseAddress: String
        public var accountRef: String
        public var facts: String
        public var goal: String
        public var willNot: [String]
        /// Details the owner holds that must never appear in an email.
        public var secrets: [String]

        public init(name: String, caseAddress: String, accountRef: String, facts: String, goal: String, willNot: [String] = [], secrets: [String] = []) {
            self.name = name
            self.caseAddress = caseAddress
            self.accountRef = accountRef
            self.facts = facts
            self.goal = goal
            self.willNot = willNot
            self.secrets = secrets
        }
    }

    public struct Company: Codable, Sendable, Equatable {
        public var name: String
        public var domain: String
        public var email: String
        /// Where the company is, as the harness scenarios name it ("DE", "UK").
        public var country: String?

        public init(name: String, domain: String, email: String, country: String? = nil) {
            self.name = name
            self.domain = domain
            self.email = email
            self.country = country
        }
    }

    public struct Email: Codable, Sendable, Equatable {
        public enum Direction: String, Codable, Sendable { case outgoing, incoming }
        public var direction: Direction
        public var date: Date
        public var from: String
        public var to: String
        public var subject: String
        public var body: String

        public init(direction: Direction, date: Date, from: String, to: String, subject: String, body: String) {
            self.direction = direction
            self.date = date
            self.from = from
            self.to = to
            self.subject = subject
            self.body = body
        }
    }

    public struct Event: Codable, Sendable, Equatable {
        public var date: Date
        public var kind: String
        public var detail: String
    }

    /// Where the case is. Every waiting state names exactly what wakes it.
    public enum State: Codable, Sendable, Equatable {
        case new
        /// A draft passed the rules and waits for the owner's tap.
        case needsApproval(callID: String, draft: Email)
        /// The agent asked the owner something.
        case needsAnswer(callID: String, question: String)
        /// Waiting for the company until a date; mail or that date wakes it.
        case waitingForReply(callID: String, until: Date)
        case closed
    }

    public struct Closure: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case done, failed, needsOwner = "needs_owner" }
        public var status: Status
        public var summary: String
        public var evidence: String
        public var date: Date
    }

    mutating func log(_ kind: String, _ detail: String, at date: Date) {
        events.append(Event(date: date, kind: kind, detail: detail))
    }
}
