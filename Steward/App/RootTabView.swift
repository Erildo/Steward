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
    /// Shared by Insights and the Steward tab, which both open "What Steward Knows".
    @State private var insights = InsightsModel.launch()
    /// What Steward can reach and holds, for the Steward tab.
    @State private var steward: StewardTabModel
    @AppStorage(AppLock.storageKey) private var locks = false
    @State private var locked = UserDefaults.standard.bool(forKey: AppLock.storageKey)
    /// Ask once per return. The Face ID sheet itself makes the app inactive
    /// and active again, which must not ask a second time.
    @State private var asksOnActive = UserDefaults.standard.bool(forKey: AppLock.storageKey)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let tasks = TasksModel.launch()
        _tasks = State(initialValue: tasks)
        _chat = State(initialValue: ChatModel.launch(tasks: tasks))
        _steward = State(initialValue: StewardTabModel.launch(tasks: tasks))
    }

    private func unlock() {
        Task {
            if case .success = await AppLock.authenticate(reason: "Unlock Steward") {
                withAnimation { locked = false }
            }
        }
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
            Tab(value: AppTab.steward) {
                StewardTabView()
            } label: {
                Label {
                    Text("Steward")
                } icon: {
                    Image(uiImage: StewardTabGlyph.image)
                }
            }
            .badge(steward.apps.filter(\.needsSignIn).count)
        }
        .tint(Palette.orange)
        .environment(router)
        .environment(profile)
        .environment(tasks)
        .environment(chat)
        .environment(insights)
        .environment(steward)
        .overlay {
            if locked {
                LockCover { unlock() }
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        // Mail and follow-up times that came due while Steward wasn't looking.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background, locks { locked = true; asksOnActive = true }
            if phase == .active, asksOnActive { asksOnActive = false; unlock() }
            guard phase == .active, let runner = CaseService.runner else { return }
            Task { await runner.refresh() }
        }
    }
}

