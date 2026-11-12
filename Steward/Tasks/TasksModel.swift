import Foundation
import Observation
import StewardCore

/// One row in Tasks: a to-do the owner keeps, or an errand Steward runs.
enum TaskItem: Identifiable {
    case own(OwnerTask)
    /// Anything handed to Steward, with its own conversation.
    case steward(StewardTask)
    /// A company errand Steward runs by email, with proof of the outcome.
    case errand(CaseFile)

    var id: UUID {
        switch self {
        case .own(let task): task.id
        case .steward(let task): task.id
        case .errand(let file): file.id
        }
    }

    var title: String {
        switch self {
        case .own(let task): task.title
        case .steward(let task): task.goal
        case .errand(let file): file.title
        }
    }

    var isErrand: Bool {
        if case .errand = self { return true }
        return false
    }
}

/// Which list Tasks shows: the owner's own to-dos, or what they handed to Steward.
enum TaskScope: String, CaseIterable, Identifiable {
    case mine, steward

    var id: Self { self }

    var title: String {
        switch self {
        case .mine: "Mine"
        case .steward: "Steward"
        }
    }

    func contains(_ item: TaskItem) -> Bool {
        if case .own = item { return self == .mine }
        return self == .steward
    }
}

/// The Tasks tab: the owner's own to-dos and Steward's errands, grouped by
/// who acts next. Errands move forward through the runner; the owner's own
/// moves on them (take over, stop, mark done) are logged in the case.
@Observable
final class TasksModel {
    private(set) var cases: [CaseFile] = []
    private(set) var ownTasks: [OwnerTask] = []
    private(set) var stewardTasks: [StewardTask] = []
    private(set) var couldNotRead = false
    /// True when the tab shows sample errands, so the view can say so.
    let isSample: Bool

    /// Cases Steward is acting on right now, after the owner's tap.
    private(set) var working: Set<UUID> = []
    /// The last action that didn't go through, per case, in plain words.
    private(set) var problems: [UUID: String] = [:]

    /// The last move, offered back for a few seconds.
    struct Undo: Identifiable {
        let id = UUID()
        let message: String
        let restore: () -> Void
    }
    private(set) var undo: Undo?

    /// Narrows every section, from the search field.
    var query = ""

    /// Finished tasks stay in Done this long, then move to the archive.
    static let doneWindow: TimeInterval = 30 * 86_400

    private let store: CaseStore
    private let taskStore: OwnerTaskStore
    private let stewardStore: JSONListStore<StewardTask>
    /// Works on general tasks. `nil` while no model is connected.
    private let agent: (any TaskAgent)?
    /// Moves cases forward. `nil` while nothing is connected, so the owner's
    /// buttons are shown but can't act.
    private let runner: CaseRunner?

    var canAct: Bool { runner != nil }
    /// Whether Steward can work on general tasks right now.
    var canWork: Bool { agent != nil }

    init(store: CaseStore, taskStore: OwnerTaskStore, stewardStore: JSONListStore<StewardTask>,
         runner: CaseRunner?, agent: (any TaskAgent)?, isSample: Bool) {
        self.store = store
        self.taskStore = taskStore
        self.stewardStore = stewardStore
        self.agent = agent
        self.runner = runner
        self.isSample = isSample
        // Chat moves cases too; show its wakes here as they land.
        runner?.observe { [weak self] _, _, _ in self?.reloadCases() }
    }

    // MARK: Sections

    /// Steward is waiting on the owner: a draft to approve or a question.
    var needsYou: [TaskItem] {
        let errands = listedCases.filter { TaskStatus(of: $0) == .needsYou }.map(TaskItem.errand)
        let tasks = stewardTasks.filter { TaskStatus(of: $0) == .needsYou }.map(TaskItem.steward)
        return (errands + tasks).sorted { lastActivity($0) > lastActivity($1) }.filter(matches)
    }

    /// Cases a Steward task carries show inside that task, not on their own.
    private var listedCases: [CaseFile] {
        let carried = Set(stewardTasks.compactMap(\.caseID))
        return cases.filter { !carried.contains($0.id) }
    }

