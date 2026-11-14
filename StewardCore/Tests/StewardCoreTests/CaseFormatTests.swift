import Foundation
import Testing
@testable import StewardCore

// Brief mode, send IDs, standing instructions, the reviewer and outcome checks
// (ADR 0002). Fixtures come from AgentTests.swift.

/// Replays fixed turns and keeps what the model was shown each time.
actor RecordingModel: ModelClient {
    private var turns: [AssistantTurn]
    private(set) var seen: [[ModelMessage]] = []
    private(set) var systems: [String] = []
    private(set) var toolNames: [[String]] = []

    init(_ turns: [AssistantTurn]) { self.turns = turns }

    func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        seen.append(messages)
        systems.append(system)
        toolNames.append(tools.map(\.name))
        guard !turns.isEmpty else { throw ScriptedModelClient.ScriptExhausted() }
        return turns.removeFirst()
    }
}

/// Fails the first `failures` sends, then records.
actor FlakyMail: MailSender {
    struct Down: Error {}
    private var failures: Int
    private(set) var attempts: [String?] = []
    private(set) var sent: [CaseFile.Email] = []
    init(failures: Int) { self.failures = failures }
    func send(_ email: CaseFile.Email, in file: CaseFile) async throws {
        attempts.append(email.sendID)
        if failures > 0 { failures -= 1; throw Down() }
        sent.append(email)
    }
}

private func firstUserText(_ messages: [ModelMessage]) -> String {
    if case .user(let text) = messages.first { return text }
    return ""
}

private let sendCall = call("1", "send_email", ["to": .string("kundenservice@fitwerk.example"), "subject": .string("Kündigung 448120"), "body": .string("Ich kündige. Lena Hoffmann")])

// MARK: Brief mode

@Test func briefModeStartsEachWakeFromTheBrief() async throws {
    let mail = SentMail(), clock = Clock()
    let model = RecordingModel([
        call("n", "note", ["text": .string("Plan: cite § 309 BGB.")]),
        sendCall,
        call("2", "wait_for_reply", ["max_days": .number(7)]),
        call("3", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("Wir bestätigen die Kündigung.")]),
    ])
    let steward = Agent(model: model, mail: mail, now: { clock.now }, context: .brief)

    var file = try await steward.wake(gymCase(), with: .start)
    #expect(file.notes == "Plan: cite § 309 BGB.")
    file = try await steward.wake(file, with: .approval(callID: "1", approved: true))
    clock.advance(days: 3)
    file = try await steward.wake(file, with: .mail([reply("Wir bestätigen die Kündigung zum 10.12.2026.", on: clock.now)]))
    #expect(file.state == .closed)

    let seen = await model.seen
    #expect(seen.count == 4)
    // Wake 1: the brief, then the conversation grows within the wake.
    #expect(firstUserText(seen[0]).contains("Your owner has just handed you this errand"))
    #expect(seen[1].count == 3)
    // Wake 2 starts afresh: one message, the brief, carrying the notes and the send.
    #expect(seen[2].count == 1)
    #expect(firstUserText(seen[2]).contains("Plan: cite § 309 BGB."))
    #expect(firstUserText(seen[2]).contains("Your owner approved your email \"Kündigung 448120\""))
    // Wake 3: the company's reply is in the brief, marked as data.
    #expect(seen[3].count == 1)
    #expect(firstUserText(seen[3]).contains("<email_content>\nWir bestätigen die Kündigung zum 10.12.2026.\n</email_content>"))
    #expect(firstUserText(seen[3]).contains("1 new email(s) from the company arrived"))
    #expect(await model.toolNames.allSatisfy { $0.contains("note") })
}

@Test func transcriptModeDoesNotOfferNotes() async throws {
    let mail = SentMail(), clock = Clock()
    let model = RecordingModel([
        call("n", "note", ["text": .string("x")]),
        call("2", "close_case", ["status": .string("failed"), "summary": .string("No."), "evidence": .string("")]),
    ])
    let file = try await Agent(model: model, mail: mail, now: { clock.now }).wake(gymCase(), with: .start)
    #expect(await model.toolNames.first == ["send_email", "wait_for_reply", "ask_owner", "close_case"])
    #expect(file.notes.isEmpty)
    #expect(file.transcript.contains { if case .tool("n", let c) = $0 { c == "Unknown tool note." } else { false } })
}

// MARK: Standing instructions

