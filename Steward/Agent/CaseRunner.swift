import Foundation
import StewardCore

/// Runs real errands for the chat: owns their case files, wakes the agent, and
/// saves the case after every wake, so the app can be suspended at any wait.
///
/// It only moves cases forward; how a case looks in chat is `ChatModel`'s job.
@MainActor
final class CaseRunner {
    struct UnknownCase: Error {}

    /// Which screen the owner acted from, so each screen can catch up on
    /// wakes it didn't start itself.
    enum Origin { case chat, tasks }

    /// Called after every wake that changed the case, including a failed one
    /// that kept what already happened: the case before, after, and who woke it.
    typealias Observer = (_ before: CaseFile, _ after: CaseFile, _ origin: Origin) -> Void
    private var observers: [Observer] = []

    private(set) var cases: [UUID: CaseFile] = [:]
    private let agent: Agent
    private let store: CaseStore
    /// Stands in for the relay until it exists. `nil` once real mail is wired.
    private let mailbox: SimulatedMailbox?
    private let queue = WakeQueue()

    /// True while nothing really leaves the phone.
    var isSimulated: Bool { mailbox != nil }

    init(agent: Agent, store: CaseStore = CaseService.store, mailbox: SimulatedMailbox?) {
        self.agent = agent
        self.store = store
        self.mailbox = mailbox
    }

    func observe(_ observer: @escaping Observer) {
        observers.append(observer)
    }

    func open(_ file: CaseFile) throws {
        cases[file.id] = file
        try store.save(file)
    }

    /// Wakes the case, one wake at a time: a wake that arrives while another is
    /// running waits for it, then starts from the case as that one saved it.
    func wake(_ id: UUID, with wake: Wake, from origin: Origin = .chat) async throws -> CaseFile {
        try await queue.run(id) { @MainActor in try await self.wakeNow(id, with: wake, from: origin) }
    }

    private func wakeNow(_ id: UUID, with wake: Wake, from origin: Origin) async throws -> CaseFile {
        // A case from an earlier launch is read back from the owner's files.
        let file: CaseFile
        if let known = cases[id] {
            file = known
        } else {
            do { file = try store.load(id) } catch { throw UnknownCase() }
        }
        let next: CaseFile
        do {
            next = try await agent.wake(file, with: wake)
        } catch let failed as Agent.WakeFailed {
            // Keep what already happened (a sent email above all), then report.
            cases[id] = failed.file
            try store.save(failed.file)
            notify(file, failed.file, origin)
            throw failed.underlying
        }
        cases[id] = next
        try store.save(next)
        notify(file, next, origin)
        return next
    }

    /// A move the owner makes without the agent (take over, stop, mark done).
    /// It waits its turn behind any running wake, so a wake that was sending
    /// finishes first and the owner's move lands on the case as it left it.
    func update(_ id: UUID, from origin: Origin = .tasks, _ change: @escaping @MainActor (inout CaseFile) -> Void) async throws -> CaseFile {
        try await queue.run(id) { @MainActor in
            let file: CaseFile
            if let known = self.cases[id] {
                file = known
            } else {
                do { file = try self.store.load(id) } catch { throw UnknownCase() }
            }
            var next = file
            change(&next)
            self.cases[id] = next
            try self.store.save(next)
            self.notify(file, next, origin)
            return next
        }
    }

    private func notify(_ before: CaseFile, _ after: CaseFile, _ origin: Origin) {
        guard before != after else { return }
        for observer in observers { observer(before, after, origin) }
    }

    /// Hands the agent any mail that has arrived for the case. Returns `nil` when
    /// there was none. With the relay this is driven by a silent push.
    func collectMail(for id: UUID) async throws -> CaseFile? {
        guard let mailbox else { return nil }
        let replies = await mailbox.takeReplies(for: id)
        guard !replies.isEmpty else { return nil }
        return try await wake(id, with: .mail(replies))
    }
}

extension CaseRunner {
    /// The debug path (`-uiState agent`): simulated mail and company, and the
    /// scripted model unless a model key is given for this run.
    static func simulated() -> CaseRunner {
        let mailbox = SimulatedMailbox(reply: SimulatedErrand.companyReply)
        return CaseRunner(agent: Agent(model: debugModel() ?? SimulatedErrand.model(), mail: mailbox), mailbox: mailbox)
    }

    /// The Tasks sample (`-uiState tasks`): simulated mail that no company
    /// answers, and a sample model that reacts to what the owner just did.
    static func tasksSample(store: CaseStore) -> CaseRunner {
        let mailbox = SimulatedMailbox(reply: { _ in nil })
        return CaseRunner(agent: Agent(model: TasksSampleModel(), mail: mailbox), store: store, mailbox: mailbox)
    }

    /// A real model for debug runs only. The key comes from the launch
    /// environment (`STEWARD_MODEL_KEY`), never from the source or the repo.
    /// Optional launch arguments: `-agentModel <name>` (required to use it) and
    /// `-agentBaseURL <url>` (OpenRouter by default).
    private static func debugModel() -> (any ModelClient)? {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let key = ProcessInfo.processInfo.environment["STEWARD_MODEL_KEY"], !key.isEmpty,
              let name = defaults.string(forKey: "agentModel"), !name.isEmpty,
              let base = URL(string: defaults.string(forKey: "agentBaseURL") ?? "https://openrouter.ai/api/v1")
        else { return nil }
        return OpenAICompatibleClient(baseURL: base, model: name, apiKey: key)
        #else
        return nil
        #endif
    }
}
