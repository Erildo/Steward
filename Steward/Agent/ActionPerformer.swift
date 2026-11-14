import EventKit
import Foundation
import StewardCore

/// Why an approved action didn't happen, in words for the owner (and the agent).
struct ActionFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Does what the owner approved on the phone itself: adds an event to their
/// calendar or a reminder to their Reminders. Runs only after a yes, once.
/// Events need write-only calendar access; reminders need Reminders access.
/// iOS asks the owner the first time.
@MainActor
enum ActionPerformer {
    private static let store = EKEventStore()

    static func add(_ event: ReplyBlock.Action.Event) async -> Result<String, ActionFailure> {
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else {
                return .failure(.init("Steward isn't allowed to add to your calendar. You can allow it in Settings, then ask again."))
            }
            let item = EKEvent(eventStore: store)
            item.title = event.title
            item.startDate = event.start
            item.endDate = event.end
            item.isAllDay = event.allDay
            item.location = event.location
            item.notes = event.notes
            item.calendar = store.defaultCalendarForNewEvents
            try store.save(item, span: .thisEvent)
            return .success("Added to your calendar.")
        } catch {
            return .failure(.init("Your calendar didn't take it, so nothing was added."))
        }
    }

    static func add(_ reminder: ReplyBlock.Action.Reminder) async -> Result<String, ActionFailure> {
        do {
            guard try await store.requestFullAccessToReminders() else {
                return .failure(.init("Steward isn't allowed to add reminders. You can allow it in Settings, then ask again."))
            }
            let item = EKReminder(eventStore: store)
            item.title = reminder.title
            item.notes = reminder.notes
            if let due = reminder.due {
                let units: Set<Calendar.Component> = reminder.dueHasTime
                    ? [.year, .month, .day, .hour, .minute]
                    : [.year, .month, .day]
                item.dueDateComponents = Calendar.current.dateComponents(units, from: due)
                if reminder.dueHasTime { item.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            guard let list = store.defaultCalendarForNewReminders() else {
                return .failure(.init("You don't have a Reminders list to add it to."))
            }
            item.calendar = list
            try store.save(item, commit: true)
            return .success("Added to your Reminders.")
        } catch {
            return .failure(.init("Reminders didn't take it, so nothing was added."))
        }
    }
}

/// Which proposals Steward may make on this phone. A proposal that isn't
/// allowed is never offered to the model. Each one still waits for a yes.
@MainActor
enum ActionAbilities {
    /// The Steward tab, where the owner turns abilities off.
    static weak var steward: StewardTabModel?

    static var offered: Set<String> {
        var names: Set<String> = []
        if allowsAdding("calendar") { names.insert("propose_event") }
        if allowsAdding("reminders") { names.insert("propose_reminder") }
        // Errands need the relay's real mail; the simulated runner is for demos.
        if let runner = CaseService.runner, !runner.isSimulated { names.insert("propose_errand") }
        return names
    }

    /// On unless the owner connected the app and turned adding off. Until
    /// connections are real, nothing connected means nothing turned off.
    private static func allowsAdding(_ id: String) -> Bool {
        guard let app = steward?.app(id) else { return true }
        return app.allowed.contains(.add)
    }
}