@Test func answersAndDeclinesBecomeStandingInstructions() async throws {
    let mail = SentMail(), clock = Clock()
    let steward = agent([
        call("q", "ask_owner", ["question": .string("Any new contract since 2024?")]),
        sendCall,
        call("2", "close_case", ["status": .string("needs_owner"), "summary": .string("Stopped."), "evidence": .string("")]),
    ], mail, clock)
    var file = try await steward.wake(gymCase(), with: .start)
    file = try await steward.wake(file, with: .answer("No, nothing new."))
    file = try await steward.wake(file, with: .approval(callID: "1", approved: false, reason: "Leave out the discount."))
    #expect(file.standingInstructions.map(\.text) == [
        "Asked \"Any new contract since 2024?\", they said: No, nothing new.",
        "Said no to the email \"Kündigung 448120\": Leave out the discount.",
    ])
}

// MARK: Send IDs

@Test func aFailedSendKeepsItsIDAndTheRetryReusesIt() async throws {
    let mail = FlakyMail(failures: 1), clock = Clock()
    let steward = Agent(model: ScriptedModelClient([sendCall, call("2", "wait_for_reply", ["max_days": .number(7)])]), mail: mail, now: { clock.now })
    let asking = try await steward.wake(gymCase(), with: .start)

    var saved = asking
    do {
        _ = try await steward.wake(asking, with: .approval(callID: "1", approved: true))
        Issue.record("expected the send to fail")
    } catch let failed as Agent.WakeFailed {
        saved = failed.file
    }
    guard case .needsApproval("1", let draft) = saved.state else { Issue.record("still waiting for approval, got \(saved.state)"); return }
    let id = try #require(draft.sendID)
    #expect(saved.emails.isEmpty)
    #expect(saved.events.last?.kind == "send_failed")

    let file = try await steward.wake(saved, with: .approval(callID: "1", approved: true))
    #expect(await mail.attempts == [id, id], "the retry hands over the same ID, so the relay can refuse a copy")
    #expect(await mail.sent.count == 1)
    #expect(file.emails.first?.sendID == id)
}

// MARK: Reviewer

@Test func theReviewerSendsAPrematureDoneBackToWork() async throws {
    let mail = SentMail(), clock = Clock()
    let reviewer = RecordingModel([
        AssistantTurn(text: "REJECT: They only acknowledged the request."),
        AssistantTurn(text: "ACCEPT"),
    ])
    let steward = Agent(model: ScriptedModelClient([
        call("1", "wait_for_reply", ["max_days": .number(7)]),
        call("2", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("Wir haben Ihre Kündigung erhalten.")]),
        call("3", "close_case", ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("Wir haben Ihre Kündigung erhalten.")]),
    ]), mail: mail, now: { clock.now }, reviewer: reviewer)
    var file = try await steward.wake(gymCase(), with: .start)
    file = try await steward.wake(file, with: .mail([reply("Wir haben Ihre Kündigung erhalten.", on: clock.now)]))

    #expect(file.events.contains { $0.kind == "review_rejected" && $0.detail.contains("They only acknowledged the request.") })
    #expect(file.transcript.contains { if case .tool("2", let c) = $0 { c.hasPrefix("Not closed: a reviewer") } else { false } })
    #expect(file.closure?.status == .done, "the second close was accepted")
    let systems = await reviewer.systems
    #expect(systems.first?.contains("Lena Hoffmann's goal: Cancel at the earliest date") == true)
    #expect(firstUserText(await reviewer.seen[0]).contains("Steward proposes to close this case as done."))
}

@Test func theReviewerIsNotAskedWhenTheEvidenceFailsTheRule() async throws {
    let mail = SentMail(), clock = Clock()
    let reviewer = RecordingModel([])
    let steward = Agent(model: ScriptedModelClient([
        call("1", "close_case", ["status": .string("done"), "summary": .string("Done."), "evidence": .string("It is cancelled.")]),
        call("2", "close_case", ["status": .string("failed"), "summary": .string("No reply."), "evidence": .string("")]),
    ]), mail: mail, now: { clock.now }, reviewer: reviewer)
    let file = try await steward.wake(gymCase(), with: .start)
    #expect(await reviewer.seen.isEmpty)
    #expect(file.closure?.status == .failed)
}

// MARK: Proof and outcome checks

