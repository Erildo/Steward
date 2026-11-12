import Foundation
import Observation

/// The five sections, as values the tab bar can select.
enum AppTab: Hashable { case chat, feed, insights, tasks, apps }

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
    /// Tasks launch states open on Tasks; everything else on Chat.
    var tab: AppTab = (UserDefaults.standard.string(forKey: "uiState") ?? "").hasPrefix("tasks") ? .tasks : .chat
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

    func newChat() {
        chatPath = [.new(UUID())]
    }
}
