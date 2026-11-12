import Foundation
import Observation

/// The five sections, as values the tab bar can select.
enum AppTab: Hashable { case chat, feed, insights, tasks, apps }

/// Moves between tabs when one screen hands work to another, such as a task
/// handed to Steward opening Chat with the request already written.
@Observable
final class AppRouter {
    /// Tasks launch states open on Tasks; everything else on Chat.
    var tab: AppTab = (UserDefaults.standard.string(forKey: "uiState") ?? "").hasPrefix("tasks") ? .tasks : .chat
    /// Text for Chat's composer. Chat takes it and clears it.
    var chatDraft: String?

    func askSteward(_ text: String) {
        chatDraft = text
        tab = .chat
    }
}
