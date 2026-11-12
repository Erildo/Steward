import SwiftUI

struct RootTabView: View {
    @AppStorage(Appearance.storageKey, store: Appearance.store) private var appearance = Appearance.light
    @State private var router = AppRouter()
    @State private var profile = OwnerProfile()
    /// Owned here so the tab can badge what needs you before Tasks is opened.
    @State private var tasks = TasksModel.launch()

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Chat", systemImage: "bubble.left", value: AppTab.chat) {
                ChatView()
            }
            Tab("Feed", systemImage: "newspaper", value: AppTab.feed) {
                FeedView()
            }
            Tab("Insights", systemImage: "lightbulb", value: AppTab.insights) {
                PlaceholderView(title: "Insights", systemImage: "lightbulb",
                                message: "What Steward notices about your errands will appear here.")
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
