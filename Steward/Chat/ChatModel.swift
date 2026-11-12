import Foundation
import Observation
import StewardCore

/// Chat's engine. Every conversation is a saved Steward task (see
/// `TasksModel`), so Chats and Tasks show the same threads. This model routes
/// what the owner writes and runs the one errand under way: the scripted demo
/// while no agent is connected, or a real case through the runner. It writes
/// what happens into the conversation as words and reply blocks, and drives
/// the Steward pill.
@MainActor
@Observable
final class ChatModel {
    let tasks: TasksModel

    /// The errand under way, one at a time, and the conversation it runs in.
    private(set) var errand: Errand?
    private(set) var errandConversationID: UUID?
    /// The message whose blocks show the errand's steps.
    private var stepsMessageID: UUID?
    /// The message holding the draft that waits for the owner's yes.
    private(set) var approvalMessageID: UUID?
    /// Steward is working on the errand right now (not the general agent).
    private(set) var isErrandWorking = false
    private(set) var showsDone = false
    /// Bumps when the pill's Review is tapped, so the thread can scroll to the draft.
    private(set) var reviewRequest = 0

    /// Demo: Steward asked which email the membership is under.
    private var awaitingDemoEmail = false
    /// Agent run: the case whose question the owner's next message answers.
    private var questionCaseID: UUID?

    private let runner: CaseRunner?
    private let pace: Duration = .seconds(1.8)
    private var runTask: Task<Void, Never>?

    init(tasks: TasksModel, runner: CaseRunner?) {
        self.tasks = tasks
        self.runner = runner
        runner?.observe { [weak self] before, after, origin in
            guard origin != .chat else { return }
            self?.caughtUp(before, after)
        }
    }

    // MARK: Reading

    var activity: StewardActivity {
        if showsDone { return .done }
        guard let errand else { return .idle }
        if errand.phase == .needsYou { return .needsYou }
        guard let index = errand.steps.firstIndex(where: { $0.state == .active }) else { return .idle }
        return .working(step: errand.steps[index].activeTitle, number: index + 1, total: errand.steps.count)
    }

    /// Steward is busy in this conversation, on an errand or a general task.
    func isWorking(in id: UUID) -> Bool {
        (isErrandWorking && errandConversationID == id) || tasks.working.contains(id)
    }

    /// Whether a draft in this conversation can still be approved here.
    func isLive(_ draft: ReplyBlock.Draft, message messageID: UUID, in id: UUID) -> Bool {
        guard draft.status == .pending else { return false }
        if let caseID = draft.caseID {
            guard let file = runner?.cases[caseID] ?? tasks.file(caseID), case .needsApproval = file.state else { return false }
            return true
        }
        return errandConversationID == id && approvalMessageID == messageID
    }

    /// False when nothing really goes out: the demo, or the simulated run.
    func sendsForReal(_ draft: ReplyBlock.Draft) -> Bool {
        draft.caseID != nil && runner != nil && runner?.isSimulated == false
    }

    // MARK: The owner writes

