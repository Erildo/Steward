import Foundation
import StewardCore

/// Runs real errands for the chat: owns their case files, wakes the agent, and
/// saves the case after every wake, so the app can be suspended at any wait.
///
/// It only moves cases forward; how a case looks in chat is `ChatModel`'s job.
@MainActor
final class CaseRunner {
    struct UnknownCase: Error {}

    private(set) var cases: [UUID: CaseFile] = [:]
    private let agent: Agent
    private let store: CaseStore
    /// Stands in for the relay until it exists. `nil` once real mail is wired.
    private let mailbox: SimulatedMailbox?

    /// True while nothing really leaves the phone.
    var isSimulated: Bool { mailbox != nil }

    init(agent: Agent, store: CaseStore = CaseService.store, mailbox: SimulatedMailbox?) {
        self.agent = agent
        self.store = store
        self.mailbox = mailbox
    }

    func open(_ file: CaseFile) throws {
        cases[file.id] = file
        try store.save(file)
    }

    func wake(_ id: UUID, with wake: Wake) async throws -> CaseFile {
        guard let file = cases[id] else { throw UnknownCase() }
        let next: CaseFile
        do {
            next = try await agent.wake(file, with: wake)
        } catch let failed as Agent.WakeFailed {
            // Keep what already happened (a sent email above all), then report.
            cases[id] = failed.file
            try store.save(failed.file)
            throw failed.underlying
        }
        cases[id] = next
        try store.save(next)
        return next
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
