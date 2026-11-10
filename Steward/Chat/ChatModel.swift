import Foundation
import Observation
import StewardCore

struct ChatMessage: Identifiable, Equatable {
    enum Author { case owner, steward }
    enum Status { case sending, delivered, failed }
    enum Attachment: Equatable {
        case progress(UUID)
        case deadline(DeadlineInfo)
        case approval(UUID)
    }

    let id: UUID
    let author: Author
    let text: String
    let date: Date
    var status: Status
    var attachment: Attachment?

    init(author: Author, text: String, date: Date = .now, status: Status = .delivered, attachment: Attachment? = nil) {
        self.id = UUID()
        self.author = author
        self.text = text
        self.date = date
        self.status = status
        self.attachment = attachment
    }
}

/// Where replies come from. The real agent replaces `PreviewChatService`.
protocol ChatService {
    func reply(to text: String) async throws -> String
}

struct PreviewChatService: ChatService {
    struct Unavailable: Error {}
    var fails = false

    func reply(to text: String) async throws -> String {
        try await Task.sleep(for: .seconds(1.2))
        if fails { throw Unavailable() }
        return "I'm not connected yet, so I can't act on this. To see a demo, ask me to cancel something."
    }
}

@MainActor
@Observable
final class ChatModel {
    private(set) var messages: [ChatMessage]
    private(set) var isStewardWorking = false
    private(set) var errands: [UUID: Errand] = [:]
    private(set) var activeErrandID: UUID?
    private(set) var showsDone = false
    var showsSampleLabel: Bool

    private let service: ChatService
    private let pace: Duration = .seconds(1.8)
    private var runTask: Task<Void, Never>?
    /// Runs real errands through the agent. `nil` keeps chat on the scripted demo.
    private let runner: CaseRunner?
    /// The case whose question the owner's next message answers.
    private var questionCaseID: UUID?

    init(messages: [ChatMessage], showsSampleLabel: Bool, service: ChatService, runner: CaseRunner? = nil) {
        self.messages = messages
        self.showsSampleLabel = showsSampleLabel
        self.service = service
        self.runner = runner
    }

    var activeErrand: Errand? { activeErrandID.flatMap { errands[$0] } }

    var activity: StewardActivity {
        if showsDone { return .done }
        guard let errand = activeErrand else { return .idle }
        if errand.phase == .needsYou { return .needsYou }
        guard let index = errand.steps.firstIndex(where: { $0.state == .active }) else { return .idle }
        return .working(step: errand.steps[index].activeTitle, number: index + 1, total: errand.steps.count)
    }

    var pendingApprovalMessageID: UUID? {
        guard let id = activeErrandID else { return nil }
        return messages.last { $0.attachment == .approval(id) }?.id
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = questionCaseID, !isStewardWorking {
            messages.append(ChatMessage(author: .owner, text: text))
            questionCaseID = nil
            errands[id]?.phase = .running
            if let index = errands[id]?.steps.firstIndex(where: { $0.state == .waiting }) {
                setStep(id, index, .active)
            }
            runTask = Task { await advance(id) { try await $0.wake(id, with: .answer(text)) } }
            return
        }
        if text.lowercased().contains("cancel"), activeErrandID == nil {
            messages.append(ChatMessage(author: .owner, text: text))
            if runner != nil { startAgentErrand() } else { startDemoErrand() }
            return
        }
        let message = ChatMessage(author: .owner, text: text, status: .sending)
        messages.append(message)
        Task { await deliver(message.id, text: text) }
    }

    func runDemoFromMenu() {
        guard activeErrandID == nil else { return }
        messages.append(ChatMessage(author: .owner, text: "Cancel my gym membership."))
        startDemoErrand()
    }

