import Foundation
import Testing
@testable import StewardCore

// MARK: Fixtures

actor SentMail: MailSender {
    private(set) var sent: [CaseFile.Email] = []
    func send(_ email: CaseFile.Email, caseID: UUID) async throws { sent.append(email) }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_794_268_800) // Tue 10 Nov 2026
    var now: Date { lock.withLock { current } }
    func advance(days: Int) { lock.withLock { current = current.addingTimeInterval(Double(days) * 86_400) } }
}

func gymCase() -> CaseFile {
    CaseFile(
        errand: "cancel",
        createdAt: Date(timeIntervalSince1970: 1_794_268_800),
        owner: .init(
            name: "Lena Hoffmann",
            caseAddress: "case-7f3a@steward.example",
            accountRef: "Mitgliedsnummer 448120",
            facts: "Joined 1 March 2024 on a 24-month contract.",
            goal: "Cancel at the earliest date with written confirmation.",
            willNot: ["accept a discount"],
            secrets: ["DE89 3704 0044 0532 0130 00"]
        ),
        company: .init(name: "FitWerk Studios GmbH", domain: "fitwerk.example", email: "kundenservice@fitwerk.example")
    )
}

func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> AssistantTurn {
    AssistantTurn(toolCalls: [ToolCall(id: id, name: name, arguments: args)])
}

func reply(_ body: String, on date: Date) -> CaseFile.Email {
    CaseFile.Email(direction: .incoming, date: date, from: "kundenservice@fitwerk.example", to: "case-7f3a@steward.example", subject: "Re: Kündigung", body: body)
}

func agent(_ turns: [AssistantTurn], _ mail: SentMail, _ clock: Clock) -> Agent {
    Agent(model: ScriptedModelClient(turns), mail: mail, now: { clock.now })
}

// MARK: Tests

@Test func fullErrandSuspendsAndResumesAtEachWait() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("1", "send_email", ["to": .string("kundenservice@fitwerk.example"), "subject": .string("Kündigung 448120"), "body": .string("Ich kündige. Lena Hoffmann")]),
        call("2", "wait_for_reply", ["max_days": .number(7)]),
        call("3", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("Wir bestätigen die Kündigung.")]),
    ], mail, clock)

    var file = try await steward.wake(gymCase(), with: .start)
    guard case .needsApproval(_, let draft) = file.state else { Issue.record("expected approval, got \(file.state)"); return }
    #expect(draft.from == "case-7f3a@steward.example")
    #expect(await mail.sent.isEmpty, "nothing goes out before the owner taps")

    file = try await steward.wake(file, with: .approval(approved: true))
    guard case .waitingForReply = file.state else { Issue.record("expected waiting, got \(file.state)"); return }
    #expect(await mail.sent.count == 1)

    clock.advance(days: 3)
    file = try await steward.wake(file, with: .mail([reply("Wir bestätigen die Kündigung zum 10.12.2026.", on: clock.now)]))
    #expect(file.state == .closed)
    #expect(file.closure?.status == .done)
    #expect(file.emails.map(\.direction) == [.outgoing, .incoming])
}

@Test func ownerCanEditTheBodyBeforeApproving() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("1", "send_email", ["to": .string("kundenservice@fitwerk.example"), "subject": .string("Kündigung"), "body": .string("Draft")]),
        call("2", "close_case", ["status": .string("needs_owner"), "summary": .string("Sent."), "evidence": .string("")]),
    ], mail, clock)
    let file = try await steward.wake(try await steward.wake(gymCase(), with: .start), with: .approval(approved: true, editedBody: "Edited by Lena"))
    #expect(await mail.sent.first?.body == "Edited by Lena")
    #expect(file.state == .closed)
}

@Test func declinedDraftIsNeverSent() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("1", "send_email", ["to": .string("kundenservice@fitwerk.example"), "subject": .string("Offer"), "body": .string("I'll take the discount.")]),
        call("2", "close_case", ["status": .string("needs_owner"), "summary": .string("Owner declined."), "evidence": .string("")]),
    ], mail, clock)
    let file = try await steward.wake(try await steward.wake(gymCase(), with: .start), with: .approval(approved: false, reason: "I said cancel"))
    #expect(await mail.sent.isEmpty)
    #expect(file.transcript.contains(.tool(callID: "1", content: "The owner said no: I said cancel. Nothing was sent.")))
}

@Test func wrongRecipientIsBlockedWithoutAskingTheOwner() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("1", "send_email", ["to": .string("verify@fitwerk-billing.example"), "subject": .string("Verify"), "body": .string("Details")]),
        call("2", "close_case", ["status": .string("failed"), "summary": .string("Stopped."), "evidence": .string("")]),
    ], mail, clock)
    let file = try await steward.wake(gymCase(), with: .start)
    #expect(file.state == .closed)
    #expect(file.events.contains { $0.kind == "gate_block" })
    #expect(await mail.sent.isEmpty)
}

@Test func privateDetailIsBlockedEvenWithDashes() async throws {
    let verdict = Gate.check(to: "kundenservice@fitwerk.example", subject: "IBAN", body: "Mein Konto: de89-3704-0044-0532-0130-00", in: gymCase())
    #expect(verdict == .blocked("The email contains a private detail the owner never shares by email."))
}

