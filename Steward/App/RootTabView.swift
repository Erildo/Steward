import SwiftUI

struct RootTabView: View {
    @AppStorage(Appearance.storageKey, store: Appearance.store) private var appearance = Appearance.light
    @State private var router = AppRouter()
    @State private var profile = OwnerProfile()
    /// Every conversation and task. Owned here so the tab can badge what
    /// needs you, and so Chat and Tasks read the same threads.
    @State private var tasks: TasksModel
    /// Chat's engine: routes what the owner writes and runs the errand under way.
    @State private var chat: ChatModel

    init() {
        let tasks = TasksModel.launch()
        _tasks = State(initialValue: tasks)
        _chat = State(initialValue: ChatModel.launch(tasks: tasks))
    }

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Chat", systemImage: "bubble.left", value: AppTab.chat) {
                ChatTab()
            }
            Tab("Feed", systemImage: "newspaper", value: AppTab.feed) {
                FeedView()
            }
            Tab("Insights", systemImage: "lightbulb", value: AppTab.insights) {
                InsightsView()
            }
            Tab("Tasks", systemImage: "checkmark.square", value: AppTab.tasks) {
                TasksView(model: tasks)
            }
            .badge(tasks.needsYouCount)
            Tab("Apps", systemImage: "square.grid.2x2", value: AppTab.apps) {
                PlaceholderView(title: "Connected Apps", systemImage: "square.grid.2x2",
                                message: "Services you connect to Steward will appear here.")
            }
        }
        .tint(Palette.orange)
        .environment(router)
        .environment(profile)
        .environment(tasks)
        .environment(chat)
        .preferredColorScheme(appearance.colorScheme)
    }
}

private struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
                .navigationTitle(title)
                .background(Palette.ground)
        }
    }
}
