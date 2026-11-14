import Foundation
import OSLog
import StewardCore

/// Relay problems, never content: what failed and why.
private let relayLog = Logger(subsystem: "esh.steward", category: "relay")

/// Runs real errands for the chat: owns their case files, wakes the agent, and
/// saves the case after every wake, so the app can be suspended at any wait.
///
/// It only moves cases forward; how a case looks in chat is `ChatModel`'s job.
@MainActor
final class CaseRunner {
    struct UnknownCase: Error {}

    /// Which screen the owner acted from, so each screen can catch up on
    /// wakes it didn't start itself. `relay`: mail or a due time the app
    /// picked up on its own.
    enum Origin { case chat, tasks, relay }

    /// Called after every wake that changed the case, including a failed one
    /// that kept what already happened: the case before, after, and who woke it.
    typealias Observer = (_ before: CaseFile, _ after: CaseFile, _ origin: Origin) -> Void
    private var observers: [Observer] = []

    private(set) var cases: [UUID: CaseFile] = [:]
    private let agent: Agent
    private let store: CaseStore
    /// Stands in for the relay in debug runs. `nil` when mail is real.
    private let mailbox: SimulatedMailbox?
    /// The real relay: case addresses, sealed mail, sends and wake times.
    private let relay: RelayConnection?
    private let queue = WakeQueue()
    private var refreshing: Task<Void, Never>?

    /// True while nothing really leaves the phone.
    var isSimulated: Bool { mailbox != nil }

    init(agent: Agent, store: CaseStore = CaseService.store, mailbox: SimulatedMailbox?, relay: RelayConnection? = nil) {
        self.agent = agent
        self.store = store
        self.mailbox = mailbox
        self.relay = relay
    }

    func observe(_ observer: @escaping Observer) {
        observers.append(observer)
    }

    /// Saves a new case. With the relay, it first gets the case its own
    /// mailbox, which becomes the address the agent writes from.
    @discardableResult
    func open(_ input: CaseFile) async throws -> CaseFile {
        var file = input
        if let relay, file.relayCaseID == nil {
            let opened = try await relay.client().openCase()
            file.relayCaseID = opened.caseId
            file.owner.caseAddress = opened.address
        }
        cases[file.id] = file
        try store.save(file)
        return file
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
            syncWake(failed.file)
            throw failed.underlying
        }
        cases[id] = next
        try store.save(next)
        notify(file, next, origin)
        syncWake(next)
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
            self.syncWake(next)
            return next
        }
    }

    private func notify(_ before: CaseFile, _ after: CaseFile, _ origin: Origin) {
        guard before != after else { return }
        for observer in observers { observer(before, after, origin) }
    }

    // MARK: Relay

    /// When the relay should show a notification for this case: the follow-up
    /// date while waiting, or the outcome check's day after a done. The relay
    /// learns only the time, never why.
    private func syncWake(_ file: CaseFile) {
        guard let relay, let relayCaseID = file.relayCaseID else { return }
        let at: Date? = switch file.state {
        case .waitingForReply(_, let until): until
        case .closed where file.closure?.status == .done && file.outcomeCheck?.answer == nil && !file.isConfirmedByOwner: file.outcomeCheck?.due
        default: nil
        }
        Task {
            guard let client = try? await relay.client() else { return }
            if let at { try? await client.setWake(relayCaseID, at: at) } else { try? await client.clearWake(relayCaseID) }
        }
    }

    /// Catches up with the world: mail that arrived for any case, and
    /// follow-up times that passed while the app wasn't running. Called on
    /// launch, when the app comes forward, and on a push. Overlapping calls
    /// share one run.
    func refresh() async {
        guard relay != nil else { return }
        if let refreshing { return await refreshing.value }
        relayLog.notice("Refreshing from the relay")
        let task = Task { @MainActor in
            await collectRelayMail()
            await runDueTimers()
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// Opens what the relay holds, hands each email to its case, and only then
    /// tells the relay to forget it.
    private func collectRelayMail() async {
        guard let relay else { return }
        let inbox: RelayInbox
        let deliveries: [RelayInbox.Delivery]
        let unreadable: [String]
        do {
            inbox = try await relay.inbox()
            (deliveries, unreadable) = try await inbox.fetch()
        } catch {
            relayLog.error("Couldn't collect mail: \(String(describing: error), privacy: .public)")
            return
        }
        relayLog.notice("Collected \(deliveries.count) email(s), \(unreadable.count) unreadable")
        var done = unreadable
        for delivery in deliveries {
            guard let file = knownCases().first(where: { $0.relayCaseID == delivery.relayCaseID }) else {
                // Mail for a case this phone no longer has: nothing to do with it.
                done.append(delivery.itemID)
                continue
            }
            let email = delivery.mail.email(to: file.owner.caseAddress)
            do {
                _ = try await wake(file.id, with: .mail([email]), from: .relay)
                done.append(delivery.itemID)
            } catch is Agent.WakeFailed {
                // The case kept the email before the wake stopped, so it is safe.
                done.append(delivery.itemID)
            } catch {
                // Not saved: leave it at the relay for next time.
                relayLog.error("Couldn't hand mail to its case: \(String(describing: error), privacy: .public)")
            }
        }
        do { try await inbox.client.ack(done) } catch {
            relayLog.error("Couldn't ack mail: \(String(describing: error), privacy: .public)")
        }
    }

    /// Cases whose wait has run out get the timer wake they asked for.
    private func runDueTimers() async {
        for file in knownCases() {
            guard case .waitingForReply(_, let until) = file.state, until <= .now else { continue }
            _ = try? await wake(file.id, with: .timer, from: .relay)
        }
    }

    /// Every case: those loaded this launch and those only on disk.
    private func knownCases() -> [CaseFile] {
        var byID = cases
        for file in (try? store.all()) ?? [] where byID[file.id] == nil { byID[file.id] = file }
        return Array(byID.values)
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

    /// Real mail through the relay at `url` (`-uiState relay` in debug, with
    /// `-relayURL`). The model is reached through the relay's proxy, unless a
    /// debug key is given, or `-agentModel scripted` asks for the scripted
    /// demo run.
    static func relay(url: URL, invite: String?) -> CaseRunner {
        let connection = RelayConnection(baseURL: url, invite: invite)
        let model: any ModelClient = RelaySettings.model == "scripted"
            ? SimulatedErrand.model()
            : debugModel() ?? RelayModel(connection: connection, model: RelaySettings.model)
        let runner = CaseRunner(agent: Agent(model: model, mail: RelayConnectionMailer(connection: connection)), mailbox: nil, relay: connection)
        RelayPush.connection = connection
        return runner
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
