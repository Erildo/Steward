import Foundation
import Observation

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

    init(messages: [ChatMessage], showsSampleLabel: Bool, service: ChatService) {
        self.messages = messages
        self.showsSampleLabel = showsSampleLabel
        self.service = service
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
        if text.lowercased().contains("cancel"), activeErrandID == nil {
            messages.append(ChatMessage(author: .owner, text: text))
            startDemoErrand()
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
        showsDone = false
        showsSampleLabel = false
        isStewardWorking = false
    }

    // MARK: Errand actions

    func approve(_ id: UUID) {
        guard errands[id]?.approval == .pending else { return }
        errands[id]?.approval = .approved
        errands[id]?.phase = .running
        setStep(id, 3, .active)
        runTask = Task { await finishAfterApproval(id) }
    }

    func decline(_ id: UUID) {
        guard errands[id]?.approval == .pending else { return }
        close(id)
        say("Okay, nothing was sent. Your membership stays as it is.")
    }

    func stopActiveErrand() {
        guard let id = activeErrandID else { return }
        runTask?.cancel()
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
    /// Reads `-uiState empty|failed|long|errand` so each state can be launched and checked directly.
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
