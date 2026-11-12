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
    /// run), `errand` (the scripted demo) and `agent` (the simulated run).
    static let isChatDebug = ["chats", "empty", "errand", "agent"].contains(launchState ?? "")

    /// True for `-uiState chats`, which shows sample conversations.
    static let isChatSample = launchState == "chats" || isDemo

    /// Debug launches keep tasks and conversations in a temporary folder,
    /// never in the owner's own files.
    static let usesScratchFiles = isTasksSample || isChatDebug

    /// Debug launches (the Tasks sample and the simulated agent run) keep their
    /// cases in a fresh temporary folder, so test cases never mix with the
    /// owner's own.
    static let store: CaseStore = usesScratchFiles
        ? CaseStore(folder: URL.temporaryDirectory.appending(path: "cases-\(launchState ?? "debug")-\(UUID().uuidString)"))
        : CaseStore(folder: URL.documentsDirectory.appending(path: "Cases"))

    /// `nil` until a model and real mail are connected: then nothing can act on
    /// a case, and the app says so. Debug launches get a simulated one.
    static let runner: CaseRunner? = {
        switch launchState {
        case "agent": .simulated()
        case "tasks", "tasksEmpty", "demo": .tasksSample(store: store)
        default: nil
        }
    }()
}
