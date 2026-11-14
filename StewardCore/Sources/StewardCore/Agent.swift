import Foundation

/// Sends an email the owner approved. In the app, the relay does this from the
/// case's own address; in tests, a recorder. `email.sendID` is stable across
/// retries of the same approval, so a sender that has already sent that ID
/// must return without sending again.
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
    /// `callID` names the exact draft decided on: the one in
    /// `.needsApproval(callID:draft:)`. An approval for any other draft, or a
    /// second approval of the same one, does nothing, so a double tap or a
    /// late notification action can never send twice.
    case approval(callID: String, approved: Bool, editedBody: String? = nil, reason: String? = nil)
    /// The owner answered the outcome check of a case closed as done. Yes
    /// makes the owner's confirmation the proof. No reopens the case, with the
    /// owner's words as a standing instruction.
    case outcome(confirmed: Bool, note: String? = nil)
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
    /// What the agent sees of earlier wakes. Transcript replay until the
    /// Stage 0 "brief" arm earns the switch.
    public var context: AgentContext
    /// A stronger model that must accept every "done" before the case closes.
    /// `nil` skips the review.
    public var reviewer: (any ModelClient)?

    public init(
        model: any ModelClient,
        mail: any MailSender,
        now: @escaping @Sendable () -> Date = Date.init,
        maxSteps: Int = 12,
        context: AgentContext = .transcript,
        reviewer: (any ModelClient)? = nil
    ) {
        self.model = model
        self.mail = mail
        self.now = now
        self.maxSteps = maxSteps
        self.context = context
        self.reviewer = reviewer
    }

    public struct TooManySteps: Error {}

    /// A wake that stopped partway, for example because the model was
    /// unreachable or ran out of steps. `file` holds everything that already
    /// happened, an approved email that was sent included, so the caller must
    /// save it. Saving it prevents the next approval from sending the email
    /// again. The case is left in `.new`, and waking it with `.start` resumes it.
    /// If the send itself failed, the case stays waiting for approval with the
    /// draft's `sendID` kept, so approving again retries under the same ID.
    public struct WakeFailed: Error {
        public var file: CaseFile
        public var underlying: any Error
    }

    public func wake(_ input: CaseFile, with wake: Wake) async throws -> CaseFile {
        var file = input
        if case .outcome(let confirmed, let note) = wake {
            return try await answerOutcome(file, confirmed: confirmed, note: note)
        }
        if case .closed = file.state { return file }

        // An approval counts once, and only for the draft that is waiting.
        if case .approval(let approvedID, _, _, _) = wake {
            guard case .needsApproval(let waitingID, _) = file.state, waitingID == approvedID else {
                file.log("stale_approval", "A decision arrived for a draft that is no longer waiting. Nothing was sent.", at: now())
                return file
            }
        }

        if case .mail(let emails) = wake {
            for email in emails {
                file.emails.append(email)
                file.log("email_in", "Reply from \(email.from): \(email.subject)", at: email.date)
            }
            file.inbox.append(contentsOf: emails)
        }

        let new = Spec.rules.new
        // What the agent is told about this wake: as the result of the call it
        // was waiting on (transcript), or as "What's new" in the brief.
        var settled: (callID: String, result: String, brief: String)?

        switch file.state {
        case .new:
            if file.transcript.isEmpty && !file.events.contains(where: { $0.kind == "opened" }) {
                file.log("opened", "\(file.errand) with \(file.company.name)", at: now())
            }
        case .needsApproval(let callID, let draft):
            guard case .approval(_, let approved, let editedBody, let reason) = wake else { return file }
            if approved {
                var email = draft
                email.date = now()
                // The ID is fixed by the first approval, so a retry after a
                // failed send can't become a second email.
                email.sendID = draft.sendID ?? "\(file.id.uuidString.lowercased())-\(callID)"
                // Keep the agent's own wording when the owner changed it: each
                // edit shows what the agent got wrong.
                let edited = editedBody.flatMap { $0 == draft.body ? nil : $0 }
                if let edited {
                    email.body = edited
                    email.draftBody = draft.body
                }
                do {
                    try await mail.send(email, caseID: file.id)
                } catch {
                    var kept = draft
                    kept.sendID = email.sendID
                    file.state = .needsApproval(callID: callID, draft: kept)
                    file.log("send_failed", "Couldn't hand the email over: \(error). Approving again retries the same email, never a copy.", at: now())
                    throw WakeFailed(file: file, underlying: error)
                }
                file.emails.append(email)
                file.log("email_out", "Sent to \(email.to): \(email.subject)", at: email.date)
                let values = ["subject": email.subject, "day": Prompt.day(email.date), "to": email.to]
                if edited != nil {
                    file.log("owner_edited", "The owner rewrote the draft before sending.", at: email.date)
                    settled = (callID, "Sent on \(Prompt.day(email.date)) to \(email.to). Your owner edited it first. This is what was sent:\n\(email.body)",
                               Spec.render(new.approvedEdited, values))
                } else {
                    settled = (callID, "Sent on \(Prompt.day(email.date)) to \(email.to).", Spec.render(new.approved, values))
                }
            } else {
                let why = reason ?? "no reason given"
                file.log("owner_declined", why, at: now())
                file.standingInstructions.append(.init(date: now(), text: Spec.render(Spec.rules.instructions.declined, ["subject": draft.subject, "reason": why])))
                settled = (callID, "The owner said no: \(why). Nothing was sent.", Spec.render(new.declined, ["subject": draft.subject, "reason": why]))
            }
        case .needsAnswer(let callID, let question):
            guard case .answer(let answer) = wake else { return file }
            file.log("owner_answer", answer, at: now())
            file.standingInstructions.append(.init(date: now(), text: Spec.render(Spec.rules.instructions.answer, ["question": question, "answer": answer])))
            settled = (callID, answer, Spec.render(new.answer, ["question": question, "answer": answer]))
        case .waitingForReply(let callID, let until):
            if !file.inbox.isEmpty {
                let count = file.inbox.count
                settled = (callID, deliver(&file), Spec.render(new.mail, ["day": Prompt.day(now()), "count": String(count)]))
            } else if now() >= until || wake == .timer {
                file.log("wait", "No reply by \(Prompt.day(now())).", at: now())
                settled = (callID, "\(Prompt.day(now())): no reply yet after waiting.", Spec.render(new.timer, ["day": Prompt.day(now())]))
            } else {
                return file
            }
        case .closed:
            return file
        }

        file.state = .new
        let opening = file.transcript.isEmpty && settled == nil
        switch context {
        case .transcript:
            if let settled { file.transcript.append(.tool(callID: settled.callID, content: settled.result)) }
            return try await run(file, brief: nil)
        case .brief:
            let what = settled?.brief
                ?? (opening ? Spec.render(new.start, ["errand": file.errand, "company": file.company.name]) : new.resume)
            return try await run(file, brief: what)
        }
    }

    /// The owner's answer to the outcome check.
    private func answerOutcome(_ input: CaseFile, confirmed: Bool, note: String?) async throws -> CaseFile {
        var file = input
        guard case .closed = file.state, file.closure?.status == .done, file.proof != .owner else { return file }
        if file.outcomeCheck == nil {
            file.outcomeCheck = .init(due: now(), question: Spec.render(Spec.rules.outcomeCheck.defaultQuestion, ["company": file.company.name]))
        }
        file.outcomeCheck?.answer = confirmed
        file.outcomeCheck?.answeredAt = now()
        if confirmed {
            file.proof = .owner
            file.log("owner_confirmed", "You confirmed it's sorted.", at: now())
            return file
        }

        // Not sorted after all: the company's word wasn't enough. Reopen.
        let why = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "no details given"
        file.proof = .none
        file.closure = nil
        file.state = .new
        file.standingInstructions.append(.init(date: now(), text: Spec.render(Spec.rules.instructions.reopened, ["reason": why])))
        file.log("reopened", "You said it isn't sorted: \(why)", at: now())
        let told = Spec.render(Spec.rules.new.reopened, ["reason": why])
        switch context {
        case .transcript:
            file.transcript.append(.user(told))
            return try await run(file, brief: nil)
        case .brief:
            return try await run(file, brief: told)
        }
    }

    /// Call the model and carry out its tool calls until the case must wait.
    /// In brief mode, `brief` is what's new this wake, and the conversation
    /// starts afresh from the case brief.
    private func run(_ input: CaseFile, brief: String?) async throws -> CaseFile {
        var file = input
        let system = Prompt.system(for: file, today: now())
        if let brief {
            file.transcript = [.user(Brief.render(file, today: now(), new: brief))]
        } else if file.transcript.isEmpty {
            file.transcript.append(.user("Please handle this \(file.errand) with \(file.company.name)."))
        }

        do {
            return try await steps(&file, system: system)
        } catch {
            file.log("wake_failed", "Stopped partway: \(error). Resume to carry on.", at: now())
            throw WakeFailed(file: file, underlying: error)
        }
    }

    private func steps(_ file: inout CaseFile, system: String) async throws -> CaseFile {
        let tools = Spec.tools(for: context)
        for _ in 0..<maxSteps {
            let turn = try await model.complete(system: system, messages: file.transcript, tools: tools)
            file.transcript.append(.assistant(text: turn.text, toolCalls: turn.toolCalls))
            if turn.toolCalls.isEmpty {
                file.transcript.append(.user(Spec.rules.continuePrompt))
                continue
            }
            for (index, call) in turn.toolCalls.enumerated() {
                // Once the case has to wait, answer any further calls in this turn
                // so the transcript stays valid, and stop.
                if index > 0, file.state != .new {
                    file.transcript.append(.tool(callID: call.id, content: "Not run: the case is waiting. Call it again later if still needed."))
                    continue
                }
                file = try await handle(call, in: file, tools: tools)
            }
            if file.state != .new { return file }
        }
        throw TooManySteps()
    }

    private func handle(_ call: ToolCall, in input: CaseFile, tools: [ToolSpec]) async throws -> CaseFile {
        var file = input
        let args = call.arguments
        guard tools.contains(where: { $0.name == call.name }) else {
            file.transcript.append(.tool(callID: call.id, content: "Unknown tool \(call.name)."))
            return file
        }
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
            let days = min(Spec.rules.waitDays.max, max(Spec.rules.waitDays.min, args["max_days"]?.int ?? 7))
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
        case "note":
            let (notes, cut) = Brief.capNotes(args["text"]?.string ?? "")
            file.notes = notes
            let reply = cut ? Spec.render(Spec.rules.messages.notesCut, ["words": String(Spec.rules.notesMaxWords)]) : Spec.rules.messages.notesSaved
            file.transcript.append(.tool(callID: call.id, content: reply))
        case "close_case":
            let status = CaseFile.Closure.Status(rawValue: args["status"]?.string ?? "") ?? .needsOwner
            let summary = args["summary"]?.string ?? ""
            let evidence = args["evidence"]?.string ?? ""
            if status == .done {
                if let reason = Gate.checkEvidence(evidence, in: file) {
                    file.log("close_rejected", reason, at: now())
                    file.transcript.append(.tool(callID: call.id, content: "Not closed: \(reason)"))
                    break
                }
                // Mechanical checks first; the reviewer adds judgment, not proof.
                if let reviewer, case .reject(let why) = try await review(file, with: reviewer, summary: summary, evidence: evidence) {
                    let reason = Spec.render(Spec.rules.messages.reviewRejected, ["reason": why])
                    file.log("review_rejected", reason, at: now())
                    file.transcript.append(.tool(callID: call.id, content: "Not closed: \(reason)"))
                    break
                }
            }
            let closure = CaseFile.Closure(status: status, summary: summary, evidence: evidence, date: now())
            file.closure = closure
            file.state = .closed
            if status == .done {
                file.proof = .company
                file.outcomeCheck = outcomeCheck(for: file, days: args["check_after_days"]?.int, question: args["check_question"]?.string)
            }
            file.transcript.append(.tool(callID: call.id, content: "Case closed as \(status.rawValue)."))
            file.log("closed", "\(status.rawValue): \(closure.summary)", at: now())
        default:
            file.transcript.append(.tool(callID: call.id, content: "Unknown tool \(call.name)."))
        }
        return file
    }

    /// The reviewer reads the same brief the agent would, with the proposed
    /// close as what's new.
    private func review(_ file: CaseFile, with reviewer: any ModelClient, summary: String, evidence: String) async throws -> Review.Verdict {
        let brief = Brief.render(file, today: now(), new: Review.proposal(summary: summary, evidence: evidence))
        let turn = try await reviewer.complete(system: Review.system(for: file), messages: [.user(brief)], tools: [])
        return Review.verdict(turn.text ?? "")
    }

    /// When to ask the owner whether it really worked, and what.
    private func outcomeCheck(for file: CaseFile, days: Int?, question: String?) -> CaseFile.OutcomeCheck {
        let rules = Spec.rules.outcomeCheck
        let wanted = days.flatMap { $0 > 0 ? $0 : nil } ?? rules.defaultDays
        let clamped = min(rules.maxDays, max(rules.minDays, wanted))
        let due = Calendar(identifier: .gregorian).date(byAdding: .day, value: clamped, to: now()) ?? now()
        let asked = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .init(due: due, question: asked.isEmpty ? Spec.render(rules.defaultQuestion, ["company": file.company.name]) : asked)
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
