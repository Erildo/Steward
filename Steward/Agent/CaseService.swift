import Foundation
import StewardCore

/// Where the app keeps its cases, and the one runner that moves them forward,
/// shared by Chat and Tasks so an approval counts the same from either.
///
/// Cases are one readable JSON file each, in the app's documents (backed up to
/// the owner's own iCloud). See docs/adr/0001-phone-is-the-brain.md.
enum CaseService {
    private static let launchState = UserDefaults.standard.string(forKey: "uiState")

    /// `-uiState demo`: every tab's sample data at once (chats, tasks,
    /// errands and the feed), for trying the whole app on a phone. Debug
    /// builds start in it unless another state is passed (see `StewardApp`).
    static let isDemo = launchState == "demo"

    /// True for the Tasks sample launches, which show sample errands.
    static let isTasksSample = launchState == "tasks" || launchState == "tasksEmpty" || isDemo

    /// Chat's debug launches: `chats` (sample conversations), `empty` (first
    /// run), `errand` (the scripted demo), `agent` (the simulated run) and
    /// `relay` (the sample errand through a real relay, `-relayURL`).
    static let isChatDebug = ["chats", "empty", "errand", "agent", "relay"].contains(launchState ?? "")

    /// True for `-uiState chats`, which shows sample conversations.
    static let isChatSample = launchState == "chats" || isDemo

    /// Debug launches keep tasks and conversations in a temporary folder,
    /// never in the owner's own files.
    static let usesScratchFiles = isTasksSample || isChatDebug

    /// Debug launches (the Tasks sample and the simulated agent run) keep their
    /// cases in a fresh temporary folder, so test cases never mix with the
    /// owner's own.
    static let store: CaseStore = launchState == "relay"
        // Relay runs are real cases at a test relay: they must outlive a
        // relaunch, but stay apart from the owner's own.
        ? CaseStore(folder: URL.documentsDirectory.appending(path: "Cases-debug-relay"))
        : usesScratchFiles
        ? CaseStore(folder: URL.temporaryDirectory.appending(path: "cases-\(launchState ?? "debug")-\(UUID().uuidString)"))
        : CaseStore(folder: URL.documentsDirectory.appending(path: "Cases"))

    /// A link to a relay, for debug runs only (`-uiState relay -relayURL …`).
    /// Errands don't need one: they use the owner's own mailbox.
    static let relayConnection: RelayConnection? = {
        guard launchState == "relay", let url = RelaySettings.url else { return nil }
        let connection = RelayConnection(baseURL: url, invite: RelaySettings.invite)
        RelayPush.connection = connection
        return connection
    }()

    /// What moves errands forward. Real launches use the owner's own mailbox
    /// and AI key; errands say what's missing until both are connected.
    /// Debug launches get a simulated one, or the relay.
    static let runner: CaseRunner? = {
        switch launchState {
        case "agent": return .simulated()
        case "tasks", "tasksEmpty", "demo": return .tasksSample(store: store)
        case "relay": return relayConnection.map { .relay(connection: $0) }
        case nil, "none": return .ownMailbox()
        default: return nil
        }
    }()
}
