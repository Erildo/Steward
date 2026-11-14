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

    /// What the owner has told the agent along the way: answers to its
    /// questions, reasons for declining a draft, and why a case was reopened.
    /// Shown next to the goal, to the agent and to the owner, so a steer is
    /// never lost when older steps drop out of the agent's view.
    public var standingInstructions: [Instruction] = []

    /// The agent's own working log, which it rewrites with the `note` tool in
    /// brief mode. Shown to the owner: nothing the agent thinks is hidden.
    public var notes: String = ""

    /// How far the outcome is proven. See `Proof`.
    public var proof: Proof = .none

    /// The one yes/no question put to the owner once they could see the
    /// result for themselves, such as after the next bill.
    public var outcomeCheck: OutcomeCheck?

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
        /// For an email the owner edited before sending: the agent's draft as
        /// it was. Kept on the phone with the case, as a record of the owner's
        /// correction. `nil` when it went out as drafted.
        public var draftBody: String?
        /// Set on an outgoing email when the owner approves it, and kept if
        /// sending fails, so a retry hands over the same ID. The relay refuses
        /// an ID it has already sent. A draft that carries one is "sending";
        /// once it is in `emails`, it is "sent".
        public var sendID: String?

        public init(direction: Direction, date: Date, from: String, to: String, subject: String, body: String, draftBody: String? = nil, sendID: String? = nil) {
            self.direction = direction
            self.date = date
            self.from = from
            self.to = to
            self.subject = subject
            self.body = body
            self.draftBody = draftBody
            self.sendID = sendID
        }
    }

    public struct Instruction: Codable, Sendable, Equatable {
        public var date: Date
        public var text: String

        public init(date: Date, text: String) {
            self.date = date
            self.text = text
        }
    }

    /// Proof comes in two levels, and the owner's counts more (ADR 0002).
    public enum Proof: String, Codable, Sendable, Equatable {
        /// Not closed as done, or closed without the company's written word.
        case none
        /// The company confirmed in writing, quoted word for word. Once the
        /// relay exists, this also needs a DKIM pass for the company's domain.
        case company
        /// The owner said it worked, which no company email can fake.
        case owner
    }

    public struct OutcomeCheck: Codable, Sendable, Equatable {
        public var due: Date
        public var question: String
        /// `nil` until the owner answers.
        public var answer: Bool?
        public var answeredAt: Date?

        public init(due: Date, question: String, answer: Bool? = nil, answeredAt: Date? = nil) {
            self.due = due
            self.question = question
            self.answer = answer
            self.answeredAt = answeredAt
        }

        public func isDue(at date: Date) -> Bool { answer == nil && date >= due }
    }

    public struct Event: Codable, Sendable, Equatable {
        public var date: Date
        public var kind: String
        public var detail: String

        public init(date: Date, kind: String, detail: String) {
            self.date = date
            self.kind = kind
            self.detail = detail
        }
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

        public init(status: Status, summary: String, evidence: String, date: Date) {
            self.status = status
            self.summary = summary
            self.evidence = evidence
            self.date = date
        }
    }

    mutating func log(_ kind: String, _ detail: String, at date: Date) {
        events.append(Event(date: date, kind: kind, detail: detail))
    }

    // Cases saved before a field existed still open: every field added after
    // the first format is optional when read.
    private enum CodingKeys: String, CodingKey {
        case id, errand, createdAt, owner, company, playbook, emails, events, inbox, transcript, state, closure
        case standingInstructions, notes, proof, outcomeCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        errand = try c.decode(String.self, forKey: .errand)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        owner = try c.decode(Owner.self, forKey: .owner)
        company = try c.decode(Company.self, forKey: .company)
        playbook = try c.decodeIfPresent(String.self, forKey: .playbook)
        emails = try c.decodeIfPresent([Email].self, forKey: .emails) ?? []
        events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
        inbox = try c.decodeIfPresent([Email].self, forKey: .inbox) ?? []
        transcript = try c.decodeIfPresent([ModelMessage].self, forKey: .transcript) ?? []
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .new
        closure = try c.decodeIfPresent(Closure.self, forKey: .closure)
        standingInstructions = try c.decodeIfPresent([Instruction].self, forKey: .standingInstructions) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        proof = try c.decodeIfPresent(Proof.self, forKey: .proof) ?? .none
        outcomeCheck = try c.decodeIfPresent(OutcomeCheck.self, forKey: .outcomeCheck)
    }
}