@Test func silenceWakesTheAgentToFollowUp() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("1", "wait_for_reply", ["max_days": .number(5)]),
        call("2", "close_case", ["status": .string("failed"), "summary": .string("No answer."), "evidence": .string("")]),
    ], mail, clock)
    var file = try await steward.wake(gymCase(), with: .start)
    guard case .waitingForReply(_, let until) = file.state else { Issue.record("expected waiting"); return }

    // Woken early with nothing new: stays asleep.
    file = try await steward.wake(file, with: .start)
    #expect(file.state == .waitingForReply(callID: "1", until: until))

    clock.advance(days: 5)
    file = try await steward.wake(file, with: .timer)
    #expect(file.state == .closed)
    #expect(file.transcript.contains { if case .tool("1", let c) = $0 { c.contains("no reply yet") } else { false } })
}

@Test func mailDuringApprovalIsKeptForTheNextWait() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("1", "send_email", ["to": .string("kundenservice@fitwerk.example"), "subject": .string("Kündigung"), "body": .string("Bitte kündigen.")]),
        call("2", "wait_for_reply", ["max_days": .number(7)]),
        call("3", "close_case", ["status": .string("done"), "summary": .string("Done."), "evidence": .string("bestätigt")]),
    ], mail, clock)
    var file = try await steward.wake(gymCase(), with: .start)
    file = try await steward.wake(file, with: .mail([reply("Bestätigt.", on: clock.now)]))
    guard case .needsApproval = file.state else { Issue.record("mail must not skip the approval"); return }
    #expect(file.inbox.count == 1)

    file = try await steward.wake(file, with: .approval(approved: true))
    #expect(file.state == .closed, "the queued reply is delivered at once, no waiting")
    #expect(file.inbox.isEmpty)
}

@Test func caseFileRoundTripsThroughTheStore() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([call("1", "ask_owner", ["question": .string("What is your member number?")])], mail, clock)
    let file = try await steward.wake(gymCase(), with: .start)
    let store = CaseStore(folder: FileManager.default.temporaryDirectory.appending(path: "steward-\(UUID())"))
    try store.save(file)
    #expect(try store.load(file.id) == file)
    #expect(try store.all().count == 1)
}

@Test func failedWakeAfterApprovalKeepsTheSentEmailSoItIsNotResent() async throws {
    let mail = SentMail(), clock = Clock()
    // The model answers once, then becomes unreachable right after the send.
    let steward = agent([
        call("1", "send_email", ["to": .string("kundenservice@fitwerk.example"), "subject": .string("Kündigung"), "body": .string("Bitte kündigen.")]),
    ], mail, clock)
    let asking = try await steward.wake(gymCase(), with: .start)

    var saved = asking
    do {
        _ = try await steward.wake(asking, with: .approval(approved: true))
        Issue.record("expected the wake to fail")
    } catch let failed as Agent.WakeFailed {
        #expect(failed.underlying is ScriptedModelClient.ScriptExhausted)
        saved = failed.file
    }
    #expect(await mail.sent.count == 1)
    #expect(saved.state == .new, "no longer waiting for approval, so it can't be approved twice")
    #expect(saved.emails.map(\.direction) == [.outgoing])
    #expect(saved.events.contains { $0.kind == "wake_failed" })

    // Resuming carries on from the saved file without sending again.
    let resumed = agent([
        call("2", "close_case", ["status": .string("needs_owner"), "summary": .string("Sent, awaiting reply."), "evidence": .string("")]),
    ], mail, clock)
    let file = try await resumed.wake(saved, with: .start)
    #expect(file.state == .closed)
    #expect(await mail.sent.count == 1)
}

@Test func doneWithoutTheCompanysWordsIsRejected() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("1", "wait_for_reply", ["max_days": .number(7)]),
        call("2", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("Your membership is cancelled.")]),
        call("3", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("“Wir bestätigen die Kündigung” … zum 10.12.2026")]),
    ], mail, clock)
    var file = try await steward.wake(gymCase(), with: .start)
    file = try await steward.wake(file, with: .mail([reply("Hallo! Wir bestätigen die Kündigung zum 10.12.2026. Grüße", on: clock.now)]))

    #expect(file.transcript.contains { if case .tool("2", let c) = $0 { c.hasPrefix("Not closed:") } else { false } })
    #expect(file.events.contains { $0.kind == "close_rejected" })
    #expect(file.closure?.status == .done, "a faithful quote with typographic marks and an ellipsis passes")
}

@Test func evidenceRules() {
    var file = gymCase()
    file.emails = [
        CaseFile.Email(direction: .outgoing, date: .now, from: "case-7f3a@steward.example", to: "kundenservice@fitwerk.example", subject: "Kündigung", body: "Bitte bestätigen Sie die Kündigung schriftlich."),
        reply("Wir haben Ihre Anfrage erhalten.", on: .now),
    ]
    #expect(Gate.checkEvidence("", in: file) != nil, "empty")
    #expect(Gate.checkEvidence("ok", in: file) != nil, "too short to show anything")
    #expect(Gate.checkEvidence("bestätigen Sie die Kündigung", in: file) != nil, "the owner's own email is not evidence")
    #expect(Gate.checkEvidence("WIR HABEN IHRE ANFRAGE ERHALTEN", in: file) == nil)
    #expect(Gate.checkEvidence("Wir haben ... erhalten", in: file) == nil)
}
