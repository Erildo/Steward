import BackgroundTasks
import Foundation
import StewardCore
import UserNotifications

/// Steward's check-ins (docs/adr/0003): a few times a day, collect replies,
/// run follow-ups that came due, and move each case one step. Nothing runs in
/// between. The relay's push only makes a check-in come sooner; without it,
/// iOS's background refresh runs them, and if iOS skips one, a single
/// notification asks the owner to open Steward, which does the same job.
@MainActor
enum CheckIn {
    static let taskID = "esh.steward.checkin"
    static let windows = CheckInWindows.standard

    private static let digestID = "checkin-digest"
    private static let missedID = "checkin-missed"

    /// One check-in. In the background, it tells the owner how many errands
    /// wait on them; in the foreground they're already looking.
    /// Returns what happened, in a few words, for the background-run notification.
    @discardableResult
    static func run(inBackground: Bool) async -> String {
        guard let runner = CaseService.runner, !runner.isSimulated else { return "skipped (no mailbox set up)" }
        let before = Set(waitingOnOwnerIDs(runner.allCases()))
        await runner.refresh()
        let cases = runner.allCases()
        schedule(cases)
        let outcome = cases.isEmpty ? "ran, no errands" : "ran, \(cases.count) errand\(cases.count == 1 ? "" : "s") checked"
        guard inBackground else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [digestID])
            return outcome
        }
        // Only news is worth a notification: errands that newly wait on the owner.
        let waiting = waitingOnOwnerIDs(cases)
        guard !Set(waiting).subtracting(before).isEmpty, let body = CheckInSummary.message(waitingOnOwner: waiting.count) else { return outcome }
        post(digestID, body: body, at: nil)
        return outcome
    }

    /// One notification per background run, so the owner can see that iOS
    /// really gave Steward its time while the app was closed.
    static func announceBackgroundRun(_ job: String, outcome: String) {
        let content = UNMutableNotificationContent()
        content.title = "Steward ran in the background"
        content.body = "\(job): \(outcome) at \(Date.now.formatted(date: .omitted, time: .shortened))."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "background-run-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// Asks iOS for the next check-in, and replaces the one notification that
    /// covers a check-in iOS skips. Called after every check-in and whenever
    /// the app goes to the background.
    static func schedule(_ cases: [CaseFile]? = nil) {
        let cases = cases ?? CaseService.runner?.allCases() ?? []
        let next = windows.next(after: .now)
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = next
        try? BGTaskScheduler.shared.submit(request)

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [missedID])
        // Nothing to miss unless a company may have replied.
        guard CheckInSummary.hasOpenWaits(cases) else { return }
        // Half an hour after the check-in after next: a run before then
        // replaces it, so the owner only sees it when iOS skipped a whole window.
        let after = windows.next(after: next).addingTimeInterval(30 * 60)
        post(missedID, body: CheckInSummary.missedCheckIn, at: after)
    }

    private static func waitingOnOwnerIDs(_ cases: [CaseFile]) -> [UUID] {
        cases.filter { CheckInSummary.waitingOnOwner([$0]) == 1 }.map(\.id)
    }

    private static func post(_ id: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = "Steward"
        content.body = body
        content.sound = .default
        let trigger = date.map {
            UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0), repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
