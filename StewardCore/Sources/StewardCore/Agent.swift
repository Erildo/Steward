import Foundation

/// Sends an email the owner approved. In the app, the relay does this from the
/// case's own address; in tests, a recorder.
public protocol MailSender: Sendable {
    func send(_ email: CaseFile.Email, caseID: UUID) async throws
}

/// Why the agent is being woken.
public enum Wake: Sendable, Equatable {
    /// A new case, or resuming one with nothing new.
    case start
    /// Mail arrived for the case (from the relay, after decrypting on the phone).
    case mail([CaseFile.Email])
    /// A wait the agent asked for has run out.
    case timer
    /// The owner answered the agent's question.
    case answer(String)
    /// The owner tapped approve (possibly after editing the body) or decline.
    case approval(approved: Bool, editedBody: String? = nil, reason: String? = nil)
}

/// The agent loop. It runs until the case has to wait for something (the owner,
/// the company, or time), saves where it is in the case, and returns. Nothing is
/// held in memory between wakes, so iOS can suspend the app for days.
public struct Agent: Sendable {
    public var model: any ModelClient
    public var mail: any MailSender
    public var now: @Sendable () -> Date
    /// Model calls allowed per wake, so a confused model can't loop forever.
    public var maxSteps: Int

    public init(model: any ModelClient, mail: any MailSender, now: @escaping @Sendable () -> Date = Date.init, maxSteps: Int = 12) {
        self.model = model
        self.mail = mail
        self.now = now
        self.maxSteps = maxSteps
    }

    public struct TooManySteps: Error {}

    public func wake(_ input: CaseFile, with wake: Wake) async throws -> CaseFile {
        var file = input
        if case .closed = file.state { return file }

        if case .mail(let emails) = wake {
            for email in emails {
                file.emails.append(email)
                file.log("email_in", "Reply from \(email.from): \(email.subject)", at: email.date)
            }
            file.inbox.append(contentsOf: emails)
        }

        // Settle whatever the case was waiting for.
        switch file.state {
        case .new:
            if file.transcript.isEmpty {
                file.log("opened", "\(file.errand) with \(file.company.name)", at: now())
            }
        case .needsApproval(let callID, let draft):
            guard case .approval(let approved, let editedBody, let reason) = wake else { return file }
            if approved {
                var email = draft
                email.date = now()
                if let editedBody { email.body = editedBody }
                try await mail.send(email, caseID: file.id)
                file.emails.append(email)
                file.log("email_out", "Sent to \(email.to): \(email.subject)", at: email.date)
                file.transcript.append(.tool(callID: callID, content: "Sent on \(Prompt.day(email.date)) to \(email.to)."))
            } else {
                let why = reason ?? "no reason given"
                file.log("owner_declined", why, at: now())
                file.transcript.append(.tool(callID: callID, content: "The owner said no: \(why). Nothing was sent."))
            }
        case .needsAnswer(let callID, _):
            guard case .answer(let answer) = wake else { return file }
            file.log("owner_answer", answer, at: now())
            file.transcript.append(.tool(callID: callID, content: answer))
        case .waitingForReply(let callID, let until):
            if !file.inbox.isEmpty {
                file.transcript.append(.tool(callID: callID, content: deliver(&file)))
            } else if now() >= until || wake == .timer {
                file.log("wait", "No reply by \(Prompt.day(now())).", at: now())
                file.transcript.append(.tool(callID: callID, content: "\(Prompt.day(now())): no reply yet after waiting."))
            } else {
                return file
            }
        case .closed:
            return file
        }
        file.state = .new
        return try await run(file)
    }

    /// Call the model and carry out its tool calls until the case must wait.
    private func run(_ input: CaseFile) async throws -> CaseFile {
        var file = input
        let system = Prompt.system(for: file, today: now())
        if file.transcript.isEmpty {
            file.transcript.append(.user("Please handle this \(file.errand) with \(file.company.name)."))
        }

        for _ in 0..<maxSteps {
            let turn = try await model.complete(system: system, messages: file.transcript, tools: Prompt.tools)
            file.transcript.append(.assistant(text: turn.text, toolCalls: turn.toolCalls))
            if turn.toolCalls.isEmpty {
                file.transcript.append(.user("Keep working the errand with your tools. If it is finished, or cannot be finished, call close_case."))
                continue
            }
            for (index, call) in turn.toolCalls.enumerated() {
                // Once the case has to wait, answer any further calls in this turn
                // so the transcript stays valid, and stop.
                if index > 0, file.state != .new {
                    file.transcript.append(.tool(callID: call.id, content: "Not run: the case is waiting. Call it again later if still needed."))
                    continue
                }
                file = try handle(call, in: file)
            }
            if file.state != .new { return file }
        }
        throw TooManySteps()
    }

    private func handle(_ call: ToolCall, in input: CaseFile) throws -> CaseFile {
        var file = input
        let args = call.arguments
        switch call.name {
        case "send_email":
            let to = args["to"]?.string ?? ""
            let subject = args["subject"]?.string ?? ""
            let body = args["body"]?.string ?? ""
            switch Gate.check(to: to, subject: subject, body: body, in: file) {
            case .blocked(let reason):
                file.log("gate_block", reason, at: now())
                file.transcript.append(.tool(callID: call.id, content: "Blocked by rule: \(reason) Nothing was sent."))
            case .askOwner:
                let draft = CaseFile.Email(direction: .outgoing, date: now(), from: file.owner.caseAddress, to: to, subject: subject, body: body)
                file.state = .needsApproval(callID: call.id, draft: draft)
                file.log("approval_asked", "Draft to \(to): \(subject)", at: now())
            }
        case "wait_for_reply":
            let days = min(14, max(1, args["max_days"]?.int ?? 7))
            if !file.inbox.isEmpty {
                file.transcript.append(.tool(callID: call.id, content: deliver(&file)))
            } else {
                let until = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: now()) ?? now()
                file.state = .waitingForReply(callID: call.id, until: until)
                file.log("waiting", "Waiting for a reply until \(Prompt.day(until)).", at: now())
            }
        case "ask_owner":
            let question = args["question"]?.string ?? ""
            file.state = .needsAnswer(callID: call.id, question: question)
            file.log("ask_owner", question, at: now())
        case "close_case":
            let status = CaseFile.Closure.Status(rawValue: args["status"]?.string ?? "") ?? .needsOwner
            let closure = CaseFile.Closure(status: status, summary: args["summary"]?.string ?? "", evidence: args["evidence"]?.string ?? "", date: now())
            file.closure = closure
            file.state = .closed
            file.transcript.append(.tool(callID: call.id, content: "Case closed as \(status.rawValue)."))
            file.log("closed", "\(status.rawValue): \(closure.summary)", at: now())
        default:
            file.transcript.append(.tool(callID: call.id, content: "Unknown tool \(call.name)."))
        }
        return file
    }

    /// Hand queued replies to the agent, marked as data rather than instructions.
    private func deliver(_ file: inout CaseFile) -> String {
        let emails = file.inbox
        file.inbox = []
        var parts = ["\(Prompt.day(now())): \(emails.count) new email(s)."]
        for email in emails {
            parts.append("\nFrom: \(email.from)\nDate: \(Prompt.day(email.date))\nSubject: \(email.subject)\n<email_content>\n\(email.body)\n</email_content>")
        }
        return parts.joined(separator: "\n")
    }
}