    /// The owner's own open to-dos, dated ones first, soonest first.
    var mine: [TaskItem] {
        ownTasks.filter { !$0.isDone }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): x < y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.createdAt > b.createdAt
                }
            }
            .map(TaskItem.own)
            .filter(matches)
    }

    /// Steward's errands and tasks that came back to the owner to finish.
    var handedBack: [TaskItem] {
        (listedCases.filter { TaskStatus(of: $0) == .yours }.map(TaskItem.errand)
            + stewardTasks.filter { TaskStatus(of: $0) == .yours }.map(TaskItem.steward))
            .sorted { lastActivity($0) > lastActivity($1) }
            .filter(matches)
    }

    /// Everything in a scope that matches the search, across sections.
    func matchCount(in scope: TaskScope) -> Int {
        switch scope {
        case .mine: mine.count + done.filter(scope.contains).count
        case .steward: needsYou.count + handedBack.count + stewards.count + done.filter(scope.contains).count
        }
    }

    /// Whether a scope holds anything at all, search aside.
    func hasItems(in scope: TaskScope) -> Bool {
        switch scope {
        case .mine: !ownTasks.isEmpty
        case .steward: !listedCases.isEmpty || !stewardTasks.isEmpty
        }
    }

    /// Errands Steward is working on or waiting on the company for, soonest wake first.
    var stewards: [TaskItem] {
        let errands = listedCases.filter { TaskStatus(of: $0) == .onIt }.map(TaskItem.errand)
        let tasks = stewardTasks.filter { TaskStatus(of: $0) == .onIt }.map(TaskItem.steward)
        return (tasks + errands).sorted { nextWake($0) < nextWake($1) }.filter(matches)
    }

    /// Finished in the last 30 days, most recent first.
    var done: [TaskItem] { finished.filter { finishDate($0) >= .now.addingTimeInterval(-Self.doneWindow) } }

    /// Finished longer ago.
    var archived: [TaskItem] { finished.filter { finishDate($0) < .now.addingTimeInterval(-Self.doneWindow) } }

    private var finished: [TaskItem] {
        let own = ownTasks.filter(\.isDone).map(TaskItem.own)
        let errands = listedCases.filter {
            let status = TaskStatus(of: $0)
            return status == .done || status == .stopped
        }.map(TaskItem.errand)
        let tasks = stewardTasks.filter(\.isFinished).map(TaskItem.steward)
        return (own + errands + tasks).sorted { finishDate($0) > finishDate($1) }.filter(matches)
    }

    var openCount: Int {
        ownTasks.filter { !$0.isDone }.count
            + listedCases.filter { [.needsYou, .yours, .onIt].contains(TaskStatus(of: $0)) }.count
            + stewardTasks.filter { !$0.isFinished }.count
    }

    var totalCount: Int { ownTasks.count + listedCases.count + stewardTasks.count }

    /// Unfiltered, for the tab badge.
    var needsYouCount: Int {
        listedCases.filter { TaskStatus(of: $0) == .needsYou }.count
            + stewardTasks.filter { TaskStatus(of: $0) == .needsYou }.count
    }

    var isEmpty: Bool { cases.isEmpty && ownTasks.isEmpty && stewardTasks.isEmpty }

    func file(_ id: UUID) -> CaseFile? { cases.first { $0.id == id } }
    func task(_ id: UUID) -> OwnerTask? { ownTasks.first { $0.id == id } }
    func stewardTask(_ id: UUID) -> StewardTask? { stewardTasks.first { $0.id == id } }

    /// An open task or errand with the same name, so adding twice can be caught.
    func existing(named title: String) -> TaskItem? {
        let key = Self.normalized(title)
        guard !key.isEmpty else { return nil }
        if let task = ownTasks.first(where: { !$0.isDone && Self.normalized($0.title) == key }) { return .own(task) }
        if let task = stewardTasks.first(where: { !$0.isFinished && Self.normalized($0.goal) == key }) { return .steward(task) }
        if let file = cases.first(where: {
            [.needsYou, .yours, .onIt].contains(TaskStatus(of: $0)) && Self.normalized($0.title) == key
        }) { return .errand(file) }
        return nil
    }

    // MARK: The owner's own tasks

    @discardableResult
    func add(_ title: String, due: Date? = nil) -> OwnerTask? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let task = OwnerTask(title: title, due: due)
        ownTasks.append(task)
        saveTasks()
        return task
    }

    func update(_ task: OwnerTask) {
        guard let index = ownTasks.firstIndex(where: { $0.id == task.id }) else { return }
        ownTasks[index] = task
        saveTasks()
    }

    func setDone(_ id: UUID, _ done: Bool) {
        guard var task = task(id), task.isDone != done else { return }
        let before = task
        task.doneAt = done ? .now : nil
        update(task)
        offerUndo(done ? "Marked done" : "Marked not done") { [weak self] in self?.update(before) }
    }

    func delete(_ id: UUID) {
        guard let index = ownTasks.firstIndex(where: { $0.id == id }) else { return }
        let removed = ownTasks.remove(at: index)
        saveTasks()
        offerUndo("Task deleted") { [weak self] in
            guard let self else { return }
            ownTasks.insert(removed, at: min(index, ownTasks.count))
            saveTasks()
        }
    }

    /// Turns the owner's to-do into Steward's, right here: same words, its
    /// own thread, and Steward starts on it.
    func handToSteward(_ id: UUID) {
        guard let index = ownTasks.firstIndex(where: { $0.id == id }) else { return }
        let removed = ownTasks.remove(at: index)
        saveTasks()
        let goal = removed.note.isEmpty ? removed.title : "\(removed.title)\n\(removed.note)"
        guard let created = createStewardTask(goal) else { return }
        offerUndo("Handed to Steward") { [weak self] in
            guard let self else { return }
            stewardTasks.removeAll { $0.id == created.id }
            saveStewardTasks()
            ownTasks.insert(removed, at: min(index, ownTasks.count))
            saveTasks()
        }
    }

    // MARK: Steward's tasks

    /// Hands Steward anything. It shows up at once and Steward starts on it.
    @discardableResult
    func addStewardTask(_ goal: String) -> StewardTask? {
        createStewardTask(goal)
    }

    private func createStewardTask(_ goal: String, wakes: Bool = true) -> StewardTask? {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return nil }
        var task = StewardTask(goal: goal)
        task.say(.owner, goal)
        stewardTasks.append(task)
        saveStewardTasks()
        if wakes { wake(task.id, .start) }
        return task
    }

    /// The owner writes in a task's thread: an answer, or anything else.
    func send(_ id: UUID, _ text: String) {
        guard var task = stewardTask(id), !working.contains(id) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task.say(.owner, text)
        // Writing on a finished or handed-back task picks it back up.
        task.state = .working
        replace(task)
        wake(id, .message)
    }

    /// Wakes the agent, or says plainly that there isn't one yet, so a
    /// conversation never sits on the owner's words with no reply.
    private func wake(_ id: UUID, _ wake: TaskWake) {
        guard agent != nil else {
            guard var task = stewardTask(id), task.messages.last?.author == .owner else { return }
            task.say(.steward, "I'm not connected to an AI model yet, so I can't work on this. It's saved here, and I'll pick it up once I'm connected.",
                     blocks: [.choices(.init(options: [Self.demoChoice]))])
            replace(task)
            return
        }
        work(id, wake)
    }

    /// The answer that starts the demo errand while nothing is connected.
    static let demoChoice = "Show me a demo errand"

    // MARK: Conversations

    /// Every conversation with Steward for Chats: pinned first, then the
    /// most recent. The same threads Tasks groups by who acts next.
    var conversations: [StewardTask] {
        stewardTasks.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Starts a conversation from the owner's first words. `wakes` is false
    /// when Chat runs it itself (an errand), so the agent stays out of it.
    @discardableResult
    func startConversation(_ text: String, wakes: Bool = true) -> UUID? {
        createStewardTask(text, wakes: wakes)?.id
    }

    /// Adds a message without waking the agent. Returns its id.
    @discardableResult
    func post(_ id: UUID, _ author: StewardTask.Message.Author, _ text: String, blocks: [ReplyBlock] = []) -> UUID? {
        guard var task = stewardTask(id) else { return nil }
        let messageID = task.say(author, text, blocks: blocks)
        replace(task)
        return messageID
    }

    /// Changes one message in place, such as a draft that was approved.
    func editMessage(_ id: UUID, _ messageID: UUID, _ edit: (inout StewardTask.Message) -> Void) {
        guard var task = stewardTask(id), let index = task.messages.firstIndex(where: { $0.id == messageID }) else { return }
        edit(&task.messages[index])
        replace(task)
    }

    /// Changes one block of a message in place.
    func editBlock(_ id: UUID, _ messageID: UUID, at index: Int, _ edit: (inout ReplyBlock) -> Void) {
        editMessage(id, messageID) { message in
            guard var blocks = message.blocks, blocks.indices.contains(index) else { return }
            edit(&blocks[index])
            message.blocks = blocks
        }
    }

    func setState(_ id: UUID, _ state: StewardTask.State, result: String? = nil) {
        guard var task = stewardTask(id) else { return }
        task.state = state
        if let result { task.result = result }
        replace(task)
    }

    func setCase(_ id: UUID, _ caseID: UUID) {
        guard var task = stewardTask(id) else { return }
        task.caseID = caseID
        replace(task)
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard var task = stewardTask(id) else { return }
        task.pinned = pinned ? true : nil
        replace(task)
    }

    /// The conversation that carries a case, if one does.
    func conversation(carrying caseID: UUID) -> StewardTask? {
        stewardTasks.first { $0.caseID == caseID }
    }

    /// Tasks left mid-step when the app last closed: pick them up again.
    func resumeStalled() {
        for task in stewardTasks where task.state == .working && !working.contains(task.id) {
            work(task.id, task.messages.last?.author == .owner && task.messages.count > 1 ? .message : .start)
        }
    }

    /// Picks a waiting task back up when its date has passed.
    func checkBack(_ id: UUID) {
        guard let task = stewardTask(id), task.isOverdue else { return }
        work(id, .timer)
    }

    private func work(_ id: UUID, _ wake: TaskWake) {
        guard let agent, let task = stewardTask(id), !working.contains(id) else { return }
        working.insert(id)
        problems[id] = nil
        Task {
            do {
                let next = try await agent.work(on: task, wake: wake)
                // Keep anything the owner did meanwhile (stop, take over).
                if let current = stewardTask(id), current.state == task.state || current.state == .working {
                    replace(next)
                }
            } catch {
                problems[id] = "Steward couldn't get through this step. Write again to retry."
            }
            working.remove(id)
        }
    }

    private func editStewardTask(_ id: UUID, undo message: String, _ edit: (inout StewardTask) -> Void) {
        guard let before = stewardTask(id) else { return }
        var task = before
        edit(&task)
        replace(task)
        offerUndo(message) { [weak self] in self?.replace(before) }
    }

    func takeOverTask(_ id: UUID) {
        editStewardTask(id, undo: "You took this over") { task in
            task.state = .handedBack(note: "You took this over", date: .now)
        }
    }

    func stopTask(_ id: UUID) {
        editStewardTask(id, undo: "Task stopped") { $0.state = .stopped(date: .now) }
    }

    func markTaskDone(_ id: UUID) {
        editStewardTask(id, undo: "Marked done") { $0.state = .done(date: .now, confirmedByOwner: true) }
    }

    func deleteStewardTask(_ id: UUID) {
        guard let index = stewardTasks.firstIndex(where: { $0.id == id }) else { return }
        let removed = stewardTasks.remove(at: index)
        saveStewardTasks()
        offerUndo("Task deleted") { [weak self] in
            guard let self else { return }
            stewardTasks.insert(removed, at: min(index, stewardTasks.count))
            saveStewardTasks()
        }
    }

    private func replace(_ task: StewardTask) {
        if let index = stewardTasks.firstIndex(where: { $0.id == task.id }) {
            stewardTasks[index] = task
        } else {
            stewardTasks.append(task)
        }
        saveStewardTasks()
    }

    private func saveStewardTasks() {
        try? stewardStore.save(stewardTasks)
    }

    // MARK: The owner's moves on errands

    func approve(_ id: UUID, editedBody: String? = nil) {
        guard case .needsApproval(let callID, _) = file(id)?.state else { return }
        act(id, .approval(callID: callID, approved: true, editedBody: editedBody))
    }

    func decline(_ id: UUID) {
        guard case .needsApproval(let callID, _) = file(id)?.state else { return }
        act(id, .approval(callID: callID, approved: false, reason: "The owner declined this draft."))
    }

    func answer(_ id: UUID, _ text: String) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, case .needsAnswer = file(id)?.state else { return }
        act(id, .answer(answer))
    }

    /// A follow-up date passed while the phone couldn't wake the case.
    func nudge(_ id: UUID) {
        guard let file = file(id), file.isOverdue else { return }
        act(id, .timer)
    }

    /// The owner does the rest themself. Steward sends nothing more.
    func takeOver(_ id: UUID) {
        change(id, undo: "You took this over") { file in
            file.state = .closed
            file.closure = .init(status: .needsOwner, summary: "You took this over. Steward won't send anything more.", evidence: "", date: .now)
            file.events.append(.init(date: .now, kind: "owner_took_over", detail: "You took this over. Steward won't send anything more."))
        }
    }

    /// Ends the errand unfinished. Steward sends nothing more.
    func stop(_ id: UUID) {
        change(id, undo: "Errand stopped") { file in
            file.state = .closed
            file.closure = .init(status: .failed, summary: "You stopped this errand.", evidence: "", date: .now)
            file.events.append(.init(date: .now, kind: "owner_stopped", detail: "You stopped this errand."))
        }
    }

    /// The owner says it's sorted. Their word counts for more than the
    /// company's, so it's logged even when the company already confirmed.
    func markDone(_ id: UUID) {
        guard let current = file(id), !current.isConfirmedByOwner else { return }
        change(id, undo: "Marked done") { file in
            if file.closure?.status != .done {
                file.state = .closed
                file.closure = .init(status: .done, summary: "You marked this done.", evidence: "", date: .now)
            }
            file.events.append(.init(date: .now, kind: "owner_confirmed", detail: "You confirmed it's sorted."))
        }
    }

    private func change(_ id: UUID, undo message: String, _ edit: @escaping @MainActor (inout CaseFile) -> Void) {
        guard let before = file(id), !working.contains(id) else { return }
        Task { @MainActor in
            do {
                try await write(id, edit)
                offerUndo(message) { [weak self] in
                    Task { @MainActor in try? await self?.write(id) { $0 = before } }
                }
            } catch {
                problems[id] = "That didn't save. Try again."
            }
        }
    }

    private func write(_ id: UUID, _ edit: @escaping @MainActor (inout CaseFile) -> Void) async throws {
        if let runner {
            _ = try await runner.update(id, from: .tasks, edit)
        } else {
            var file = try store.load(id)
            edit(&file)
            try store.save(file)
        }
        reloadCases()
    }

    private func act(_ id: UUID, _ wake: Wake) {
        guard let runner, !working.contains(id) else { return }
        working.insert(id)
        problems[id] = nil
        Task {
            do {
                _ = try await runner.wake(id, with: wake, from: .tasks)
            } catch {
                problems[id] = "Steward couldn't finish that step, so it paused here. Nothing more goes out without your OK."
            }
            working.remove(id)
            reloadCases()
        }
    }

    // MARK: Undo

    private func offerUndo(_ message: String, _ restore: @escaping () -> Void) {
        undo = Undo(message: message, restore: restore)
    }

    func performUndo() {
        undo?.restore()
        undo = nil
    }

    func dismissUndo(_ id: UUID) {
        if undo?.id == id { undo = nil }
    }

    // MARK: Reading

    func reload() {
        reloadCases()
        do {
            ownTasks = try taskStore.all()
            stewardTasks = try stewardStore.all()
        } catch {
            couldNotRead = true
        }
    }

    private func reloadCases() {
        do {
            cases = try store.all()
            couldNotRead = false
        } catch {
            couldNotRead = true
        }
    }

    private func saveTasks() {
        try? taskStore.save(ownTasks)
    }

    private func matches(_ item: TaskItem) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        switch item {
        case .own(let task):
            return task.title.localizedStandardContains(query) || task.note.localizedStandardContains(query)
        case .steward(let task):
            return task.goal.localizedStandardContains(query) || (task.result ?? "").localizedStandardContains(query)
        case .errand(let file):
            return file.title.localizedStandardContains(query) || file.company.name.localizedStandardContains(query)
        }
    }

    private func finishDate(_ item: TaskItem) -> Date {
        switch item {
        case .own(let task): task.doneAt ?? task.createdAt
        case .steward(let task): task.finishedAt ?? task.createdAt
        case .errand(let file): file.closure?.date ?? file.createdAt
        }
    }

    private func lastActivity(_ item: TaskItem) -> Date {
        switch item {
        case .own(let task): task.createdAt
        case .steward(let task): task.messages.last?.date ?? task.createdAt
        case .errand(let file): file.events.last?.date ?? file.createdAt
        }
    }

    private func nextWake(_ item: TaskItem) -> Date {
        switch item {
        case .steward(let task):
            if case .waiting(let until, _) = task.state { return until }
        case .errand(let file):
            if case .waitingForReply(_, let until) = file.state { return until }
        case .own:
            break
        }
        return .distantPast
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Who acts next on a case.
enum TaskStatus: Equatable {
    /// Steward waits on the owner: a draft to approve or a question.
    case needsYou
    /// Steward handed it back, or the owner took it over.
    case yours
    case onIt, done, stopped

    init(of file: CaseFile) {
        switch file.state {
        case .needsApproval, .needsAnswer:
            self = .needsYou
        case .new, .waitingForReply:
            self = .onIt
        case .closed:
            switch file.closure?.status {
            case .done: self = .done
            case .needsOwner: self = .yours
            case .failed, nil: self = .stopped
            }
        }
    }

    init(of task: StewardTask) {
        switch task.state {
        case .working, .waiting: self = .onIt
        case .needsAnswer: self = .needsYou
        case .handedBack: self = .yours
        case .done: self = .done
        case .stopped: self = .stopped
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .needsYou: "Needs you"
        case .yours: "Over to you"
        case .onIt: "Steward is on it"
        case .done: "Done"
        case .stopped: "Not finished"
        }
    }
}

extension CaseFile {
    /// The errand as the owner would name it. Cases opened from chat (and the
    /// harness) store only the kind, such as "cancel", so name the company too.
    var title: String {
        let errand = self.errand.trimmingCharacters(in: .whitespaces)
        guard !errand.contains(" ") else { return errand }
        return "\(errand.prefix(1).uppercased())\(errand.dropFirst()) with \(company.name)"
    }

    var isConfirmedByOwner: Bool { events.contains { $0.kind == "owner_confirmed" } }
    var wasTakenOver: Bool { events.last { $0.kind.hasPrefix("owner_") || $0.kind == "closed" }?.kind == "owner_took_over" }
    var wasStoppedByOwner: Bool { events.last { $0.kind.hasPrefix("owner_") || $0.kind == "closed" }?.kind == "owner_stopped" }

    /// Waiting for a follow-up date that has already passed.
    var isOverdue: Bool {
        if case .waitingForReply(_, let until) = state { return until < .now }
        return false
    }

    /// One line on where the case stands, in the owner's terms.
    var statusLine: String {
        switch state {
        case .new:
            return "Getting started"
        case .needsApproval:
            return "Approve the email to \(company.name)"
        case .needsAnswer(_, let question):
            return "Steward asks: \(question)"
        case .waitingForReply(_, let until):
            if until < .now { return "Follow-up with \(company.name) was due \(until.taskDay)" }
            return "Waiting for \(company.name) · follows up \(until.taskDay)"
        case .closed:
            guard let closure else { return "Closed" }
            switch closure.status {
            case .done:
                return isConfirmedByOwner
                    ? "Confirmed by you · \(closure.date.taskDay)"
                    : "Confirmed by \(company.name) · \(closure.date.taskDay)"
            case .needsOwner:
                return wasTakenOver ? "You took this over · \(closure.date.taskDay)" : "Over to you: \(closure.summary)"
            case .failed:
                return wasStoppedByOwner ? "You stopped this · \(closure.date.taskDay)" : "Couldn't finish: \(closure.summary)"
            }
        }
    }
}

extension OwnerTask {
    var isOverdue: Bool {
        guard let due, !isDone else { return false }
        return due < Calendar.current.startOfDay(for: .now)
    }

    /// "Due Fri", "Was due yesterday", or the note; empty when there's nothing.
    var statusLine: String {
        if let doneAt { return "Done \(doneAt.taskDay)" }
        if let due { return isOverdue ? "Was due \(due.taskDay)" : "Due \(due.taskDay)" }
        return note
    }
}

extension Date {
    /// "today", "tomorrow", "Thu" within a week, otherwise "14 Nov".
    var taskDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "today" }
        if calendar.isDateInTomorrow(self) { return "tomorrow" }
        if calendar.isDateInYesterday(self) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: self)).day ?? 0
        if (2...6).contains(days) { return formatted(.dateTime.weekday(.abbreviated)) }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