    func retry(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].status = .sending
        let text = messages[index].text
        Task { await deliver(id, text: text) }
    }

    func startNewConversation() {
        runTask?.cancel()
        messages = []
        errands = [:]
        activeErrandID = nil
        questionCaseID = nil
        showsDone = false
        showsSampleLabel = false
        isStewardWorking = false
    }

    // MARK: Errand actions

    func approve(_ id: UUID) {
        guard errands[id]?.approval == .pending else { return }
        errands[id]?.approval = .approved
        errands[id]?.phase = .running
        if let file = runner?.cases[id], case .needsApproval(_, let draft) = file.state {
            let body = errands[id]?.messageBody
            let edited = body == draft.body ? nil : body
            setStage(id, 1, .active)
            runTask = Task { await advance(id) { try await $0.wake(id, with: .approval(approved: true, editedBody: edited)) } }
            return
        }
        setStep(id, 3, .active)
        runTask = Task { await finishAfterApproval(id) }
    }

    func decline(_ id: UUID) {
        guard errands[id]?.approval == .pending else { return }
        if runner?.cases[id] != nil {
            // The agent hears the no and decides what's next; usually it closes.
            errands[id]?.approval = .declined
            errands[id]?.phase = .running
            setStage(id, 1, .active)
            runTask = Task { await advance(id) { try await $0.wake(id, with: .approval(approved: false, reason: "The owner declined this draft.")) } }
            return
        }
        close(id)
        say("Okay, nothing was sent. Your membership stays as it is.")
    }

    func stopActiveErrand() {
        guard let id = activeErrandID else { return }
        runTask?.cancel()
        if questionCaseID == id { questionCaseID = nil }
        close(id)
        say("Stopped. Nothing was sent.")
    }

    func updateMessageBody(_ body: String, for id: UUID) {
        errands[id]?.messageBody = body
    }

    private func close(_ id: UUID) {
        if errands[id]?.approval == .pending { errands[id]?.approval = .declined }
        errands[id]?.phase = .stopped
        if let steps = errands[id]?.steps {
            for index in steps.indices where steps[index].state != .done {
                errands[id]?.steps[index].state = .pending
            }
        }
        activeErrandID = nil
    }

    // MARK: Agent run

    private func startAgentErrand() {
        guard let runner else { return }
        let file = SimulatedErrand.gymCancellation()
        do {
            try runner.open(file)
        } catch {
            say("I couldn't save this errand on your phone, so I haven't started it.")
            return
        }
        let errand = Errand.agentErrand(id: file.id, title: SimulatedErrand.title, label: runner.isSimulated ? "Simulated" : nil)
        errands[errand.id] = errand
        activeErrandID = errand.id
        showsDone = false
        setStage(file.id, 0, .active)
        say("On it. I'll write to \(file.company.name) and show you the email before anything goes out.", attachment: .progress(file.id))
        runTask = Task { await advance(file.id) { try await $0.wake(file.id, with: .start) } }
    }

    /// Wakes the agent through `work`, then shows where the case now stands.
    private func advance(_ id: UUID, _ work: (CaseRunner) async throws -> CaseFile?) async {
        guard let runner, let before = runner.cases[id] else { return }
        isStewardWorking = true
        do {
            let file = try await work(runner)
            isStewardWorking = false
            guard !Task.isCancelled, let file else { return }
            show(file, newEvents: file.events.dropFirst(before.events.count))
        } catch {
            isStewardWorking = false
            guard !Task.isCancelled else { return }
            close(id)
            say("I couldn't finish that step, so I've paused this errand. Nothing more goes out without your OK.")
        }
    }

    private func show(_ file: CaseFile, newEvents: ArraySlice<CaseFile.Event>) {
        let id = file.id
        if newEvents.contains(where: { $0.kind == "email_in" }) {
            say("\(file.company.name) replied. Reading it now.")
        }
        switch file.state {
        case .new:
            break
        case .needsApproval(_, let draft):
            errands[id]?.recipient = draft.to
            errands[id]?.subject = draft.subject
            errands[id]?.messageBody = draft.body
            errands[id]?.approval = .pending
            errands[id]?.phase = .needsYou
            setStage(id, 1, .waiting)
            say("Here's exactly what I'll send. Nothing goes until you say yes.", attachment: .approval(id))
        case .needsAnswer(_, let question):
            errands[id]?.phase = .needsYou
            if let index = errands[id]?.steps.firstIndex(where: { $0.state == .active }) {
                setStep(id, index, .waiting)
            }
            questionCaseID = id
            say(question)
        case .waitingForReply(_, let until):
            errands[id]?.phase = .running
            setStage(id, 2, .active)
            if newEvents.contains(where: { $0.kind == "email_out" }) {
                say("Sent to \(file.company.name). I'll watch for their reply and pick it up as soon as it lands.")
            } else {
                say("I'm waiting for \(file.company.name) to reply, until \(until.formatted(.dateTime.month(.wide).day())) at the latest.")
            }
            if runner?.isSimulated == true {
                runTask = Task { await collectSimulatedReply(id) }
            }
        case .closed:
            finish(file)
        }
    }

    private func finish(_ file: CaseFile) {
        let id = file.id
        guard let closure = file.closure, closure.status == .done else {
            close(id)
            say(file.closure?.summary ?? "I've stopped this errand.")
            return
        }
        setStage(id, errands[id]?.steps.count ?? 0, .done)
        errands[id]?.phase = .finished
        activeErrandID = nil
        showsDone = true
        say("Done. \(closure.summary)")
        if !closure.evidence.isEmpty {
            say("In their words: \u{201C}\(closure.evidence)\u{201D}")
        }
        runTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { showsDone = false }
        }
    }

    /// Simulated relay only: the company's reply arrives a moment after sending.
    private func collectSimulatedReply(_ id: UUID) async {
        do { try await Task.sleep(for: pace * 2) } catch { return }
        setStage(id, 3, .active)
        await advance(id) { try await $0.collectMail(for: id) }
        if runner?.cases[id]?.inbox.isEmpty == true, case .waitingForReply = runner?.cases[id]?.state {
            setStage(id, 2, .active)
        }
    }

    /// Marks steps before `index` done, `index` as `state`, and the rest not started.
    private func setStage(_ id: UUID, _ index: Int, _ state: Errand.StepState) {
        guard let count = errands[id]?.steps.count else { return }
        for step in 0..<count {
            setStep(id, step, step < index ? .done : step == index ? state : .pending)
        }
    }

    // MARK: Scripted run

    private func startDemoErrand() {
        let errand = Errand.demoGymCancellation()
        errands[errand.id] = errand
        activeErrandID = errand.id
        showsDone = false
        runTask = Task { await runUntilApproval(errand.id) }
    }

    private func runUntilApproval(_ id: UUID) async {
        do {
            setStep(id, 0, .active)
            say("On it. I'll check your notice period first, so you don't pay for another month.", attachment: .progress(id))
            try await Task.sleep(for: pace)
            setStep(id, 0, .done)
            setStep(id, 1, .active)
            try await Task.sleep(for: pace)
            setStep(id, 1, .done)
            setStep(id, 2, .active)
            say("You have 6 days. After that you pay for one more month.", attachment: .deadline(Self.demoDeadline()))
            try await Task.sleep(for: pace)
            setStep(id, 2, .done)
            setStep(id, 3, .waiting)
            errands[id]?.phase = .needsYou
            errands[id]?.approval = .pending
            say("Here's exactly what I'll send. Nothing goes until you say yes.", attachment: .approval(id))
        } catch {}
    }

    private func finishAfterApproval(_ id: UUID) async {
        do {
            try await Task.sleep(for: pace)
            setStep(id, 3, .done)
            setStep(id, 4, .active)
            try await Task.sleep(for: pace)
            setStep(id, 4, .done)
            errands[id]?.phase = .finished
            activeErrandID = nil
            showsDone = true
            say("Done. Your cancellation went through, and you won't be charged again.")
            try await Task.sleep(for: .seconds(3))
            showsDone = false
        } catch {}
    }

    private func setStep(_ id: UUID, _ index: Int, _ state: Errand.StepState) {
        errands[id]?.steps[index].state = state
    }

    private func say(_ text: String, attachment: ChatMessage.Attachment? = nil) {
        messages.append(ChatMessage(author: .steward, text: text, attachment: attachment))
    }

    private static func demoDeadline() -> DeadlineInfo {
        let calendar = Calendar.current
        return DeadlineInfo(
            daysLeft: 6,
            elapsedFraction: 0.8,
            lastDay: calendar.date(byAdding: .day, value: 6, to: .now) ?? .now,
            nextPayment: calendar.date(byAdding: .day, value: 7, to: .now) ?? .now,
            amount: "$39"
        )
    }

    private func deliver(_ id: UUID, text: String) async {
        isStewardWorking = true
        defer { isStewardWorking = false }
        do {
            let reply = try await service.reply(to: text)
            setStatus(.delivered, for: id)
            messages.append(ChatMessage(author: .steward, text: reply))
        } catch {
            setStatus(.failed, for: id)
        }
    }

    private func setStatus(_ status: ChatMessage.Status, for id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].status = status
    }
}

