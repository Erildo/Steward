import Foundation
import StewardCore

/// Where the app keeps its cases, and the one runner that moves them forward,
/// shared by Chat and Tasks so an approval counts the same from either.
///
/// Cases are one readable JSON file each, in the app's documents (backed up to
/// the owner's own iCloud). See docs/adr/0001-phone-is-the-brain.md.
enum CaseService {
    private static let launchState = UserDefaults.standard.string(forKey: "uiState")

    /// True for the Tasks sample launches, which keep their cases in a
    /// temporary folder and never touch the owner's files.
    static let isTasksSample = launchState == "tasks" || launchState == "tasksEmpty"

    static let store: CaseStore = isTasksSample
        ? CaseStore(folder: URL.temporaryDirectory.appending(path: "tasks-sample-\(UUID().uuidString)"))
        : CaseStore(folder: URL.documentsDirectory.appending(path: "Cases"))

    /// `nil` until a model and real mail are connected: then nothing can act on
    /// a case, and the app says so. Debug launches get a simulated one.
    static let runner: CaseRunner? = {
        switch launchState {
        case "agent": .simulated()
        case "tasks", "tasksEmpty": .tasksSample(store: store)
        default: nil
        }
    }()
}