extension TasksModel {
    /// Launch states, like chat's and feed's: `-uiState tasks` shows sample
    /// tasks and errands and `-uiState tasksEmpty` the first run, both in a
    /// temporary folder (see `CaseService`). Otherwise the tab reads the
    /// owner's real files.
    @MainActor
    static func launch() -> TasksModel {
        let taskStore = OwnerTaskStore(url: CaseService.store.folder
            .deletingLastPathComponent()
            .appending(path: CaseService.usesScratchFiles ? "owner-tasks-\(UUID().uuidString).json" : "OwnerTasks.json"))
        let stewardStore = JSONListStore<StewardTask>(url: taskStore.url.deletingLastPathComponent()
            .appending(path: CaseService.usesScratchFiles ? "steward-tasks-\(UUID().uuidString).json" : "StewardTasks.json"))
        if UserDefaults.standard.string(forKey: "uiState") == "tasks" {
            for file in TasksSample.cases() { try? CaseService.store.save(file) }
            try? taskStore.save(OwnerTask.samples())
            try? stewardStore.save(StewardTask.samples())
        }
        if CaseService.isChatSample {
            try? stewardStore.save(StewardTask.samples() + StewardTask.chatSamples())
        }
        // Sample launches get the scripted stand-in; otherwise a real model
        // when one is set up (debug key for now), or nothing.
        let agent: (any TaskAgent)? = CaseService.isTasksSample || CaseService.isChatSample
            ? SampleTaskAgent()
            : ModelAccess.feedModel().map { ModelTaskAgent(model: $0) }
        let model = TasksModel(store: CaseService.store, taskStore: taskStore, stewardStore: stewardStore,
                               runner: CaseService.runner, agent: agent, isSample: CaseService.isTasksSample)
        model.reload()
        model.resumeStalled()
        return model
    }
}