extension ChatModel {
    /// Reads `-uiState empty|failed|long|errand|agent` so each state can be launched and checked directly.
    static func launch() -> ChatModel {
        let state = UserDefaults.standard.string(forKey: "uiState")
        let service = PreviewChatService(fails: state == "failed")
        switch state {
        case "empty":
            return ChatModel(messages: [], showsSampleLabel: false, service: service)
        case "failed":
            let failed = ChatMessage(author: .owner, text: "My email is on the account, go ahead.", status: .failed)
            return ChatModel(messages: sample() + [failed], showsSampleLabel: true, service: service)
        case "long":
            let long = ChatMessage(author: .steward, text: String(repeating: "Your gym's terms ask for thirty days' written notice, and the next payment leaves on the fourteenth. ", count: 6))
            return ChatModel(messages: sample() + [long], showsSampleLabel: true, service: service)
        case "agent":
            // A real agent run on a sample case, with simulated mail and company.
            let model = ChatModel(messages: [], showsSampleLabel: false, service: service, runner: .simulated())
            model.send("Cancel my gym membership.")
            return model
        case "errand":
            let model = ChatModel(messages: [], showsSampleLabel: false, service: service)
            model.runDemoFromMenu()
            return model
        default:
            return ChatModel(messages: sample(), showsSampleLabel: true, service: service)
        }
    }

    private static func sample() -> [ChatMessage] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let nineToday = calendar.date(bySettingHour: 9, minute: 2, second: 0, of: today) ?? today
        let evening = calendar.date(byAdding: .minute, value: -319, to: today) ?? today
        return [
            ChatMessage(author: .owner, text: "Can you cancel my gym membership? They just put it up again.", date: evening),
            ChatMessage(author: .steward, text: "Yes. I'll check the notice period first, so you aren't charged for another month.", date: evening),
            ChatMessage(author: .steward, text: "Nothing gets sent until you've read it and said yes.", date: evening),
            ChatMessage(author: .owner, text: "Ok, what do you need from me?", date: nineToday),
            ChatMessage(author: .steward, text: "Just your membership email. I'll do the rest.", date: nineToday),
        ]
    }
}
