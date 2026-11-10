import ActivityKit
import Foundation

/// Mirrors the Steward pill on the lock screen and in the Dynamic Island.
enum LiveErrandActivity {
    private static var current: Activity<ErrandActivityAttributes>?
    private static var title = ""
    private static var clearedStale = false

    static func sync(_ activity: StewardActivity, errandTitle: String?) {
        clearStaleActivities()
        if let errandTitle { title = errandTitle }

        switch activity {
        case .idle:
            end(nil, policy: .immediate)
        case .working(let step, let number, let total):
            show(.init(phase: .working, step: step, number: number, total: total))
        case .needsYou:
            // Keep the bar where the errand stopped.
            let number = current?.content.state.number ?? 1
            let total = current?.content.state.total ?? 1
            show(.init(phase: .needsYou, step: "", number: number, total: total))
        case .done:
            let total = current?.content.state.total ?? 1
            end(.init(phase: .done, step: "", number: total, total: total),
                policy: .after(.now + 8))
        }
    }

    private static func show(_ state: ErrandActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: nil)
        if let current {
            let id = current.id
            Task { await update(id: id, content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            current = try? Activity.request(
                attributes: ErrandActivityAttributes(errandTitle: title),
                content: content
            )
        }
    }

    private static func end(_ state: ErrandActivityAttributes.ContentState?, policy: ActivityUIDismissalPolicy) {
        guard let activity = current else { return }
        current = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let id = activity.id
        Task { await finish(id: id, content, policy: policy) }
    }

    /// Anything left from an earlier launch no longer reflects a running errand.
    private static func clearStaleActivities() {
        guard !clearedStale else { return }
        clearedStale = true
        for activity in Activity<ErrandActivityAttributes>.activities {
            let id = activity.id
            Task { await finish(id: id, nil, policy: .immediate) }
        }
    }

    private typealias Content = ActivityContent<ErrandActivityAttributes.ContentState>

    private nonisolated static func live(_ id: String) -> Activity<ErrandActivityAttributes>? {
        Activity<ErrandActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func update(id: String, _ content: Content) async {
        await live(id)?.update(content)
    }

    private nonisolated static func finish(id: String, _ content: Content?, policy: ActivityUIDismissalPolicy) async {
        await live(id)?.end(content, dismissalPolicy: policy)
    }
}