    /// Sends the owner's words, starting a conversation when `id` is nil.
    /// Returns the conversation they went to.
    @discardableResult
    func send(_ raw: String, in id: UUID?) -> UUID? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return id }
        let wantsErrand = Self.isErrandRequest(text)

        guard let id else {
            let id = tasks.startConversation(text, wakes: !(wantsErrand && errand == nil))
            if wantsErrand, errand == nil, let id { startErrand(in: id) }
            return id
        }
        if id == errandConversationID, awaitingDemoEmail {
            tasks.post(id, .owner, text)
            awaitingDemoEmail = false
            runTask = Task { await continueDemo(id) }
            return id
        }
        if id == errandConversationID, let caseID = questionCaseID, !isErrandWorking {
            tasks.post(id, .owner, text)
            questionCaseID = nil
            errand?.phase = .running
            if let index = errand?.steps.firstIndex(where: { $0.state == .waiting }) { setStep(index, .active) }
            tasks.setState(id, .working)
            runTask = Task { await advance(caseID) { try await $0.wake(caseID, with: .answer(text)) } }
            return id
        }
        if wantsErrand {
            tasks.post(id, .owner, text)
            if errand == nil {
                startErrand(in: id)
            } else {
                tasks.post(id, .steward, "I'm already on one errand. Finish or stop it first, and I'll start this one.")
            }
            return id
        }
        tasks.send(id, text)
        return id
    }

    /// "Cancel my…" starts an errand; so does the demo's own button. Narrow
    /// on purpose, so "don't cancel anything yet" stays a message.
    static func isErrandRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text == TasksModel.demoChoice || lower.hasPrefix("cancel ") || lower.contains("cancel my ")
    }

    // MARK: Drafts

    func approve(message messageID: UUID, in id: UUID) {
        guard let draft = draft(messageID, in: id), isLive(draft, message: messageID, in: id) else { return }
        setDraftStatus(.approved, message: messageID, in: id)
        errand?.phase = .running
        tasks.setState(id, .working)
        if let caseID = draft.caseID, let runner, case .needsApproval(let callID, let original) = runner.cases[caseID]?.state {
            let edited = draft.body == original.body ? nil : draft.body
            if errand?.id == caseID { setStage(1, .active) }
            runTask = Task { await advance(caseID) { try await $0.wake(caseID, with: .approval(callID: callID, approved: true, editedBody: edited)) } }
            return
        }
        setStep(3, .active)
        runTask = Task { await finishDemo(id) }
    }

    func decline(message messageID: UUID, in id: UUID) {
        guard let draft = draft(messageID, in: id), isLive(draft, message: messageID, in: id) else { return }
        setDraftStatus(.declined, message: messageID, in: id)
        if let caseID = draft.caseID, let runner, case .needsApproval(let callID, _) = runner.cases[caseID]?.state {
            // The agent hears the no and decides what's next; usually it closes.
            errand?.phase = .running
            if errand?.id == caseID { setStage(1, .active) }
            runTask = Task { await advance(caseID) { try await $0.wake(caseID, with: .approval(callID: callID, approved: false, reason: "The owner declined this draft.")) } }
            return
        }
        close()
        tasks.setState(id, .stopped(date: .now))
        tasks.post(id, .steward, "Okay, nothing was sent. Your membership stays as it is.")
    }

    func editDraft(message messageID: UUID, in id: UUID, body: String) {
        guard let index = blockIndex(messageID, in: id, where: { if case .draft = $0 { true } else { false } }) else { return }
        tasks.editBlock(id, messageID, at: index) { block in
            if case .draft(var draft) = block {
                draft.body = body
                block = .draft(draft)
            }
        }
    }

    func stopErrand() {
        guard let id = errandConversationID else { return }
        runTask?.cancel()
        if let messageID = approvalMessageID, let draft = draft(messageID, in: id), draft.status == .pending {
            setDraftStatus(.declined, message: messageID, in: id)
        }
        questionCaseID = nil
        awaitingDemoEmail = false
        close()
        isErrandWorking = false
        tasks.setState(id, .stopped(date: .now))
        tasks.post(id, .steward, "Stopped. Nothing was sent.")
    }

    /// The pill's Review: the thread scrolls to the waiting draft.
    func review() { reviewRequest += 1 }

    // MARK: Errands

    private func startErrand(in id: UUID) {
        if runner != nil { startAgentErrand(in: id) } else { startDemo(in: id) }
    }

    private func begin(_ errand: Errand, in id: UUID) {
        runTask?.cancel()
        self.errand = errand
        errandConversationID = id
        approvalMessageID = nil
        stepsMessageID = nil
        showsDone = false
        tasks.setState(id, .working)
    }

    private func close() {
        errand?.phase = .stopped
        if let steps = errand?.steps {
            for index in steps.indices where steps[index].state != .done { errand?.steps[index].state = .pending }
        }
        syncSteps()
        errand = nil
        awaitingDemoEmail = false
        questionCaseID = nil
    }

    @discardableResult
    private func say(_ text: String, _ blocks: [ReplyBlock] = [], in id: UUID) -> UUID? {
        tasks.post(id, .steward, text, blocks: blocks)
    }

    // MARK: Scripted demo

    private func startDemo(in id: UUID) {
        begin(.demoGymCancellation(), in: id)
        setStep(0, .active, sync: false)
        stepsMessageID = say("On it. I'll check your notice period first, so you don't pay for another month.", [errand!.stepsBlock], in: id)
        runTask = Task {
            do { try await Task.sleep(for: pace) } catch { return }
            setStep(0, .waiting)
            errand?.phase = .needsYou
            awaitingDemoEmail = true
            let question = "Which email is your membership under?"
            say(question, [.field(.init(label: "Membership email", kind: .email, placeholder: "name@example.com"))], in: id)
            tasks.setState(id, .needsAnswer(question: question))
        }
    }

    private func continueDemo(_ id: UUID) async {
        do {
            errand?.phase = .running
            tasks.setState(id, .working)
            setStep(0, .done)
            setStep(1, .active)
            try await Task.sleep(for: pace)
            setStep(1, .done)
            setStep(2, .active)
            let calendar = Calendar.current
            let lastDay = calendar.date(byAdding: .day, value: 6, to: .now) ?? .now
            let payment = calendar.date(byAdding: .day, value: 7, to: .now) ?? .now
            say("You have 6 days. After that you pay for one more month.", [.deadline(.init(
                title: "6 days left to cancel", progress: 0.8,
                rows: [.init(label: "Last day to cancel", value: Self.day(lastDay)),
                       .init(label: "Next payment, $39", value: Self.day(payment))]
            ))], in: id)
            try await Task.sleep(for: pace)
            setStep(2, .done)
            setStep(3, .waiting)
            errand?.phase = .needsYou
            approvalMessageID = say("Here's exactly what I'll send. Nothing goes until you say yes.", [.draft(.init(
                to: "members@northside-gym.example",
                subject: "Please cancel my membership",
                body: "Hello,\n\nPlease cancel my membership and confirm the date it ends. I'm giving notice within the period in your terms.\n\nThank you."
            ))], in: id)
            tasks.setState(id, .needsAnswer(question: "Approve the email to Northside Gym"))
        } catch {}
    }

    private func finishDemo(_ id: UUID) async {
        do {
            try await Task.sleep(for: pace)
            setStep(3, .done)
            setStep(4, .active)
            try await Task.sleep(for: pace)
            setStep(4, .done)
            let summary = "Your membership is cancelled, and you won't be charged again."
            say("Done. \(summary)", [.proof(.init(
                headline: "Membership cancelled",
                detail: "No more payments after \(Self.day(Calendar.current.date(byAdding: .day, value: 6, to: .now) ?? .now)).",
                quote: "We've cancelled your membership as requested. No further payments will be taken.",
                source: "Northside Gym (demo)",
                date: .now
            ))], in: id)
            errand?.phase = .finished
            errand = nil
            tasks.setState(id, .done(date: .now, confirmedByOwner: false), result: summary)
            await flashDone()
        } catch {}
    }

    private func flashDone() async {
        showsDone = true
        try? await Task.sleep(for: .seconds(3))
        if !Task.isCancelled { showsDone = false }
    }

    // MARK: Agent run

    private func startAgentErrand(in id: UUID) {
        guard let runner else { return }
        let file = SimulatedErrand.gymCancellation()
        do {
            try runner.open(file)
        } catch {
            say("I couldn't save this errand on your phone, so I haven't started it.", in: id)
            return
        }
        tasks.setCase(id, file.id)
        begin(.agentErrand(id: file.id, title: SimulatedErrand.title, label: runner.isSimulated ? "Simulated" : nil), in: id)
        setStage(0, .active, sync: false)
        stepsMessageID = say("On it. I'll write to \(file.company.name) and show you the email before anything goes out.", [errand!.stepsBlock], in: id)
        runTask = Task { await advance(file.id) { try await $0.wake(file.id, with: .start) } }
    }

    /// Wakes the agent through `work`, then shows where the case now stands.
    private func advance(_ caseID: UUID, _ work: (CaseRunner) async throws -> CaseFile?) async {
        guard let runner, let before = runner.cases[caseID] else { return }
        isErrandWorking = true
        do {
            let file = try await work(runner)
            isErrandWorking = false
            guard !Task.isCancelled, let file else { return }
            show(file, newEvents: file.events.dropFirst(before.events.count))
        } catch {
            isErrandWorking = false
            guard !Task.isCancelled, let id = conversationID(for: caseID) else { return }
            if errand?.id == caseID { close() }
            tasks.setState(id, .handedBack(note: "Paused after a problem", date: .now))
            say("I couldn't finish that step, so I've paused this errand. Nothing more goes out without your OK.", in: id)
        }
    }

    private func conversationID(for caseID: UUID) -> UUID? {
        if errand?.id == caseID, let id = errandConversationID { return id }
        return tasks.conversation(carrying: caseID)?.id
    }

    /// The owner acted on a chat errand from Tasks: show the same outcome
    /// here, as if they had tapped it in chat.
    private func caughtUp(_ before: CaseFile, _ after: CaseFile) {
        guard let id = conversationID(for: after.id) else { return }
        let newEvents = after.events.dropFirst(before.events.count)
        if let messageID = pendingDraftMessage(for: after.id, in: id) {
            if newEvents.contains(where: { $0.kind == "email_out" }) {
                setDraftStatus(.approved, message: messageID, in: id)
            } else if newEvents.contains(where: { $0.kind == "owner_declined" }) {
                setDraftStatus(.declined, message: messageID, in: id)
            }
        }
        if questionCaseID == after.id, let answer = newEvents.first(where: { $0.kind == "owner_answer" }) {
            questionCaseID = nil
            tasks.post(id, .owner, answer.detail)
        }
        show(after, newEvents: newEvents)
    }

    private func show(_ file: CaseFile, newEvents: ArraySlice<CaseFile.Event>) {
        guard let id = conversationID(for: file.id) else { return }
        let isLive = errand?.id == file.id
        if newEvents.contains(where: { $0.kind == "email_in" }) {
            say("\(file.company.name) replied. Reading it now.", in: id)
        }
        switch file.state {
        case .new:
            break
        case .needsApproval(_, let draft):
            guard pendingDraftMessage(for: file.id, in: id) == nil else { return }
            if isLive {
                errand?.phase = .needsYou
                setStage(1, .waiting)
            }
            approvalMessageID = say("Here's exactly what I'll send. Nothing goes until you say yes.",
                                    [.draft(.init(to: draft.to, subject: draft.subject, body: draft.body, caseID: file.id))], in: id)
            tasks.setState(id, .needsAnswer(question: "Approve the email to \(file.company.name)"))
        case .needsAnswer(_, let question):
            if isLive {
                errand?.phase = .needsYou
                if let index = errand?.steps.firstIndex(where: { $0.state == .active }) { setStep(index, .waiting) }
            }
            questionCaseID = file.id
            say(question, in: id)
            tasks.setState(id, .needsAnswer(question: question))
        case .waitingForReply(_, let until):
            if isLive {
                errand?.phase = .running
                setStage(2, .active)
            }
            if newEvents.contains(where: { $0.kind == "email_out" }) {
                say("Sent to \(file.company.name). I'll watch for their reply and pick it up as soon as it lands.", in: id)
            } else {
                say("I'm waiting for \(file.company.name) to reply, until \(until.formatted(.dateTime.month(.wide).day())) at the latest.", in: id)
            }
            tasks.setState(id, .waiting(until: until, note: "Waiting for \(file.company.name)"))
            if runner?.isSimulated == true, isLive {
                runTask = Task { await collectSimulatedReply(file.id) }
            }
        case .closed:
            finish(file, in: id)
        }
    }

    private func finish(_ file: CaseFile, in id: UUID) {
        guard let closure = file.closure, closure.status == .done else {
            if errand?.id == file.id { close() }
            let summary = file.closure?.summary ?? "I've stopped this errand."
            say(summary, in: id)
            tasks.setState(id, file.closure?.status == .needsOwner
                ? .handedBack(note: "Over to you", date: .now)
                : .stopped(date: .now), result: summary)
            return
        }
        if errand?.id == file.id {
            setStage(errand?.steps.count ?? 0, .done)
            errand = nil
        }
        say("Done. \(closure.summary)", [.proof(.init(
            headline: "Confirmed by \(file.company.name)",
            detail: closure.summary,
            quote: closure.evidence.isEmpty ? nil : closure.evidence,
            source: file.company.email,
            date: closure.date
        ))], in: id)
        tasks.setState(id, .done(date: closure.date, confirmedByOwner: false), result: closure.summary)
        runTask = Task { await flashDone() }
    }

    /// Simulated relay only: the company's reply arrives a moment after sending.
    private func collectSimulatedReply(_ caseID: UUID) async {
        do { try await Task.sleep(for: pace * 2) } catch { return }
        setStage(3, .active)
        await advance(caseID) { try await $0.collectMail(for: caseID) }
        if runner?.cases[caseID]?.inbox.isEmpty == true, case .waitingForReply = runner?.cases[caseID]?.state {
            setStage(2, .active)
        }
    }

    // MARK: Steps and blocks

    /// Marks steps before `index` done, `index` as `state`, and the rest not started.
    private func setStage(_ index: Int, _ state: Errand.StepState, sync: Bool = true) {
        guard let count = errand?.steps.count else { return }
        for step in 0..<count {
            errand?.steps[step].state = step < index ? .done : step == index ? state : .pending
        }
        if sync { syncSteps() }
    }

    private func setStep(_ index: Int, _ state: Errand.StepState, sync: Bool = true) {
        guard let steps = errand?.steps, steps.indices.contains(index) else { return }
        errand?.steps[index].state = state
        if sync { syncSteps() }
    }

    /// Writes the errand's steps into its steps block, so the record matches.
    private func syncSteps() {
        guard let errand, let id = errandConversationID, let messageID = stepsMessageID,
              let index = blockIndex(messageID, in: id, where: { if case .steps = $0 { true } else { false } })
        else { return }
        tasks.editBlock(id, messageID, at: index) { $0 = errand.stepsBlock }
    }

    private func draft(_ messageID: UUID, in id: UUID) -> ReplyBlock.Draft? {
        tasks.stewardTask(id)?.messages.first { $0.id == messageID }?.allBlocks.lazy.compactMap { block -> ReplyBlock.Draft? in
            if case .draft(let draft) = block { draft } else { nil }
        }.first
    }

    private func pendingDraftMessage(for caseID: UUID, in id: UUID) -> UUID? {
        tasks.stewardTask(id)?.messages.last { message in
            message.allBlocks.contains { block in
                if case .draft(let draft) = block { draft.caseID == caseID && draft.status == .pending } else { false }
            }
        }?.id
    }

    private func setDraftStatus(_ status: ReplyBlock.Draft.Status, message messageID: UUID, in id: UUID) {
        guard let index = blockIndex(messageID, in: id, where: { if case .draft = $0 { true } else { false } }) else { return }
        tasks.editBlock(id, messageID, at: index) { block in
            if case .draft(var draft) = block {
                draft.status = status
                block = .draft(draft)
            }
        }
    }

    private func blockIndex(_ messageID: UUID, in id: UUID, where match: (ReplyBlock) -> Bool) -> Int? {
        tasks.stewardTask(id)?.messages.first { $0.id == messageID }?.allBlocks.firstIndex(where: match)
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension ChatModel {
    /// `-uiState errand` starts the scripted demo and `-uiState agent` the
    /// simulated agent run, each in a fresh conversation. Other states read
    /// whatever conversations the store holds (see `CaseService`).
    static func launch(tasks: TasksModel) -> ChatModel {
        let model = ChatModel(tasks: tasks, runner: CaseService.runner)
        switch UserDefaults.standard.string(forKey: "uiState") {
        case "errand", "agent":
            model.send("Cancel my gym membership.", in: nil)
        default:
            break
        }
        return model
    }
}

extension StewardTask {
    /// Extra conversations for `-uiState chats`: a finished errand with its
    /// proof, beside the sample tasks. Companies are fictional.
    static func chatSamples(now: Date = .now) -> [StewardTask] {
        func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86_400) }
        var mealKit = StewardTask(goal: "Cancel my meal kit subscription", createdAt: day(-9))
        mealKit.messages = [
            .init(author: .owner, text: "Cancel my meal kit subscription", date: day(-9)),
            .init(author: .steward, text: "Done. Fresh Fork cancelled it, and no more boxes or charges will come.", date: day(-8), blocks: [
                .proof(.init(headline: "Confirmed by Fresh Fork", detail: "No more boxes or charges.",
                             quote: "We can confirm your subscription has been cancelled and no further payments will be taken.",
                             source: "help@freshfork.example", date: day(-8))),
            ]),
        ]
        mealKit.state = .done(date: day(-8), confirmedByOwner: false)
        mealKit.result = "Fresh Fork cancelled the subscription."
        mealKit.pinned = true
        return [mealKit]
    }
}
