import SwiftUI

struct RootTabView: View {
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.light

    var body: some View {
        TabView {
            Tab("Chat", systemImage: "bubble.left") {
                ChatView()
            }
            Tab("Feed", systemImage: "newspaper") {
                FeedView()
            }
            Tab("Insights", systemImage: "lightbulb") {
                PlaceholderView(title: "Insights", systemImage: "lightbulb",
                                message: "What Steward notices about your errands will appear here.")
            }
            Tab("Tasks", systemImage: "checkmark.square") {
                PlaceholderView(title: "Tasks", systemImage: "checkmark.square",
                                message: "Errands in progress will appear here.")
            }
            Tab("Apps", systemImage: "square.grid.2x2") {
                PlaceholderView(title: "Connected Apps", systemImage: "square.grid.2x2",
                                message: "Services you connect to Steward will appear here.")
            }
        }
        .tint(Palette.orange)
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
