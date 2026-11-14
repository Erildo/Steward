import Foundation
import StewardCore

/// Stands in for the relay until it exists: "sends" approved emails by keeping
/// them, and queues the company's answer for the case. Nothing leaves the phone.
actor SimulatedMailbox: MailSender {
    private(set) var sent: [CaseFile.Email] = []
    private var replies: [UUID: [CaseFile.Email]] = [:]
    private let reply: @Sendable (CaseFile.Email) -> CaseFile.Email?

    init(reply: @escaping @Sendable (CaseFile.Email) -> CaseFile.Email?) {
        self.reply = reply
    }

    func send(_ email: CaseFile.Email, in file: CaseFile) async throws {
        sent.append(email)
        if let answer = reply(email) {
            replies[file.id, default: []].append(answer)
        }
    }

    func takeReplies(for caseID: UUID) -> [CaseFile.Email] {
        replies.removeValue(forKey: caseID) ?? []
    }
}

/// The sample cancel errand used by `-uiState agent`: the owner, the company,
/// a scripted model run, and the company's reply.
nonisolated enum SimulatedErrand {
    static let title = "Cancel gym membership"
    static let company = CaseFile.Company(name: "Northside Gym", domain: "northside-gym.example", email: "members@northside-gym.example")

    static func gymCancellation(now: Date = .now) -> CaseFile {
        let id = UUID()
        return CaseFile(
            id: id,
            errand: "cancel",
            createdAt: now,
            owner: .init(
                name: "Sam Rivera",
                caseAddress: "case-\(id.uuidString.prefix(8).lowercased())@steward.example",
                accountRef: "Member number 20417",
                facts: "Monthly membership since March 2025, $39 a month. The terms ask for 30 days' written notice.",
                goal: "Cancel at the earliest date, with written confirmation and no further payments.",
                willNot: ["accept a discount or a pause instead"],
                secrets: ["4929 1234 5678 9012"]
            ),
            company: company
        )
    }

    static let confirmation = "We have cancelled membership 20417. Your last day is 10 December 2026 and no further payments will be taken."

    /// The company answers any email to its own address with a confirmation.
    @Sendable static func companyReply(to email: CaseFile.Email) -> CaseFile.Email? {
        guard email.to.lowercased() == company.email else { return nil }
        return CaseFile.Email(
            direction: .incoming,
            date: email.date.addingTimeInterval(2 * 86_400),
            from: company.email,
            to: email.from,
            subject: "Re: \(email.subject)",
            body: "Hello Sam,\n\n\(confirmation)\n\nNorthside Gym Members Team"
        )
    }

    /// A deterministic model: the happy path through `ScriptedModelClient`, and a
    /// clean close if the owner declines the draft.
    static func model() -> any ModelClient {
        OwnerAwareScript(script: ScriptedModelClient([
            turn("send_email", [
                "to": .string(company.email),
                "subject": .string("Cancel membership 20417"),
                "body": .string("Hello,\n\nPlease cancel my membership (member number 20417) at the earliest date your terms allow, and confirm in writing the date it ends and that no further payments will be taken.\n\nThank you,\nSam Rivera"),
            ]),
            turn("wait_for_reply", ["max_days": .number(7)]),
            turn("close_case", [
                "status": .string("done"),
                "summary": .string("Northside Gym confirmed your cancellation in writing. Your last day is 10 December, and no more payments will be taken."),
                "evidence": .string(confirmation),
            ]),
        ]))
    }

    private static func turn(_ name: String, _ args: [String: JSONValue]) -> AssistantTurn {
        AssistantTurn(toolCalls: [ToolCall(id: UUID().uuidString, name: name, arguments: args)])
    }
}

/// Follows the script, except that when the owner has just said no it closes the
/// case instead, so declining works without a second script.
nonisolated private struct OwnerAwareScript: ModelClient {
    let script: ScriptedModelClient

    func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        if case .tool(_, let content) = messages.last, content.hasPrefix("The owner said no") {
            return AssistantTurn(toolCalls: [ToolCall(id: UUID().uuidString, name: "close_case", arguments: [
                "status": .string("needs_owner"),
                "summary": .string("You said no, so nothing was sent. Your membership stays as it is."),
                "evidence": .string(""),
            ])])
        }
        return try await script.complete(system: system, messages: messages, tools: tools)
    }
}

/// The model behind the Tasks sample. It reacts to the owner's last move, for
/// any sample case: a sent email means wait a week, a no means hand the case
/// back, and an answer becomes a short email for the owner to approve.
nonisolated struct TasksSampleModel: ModelClient {
    func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        guard case .tool(_, let content) = messages.last else {
            return Self.turn("wait_for_reply", ["max_days": .number(7)])
        }
        if content.hasPrefix("The owner said no") {
            return Self.turn("close_case", [
                "status": .string("needs_owner"),
                "summary": .string("You said no, so nothing was sent."),
                "evidence": .string(""),
            ])
        }
        if content.hasPrefix("Sent on") {
            return Self.turn("wait_for_reply", ["max_days": .number(7)])
        }
        return Self.turn("send_email", [
            "to": .string(Self.companyEmail(in: system) ?? ""),
            "subject": .string("Further information on my account"),
            "body": .string("Hello,\n\nAs you asked, here is the information you need: \(content)\n\nPlease confirm you have what you need to resolve this.\n\nThank you"),
        ])
    }

    /// The company's address, as the system prompt states it.
    private static func companyEmail(in system: String) -> String? {
        let marker = "Only email the company at its own address: "
        guard let start = system.range(of: marker)?.upperBound else { return nil }
        return String(system[start...].prefix { !$0.isWhitespace }).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func turn(_ name: String, _ args: [String: JSONValue]) -> AssistantTurn {
        AssistantTurn(toolCalls: [ToolCall(id: UUID().uuidString, name: name, arguments: args)])
    }
}