/// Demo cases for `-uiState tasks`. Companies and people are fictional.
enum TasksSample {
    static func cases(now: Date = .now) -> [CaseFile] {
        func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86_400) }

        var gym = make("Cancel gym membership", "FitWorld Berlin", "fitworld.example", "DE", playbook: "cancel/de-gym", created: day(-1))
        gym.events = [
            .init(date: day(-1), kind: "opened", detail: "Cancel gym membership with FitWorld Berlin"),
            .init(date: day(-0.1), kind: "approval_asked", detail: "Draft to kuendigung@fitworld.example: Cancellation of membership 48213"),
        ]
        gym.state = .needsApproval(callID: "sample-1", draft: .init(
            direction: .outgoing, date: day(-0.1), from: gym.owner.caseAddress, to: "kuendigung@fitworld.example",
            subject: "Cancellation of membership 48213",
            body: "Hello,\n\nI'm cancelling my membership 48213 with notice, as section 7 of your terms allows. Please confirm in writing the date it ends.\n\nThank you,\nAlex Weber"
        ))

        var energy = make("Dispute estimated energy bill", "Stadtwerk Nord", "stadtwerk-nord.example", "DE", playbook: "dispute/de-energy", created: day(-3))
        energy.events = [
            .init(date: day(-3), kind: "opened", detail: "Dispute estimated energy bill with Stadtwerk Nord"),
            .init(date: day(-0.3), kind: "ask_owner", detail: "Do you have a photo of the meter from 1 October?"),
        ]
        energy.state = .needsAnswer(callID: "sample-2", question: "Do you have a photo of the meter from 1 October?")

        var headphones = make("Refund for faulty headphones", "SoundHouse", "soundhouse.example", "UK", playbook: "refund/gb-retail", created: day(-5))
        headphones.events = [
            .init(date: day(-5), kind: "opened", detail: "Refund for faulty headphones with SoundHouse"),
            .init(date: day(-4), kind: "email_out", detail: "Sent to returns@soundhouse.example: Refund under the Consumer Rights Act"),
            .init(date: day(-2), kind: "email_in", detail: "Reply from returns@soundhouse.example: Your return 7731"),
            .init(date: day(-1), kind: "email_out", detail: "Sent to returns@soundhouse.example: Re: Your return 7731"),
            .init(date: day(-1), kind: "waiting", detail: "Waiting for a reply."),
        ]
        headphones.state = .waitingForReply(callID: "sample-3", until: day(2))

        var broadband = make("Complain about broadband outage", "Fibrelink", "fibrelink.example", "UK", playbook: "complain/gb-broadband", created: day(-8))
        broadband.events = [
            .init(date: day(-8), kind: "opened", detail: "Complain about broadband outage with Fibrelink"),
            .init(date: day(-7), kind: "email_out", detail: "Sent to complaints@fibrelink.example: Formal complaint, account FL-2290"),
            .init(date: day(-7), kind: "waiting", detail: "Waiting for a reply."),
        ]
        broadband.state = .waitingForReply(callID: "sample-4", until: day(9))

        var mealkit = make("Cancel meal kit subscription", "Fresh Fork", "freshfork.example", "UK", playbook: "cancel/gb-subscription", created: day(-12))
        mealkit.events = [
            .init(date: day(-12), kind: "opened", detail: "Cancel meal kit subscription with Fresh Fork"),
            .init(date: day(-11), kind: "email_out", detail: "Sent to help@freshfork.example: Please cancel my subscription"),
            .init(date: day(-9), kind: "email_in", detail: "Reply from help@freshfork.example: Your subscription is cancelled"),
            .init(date: day(-9), kind: "closed", detail: "done: Fresh Fork cancelled the subscription. No more boxes or charges."),
        ]
        mealkit.state = .closed
        mealkit.closure = .init(status: .done, summary: "Fresh Fork cancelled the subscription. No more boxes or charges.",
                                evidence: "We can confirm your subscription has been cancelled and no further payments will be taken.", date: day(-9))

        var phone = make("Cancel phone contract", "Telesul", "telesul.example", "BR", playbook: nil, created: day(-20))
        phone.events = [
            .init(date: day(-20), kind: "opened", detail: "Cancel phone contract with Telesul"),
            .init(date: day(-18), kind: "email_in", detail: "Reply from atendimento@telesul.example: Cancellations by phone only"),
            .init(date: day(-18), kind: "closed", detail: "failed: Telesul only cancels by phone, with the account holder."),
        ]
        phone.state = .closed
        phone.closure = .init(status: .failed, summary: "Telesul only cancels by phone, with the account holder.",
                              evidence: "", date: day(-18))

        // Edge cases for the layout: a case just opened, of no known kind.
        var dentist = make("Book a dentist check-up before the end of the year", "Clínica Dental Mar", "clinicamar.example", "ES", playbook: nil, created: day(-0.02))
        dentist.events = [
            .init(date: day(-0.02), kind: "opened", detail: "Book a dentist check-up with Clínica Dental Mar"),
        ]
        dentist.state = .new

        // Opened from chat, which stores only the kind: the title adds the company.
        // Closed, but handed back to the owner.
        var flight = make("refund", "Aerovía Sol", "aeroviasol.example", "ES", playbook: "refund/eu-air", created: day(-15),
                          goal: "Get my money back for flight SL 2214, which Aerovía Sol cancelled.")
        flight.events = [
            .init(date: day(-15), kind: "opened", detail: "Refund with Aerovía Sol"),
            .init(date: day(-14), kind: "email_out", detail: "Sent to reembolsos@aeroviasol.example: Refund for cancelled flight SL 2214"),
            .init(date: day(-6), kind: "email_in", detail: "Reply from reembolsos@aeroviasol.example: Use our claims form"),
            .init(date: day(-6), kind: "closed", detail: "needs_owner: Aerovía Sol only takes refund claims through its own form, signed in as you."),
        ]
        flight.state = .closed
        flight.closure = .init(status: .needsOwner, summary: "Aerovía Sol only takes refund claims through its own form, signed in as you.",
                               evidence: "Refund requests must be submitted through the claims form in your account.", date: day(-6))

        // A long title and company, to check wrapping.
        var licence = make("Dispute the double charge for my annual photo editing software licence renewal", "Northwind Creative Software International", "northwind.example", "UK", playbook: "dispute/gb-card", created: day(-2))
        licence.events = [
            .init(date: day(-2), kind: "opened", detail: "Dispute the double charge with Northwind Creative Software International"),
            .init(date: day(-1), kind: "email_out", detail: "Sent to billing@northwind.example: Duplicate charge on order NW-55120"),
            .init(date: day(-1), kind: "waiting", detail: "Waiting for a reply."),
        ]
        licence.state = .waitingForReply(callID: "sample-7", until: day(1))

        return [gym, energy, headphones, broadband, mealkit, phone, dentist, flight, licence]
    }

    private static func make(_ errand: String, _ company: String, _ domain: String, _ country: String, playbook: String?, created: Date, goal: String? = nil) -> CaseFile {
        CaseFile(
            errand: errand, createdAt: created,
            owner: .init(name: "Alex Weber", caseAddress: "case@steward.example", accountRef: "",
                         facts: "", goal: goal ?? errand),
            company: .init(name: company, domain: domain, email: "help@\(domain)", country: country),
            playbook: playbook
        )
    }
}