private func closedDone(check days: Int? = nil, question: String? = nil, context: AgentContext = .transcript) async throws -> (CaseFile, Clock, SentMail) {
    let mail = SentMail(), clock = Clock()
    var args: [String: JSONValue] = ["status": .string("done"), "summary": .string("Cancelled."), "evidence": .string("Wir bestätigen die Kündigung.")]
    if let days { args["check_after_days"] = .number(Double(days)) }
    if let question { args["check_question"] = .string(question) }
    let steward = Agent(model: ScriptedModelClient([call("1", "wait_for_reply", ["max_days": .number(7)]), call("2", "close_case", args)]), mail: mail, now: { clock.now }, context: context)
    var file = try await steward.wake(gymCase(), with: .start)
    file = try await steward.wake(file, with: .mail([reply("Wir bestätigen die Kündigung zum 10.12.2026.", on: clock.now)]))
    return (file, clock, mail)
}

@Test func aDoneCloseIsCompanyProofWithAnOutcomeCheck() async throws {
    let (file, clock, _) = try await closedDone(check: 35, question: "Did the December debit stop?")
    #expect(file.proof == .company)
    let check = try #require(file.outcomeCheck)
    #expect(check.question == "Did the December debit stop?")
    #expect(check.due == clock.now.addingTimeInterval(35 * 86_400))
    #expect(!check.isDue(at: clock.now))
}

@Test func outcomeCheckFallsBackToTheRules() async throws {
    let (file, clock, _) = try await closedDone(check: 500)
    let check = try #require(file.outcomeCheck)
    #expect(check.due == clock.now.addingTimeInterval(90 * 86_400), "clamped to max_days")
    #expect(check.question == "Is it sorted? Did FitWerk Studios GmbH do what they confirmed?")
}

@Test func theOwnersYesIsTheStrongerProof() async throws {
    let (closed, clock, mail) = try await closedDone()
    let steward = Agent(model: ScriptedModelClient([]), mail: mail, now: { clock.now })
    let file = try await steward.wake(closed, with: .outcome(confirmed: true))
    #expect(file.proof == .owner)
    #expect(file.outcomeCheck?.answer == true)
    #expect(file.state == .closed)
    #expect(file.events.last?.kind == "owner_confirmed")
}

@Test func theOwnersNoReopensTheCase() async throws {
    for context in [AgentContext.transcript, .brief] {
        let (closed, clock, mail) = try await closedDone(context: context)
        let model = RecordingModel([call("9", "wait_for_reply", ["max_days": .number(7)])])
        let steward = Agent(model: model, mail: mail, now: { clock.now }, context: context)
        let file = try await steward.wake(closed, with: .outcome(confirmed: false, note: "They still took 39.90 in December."))
        #expect(file.proof == CaseFile.Proof.none)
        #expect(file.closure == nil)
        #expect(file.outcomeCheck?.answer == false)
        guard case .waitingForReply = file.state else { Issue.record("\(context): expected the agent to work again, got \(file.state)"); continue }
        #expect(file.standingInstructions.last?.text == "Said it isn't sorted after all: They still took 39.90 in December.")
        let shown = await model.seen[0]
        let told = shown.contains { if case .user(let t) = $0 { t.contains("isn't sorted after all") } else { false } }
        #expect(told, "\(context)")
    }
}

// MARK: Format

@Test func aCaseSavedBeforeTheNewFieldsStillOpens() throws {
    let old = """
    {"id":"6F1C2A4E-0000-4000-8000-000000000001","errand":"cancel","createdAt":"2026-11-10T12:00:00Z",
     "owner":{"name":"Lena","caseAddress":"c@steward.example","accountRef":"","facts":"","goal":"Cancel","willNot":[],"secrets":[]},
     "company":{"name":"FitWerk","domain":"fitwerk.example","email":"k@fitwerk.example"},
     "emails":[{"direction":"outgoing","date":"2026-11-10T12:00:00Z","from":"c@steward.example","to":"k@fitwerk.example","subject":"S","body":"B"}],
     "events":[],"inbox":[],"transcript":[],"state":{"closed":{}}}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let file = try decoder.decode(CaseFile.self, from: Data(old.utf8))
    #expect(file.standingInstructions.isEmpty)
    #expect(file.notes.isEmpty)
    #expect(file.proof == CaseFile.Proof.none)
    #expect(file.outcomeCheck == nil)
    #expect(file.emails.first?.sendID == nil)
    #expect(file.state == .closed)
}
