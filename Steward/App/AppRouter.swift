import Foundation
import Observation

/// The five sections, as values the tab bar can select.
enum AppTab: Hashable { case chat, feed, insights, tasks, steward }

/// A screen in Chat's stack, above the Chats list.
enum ChatRoute: Hashable {
    /// A fresh conversation; the token keeps two new chats apart.
    case new(UUID)
    case conversation(UUID)
}

/// Moves between tabs when one screen hands work to another, such as a task
/// handed to Steward opening Chat with the request already written.
@Observable
final class AppRouter {
    /// Tasks and Insights launch states open on their tab; everything else on Chat.
    var tab: AppTab = {
        let state = UserDefaults.standard.string(forKey: "uiState") ?? ""
        if state.hasPrefix("tasks") { return .tasks }
        if state.hasPrefix("insights") { return .insights }
        if state.hasPrefix("steward") { return .steward }
        return .chat
    }()
    /// Chat's stack above the Chats list.
    var chatPath: [ChatRoute] = []
    /// Text for a new chat's composer. The new chat takes it and clears it.
    var chatDraft: String?

    /// Opens a new chat with the request written but not sent.
    func askSteward(_ text: String) {
        chatDraft = text
        chatPath = [.new(UUID())]
        tab = .chat
    }

    /// Shows one conversation in Chat, over the Chats list.
    func openConversation(_ id: UUID) {
        chatPath = [.conversation(id)]
        tab = .chat
    }

    /// A task for Tasks to open, from another tab. Tasks takes it and clears it.
    var taskToOpen: UUID?

    /// Shows one task in Tasks, such as the task a file belongs to.
    func openTask(_ id: UUID) {
        taskToOpen = id
        tab = .tasks
    }

    func newChat() {
        chatPath = [.new(UUID())]
    }
}
