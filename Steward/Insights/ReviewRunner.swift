import BackgroundTasks
import EventKit
import Foundation
import Observation
import StewardCore
import UserNotifications

/// Runs Steward's daily review (`DailyReview` in StewardCore) and keeps what
/// it found in `Review.json` in the owner's documents, beside their memory.
///
/// When it runs: once a day at most, when the app comes forward 20 hours or
/// more after the last try, and from a background refresh. Three failures in
/// a row pause it for a week (`ReviewSchedule`). `-forceReview YES` runs it
/// at launch whatever the schedule says, for debugging.
///
/// It only proposes: findings for Insights, offers the owner taps to open
/// Chat, and nudges as visible notifications. It never asks for calendar or
/// reminders access; it reads them only when the owner already allowed it.
@MainActor
@Observable
final class ReviewRunner {
    static let taskID = "esh.steward.review"

    private(set) var record: ReviewRecord
    private(set) var isRunning = false
    @ObservationIgnored private let store: ReviewStore
    @ObservationIgnored private let memory: MemoryBook

    init(record: ReviewRecord, store: ReviewStore, memory: MemoryBook) {
        self.record = record
        self.store = store
        self.memory = memory
    }

    /// The owner's real files only. Sample and scratch launches keep their
    /// samples and never run a review.
    static let shared: ReviewRunner? = {
        let state = UserDefaults.standard.string(forKey: "uiState")
        guard state == nil || state == "none" || state == "relay", !CaseService.usesScratchFiles else { return nil }
        let store = ReviewStore(url: URL.documentsDirectory.appending(path: "Review.json"))
        return ReviewRunner(record: (try? store.load()) ?? ReviewRecord(), store: store, memory: .shared)
    }()

    /// Debug: `-forceReview YES` runs one review at launch, whatever the schedule.
    static var forcedAtLaunch: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "forceReview")
        #else
        false
        #endif
    }

    @ObservationIgnored private var forcedDone = false

    /// Runs a review when one is due (or forced). Without a model it does
    /// nothing and counts no failure: there was nothing to fail.
    func runIfDue(now: Date = .now) async {
        let forced = Self.forcedAtLaunch && !forcedDone
        forcedDone = true
        guard !isRunning, forced || record.schedule.isDue(at: now), let model = Self.model() else { return }
        isRunning = true
        defer { isRunning = false }
        record.schedule.started(at: now)
        save()

        let input = await ReviewSources.input(memory: memory.memory, record: record, now: now)
        do {
            let result = try await DailyReview(model: model, now: { now }).run(input)
            record.schedule.succeeded(at: .now)
            record.show(result)
            save()
            await ReviewNudges.schedule(result.nudges)
        } catch {
            record.schedule.failed(at: .now)
            save()
        }
    }

    /// A background refresh: run if due, then ask for the next one.
    static func runInBackground() async {
        guard let runner = shared else { return }
        await runner.runIfDue()
        runner.scheduleBackgroundRefresh()
    }

    /// Asks iOS for a background refresh once the next review may run.
    func scheduleBackgroundRefresh(now: Date = .now) {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = record.schedule.nextDue(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func save() {
        try? store.save(record)
    }

    private static func model() -> (any ModelClient)? {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "reviewModel") == "scripted" {
            return ScriptedModelClient([ReviewDemo.turn(now: .now)])
        }
        #endif
        return ModelAccess.model(searchesWeb: false)
    }

    // MARK: The owner's reactions

    func reaction(to id: UUID) -> ReviewRecord.Reaction? { record.reactions[id.uuidString] }
    func isHidden(_ id: UUID) -> Bool { record.hidden.contains(id) }

    /// "That's me" keeps the finding in memory as a fact (confirming the
    /// guess it matches, if any); "Not quite" trusts the matching guess less
    /// and tells the next review. Tapping the same answer again takes it back.
    func react(_ reaction: ReviewRecord.Reaction, to id: UUID) {
        guard let insight = record.result?.insights.first(where: { $0.id == id }) else { return }
        let key = id.uuidString
        let previous = record.reactions[key]
        undo(previous, for: insight)
        guard previous != reaction else {
            record.reactions[key] = nil
            save()
            return
        }
        record.reactions[key] = reaction
        switch reaction {
        case .confirmed:
            if let known = memory.memory.item(matching: insight.memoryNote) {
                if known.kind == .guess { memory.update { $0.confirm(known.id) } }
            } else if case .added(let item) = memory.remember(.init(
                text: insight.memoryNote, kind: .fact, source: .review,
                evidence: "You confirmed it in Insights on \(Date.now.formatted(.dateTime.day().month(.wide)))",
                topic: insight.topic)) {
                record.added[key] = item.id
            }
        case .corrected:
            if let known = memory.memory.item(matching: insight.memoryNote), known.kind == .guess {
                memory.update { $0.doubt(known.id) }
            }
            record.noteCorrected(insight.title)
        }
        save()
    }

    private func undo(_ reaction: ReviewRecord.Reaction?, for insight: ReviewInsight) {
        let key = insight.id.uuidString
        switch reaction {
        case .confirmed:
            if let added = record.added.removeValue(forKey: key) { memory.update { $0.forget(added) } }
        case .corrected:
            record.unnoteCorrected(insight.title)
        case nil:
            break
        }
    }

    /// "Stop Noticing This": hidden now, and never brought up again.
    func stop(_ id: UUID) {
        guard let insight = record.result?.insights.first(where: { $0.id == id }) else { return }
        record.stop(insight)
        save()
    }

    func unstop(_ id: UUID) {
        guard let insight = record.result?.insights.first(where: { $0.id == id }) else { return }
        record.unstop(insight)
        save()
    }
}

// MARK: What the review reads

/// Gathers the review's input from the owner's own files and, only when
/// already allowed, their calendar and reminders.
@MainActor
enum ReviewSources {
    static func input(memory: Memory, record: ReviewRecord, now: Date) async -> DailyReview.Input {
        let folder = CaseService.store.folder.deletingLastPathComponent()
        let stewardTasks = (try? JSONListStore<StewardTask>(url: folder.appending(path: "StewardTasks.json")).all()) ?? []
        let ownTasks = (try? OwnerTaskStore(url: folder.appending(path: "OwnerTasks.json")).all()) ?? []
        let goals = (try? FeedStore(folder: FeedFolder.url).loadTaste().goals) ?? []
        let weekAgo = now.addingTimeInterval(-7 * 86_400)

        let open = stewardTasks.filter { !$0.isFinished }.sorted { $0.lastActivity > $1.lastActivity }.prefix(20).map {
            "\($0.goal): \($0.statusLine(connected: true))"
        } + ownTasks.filter { !$0.isDone }.prefix(20).map { task in
            "\(task.title) (the owner's own\(task.due.map { ", due \(stamp($0))" } ?? ""))"
        }
        let chats = stewardTasks.filter { $0.lastActivity >= weekAgo }.sorted { $0.lastActivity > $1.lastActivity }.prefix(20).map(summary)

        return DailyReview.Input(
            memory: memory, goals: goals, openTasks: Array(open), chats: Array(chats),
            calendar: events(from: now), reminders: await reminders(from: now),
            stopped: record.stopped, corrected: record.corrected
        )
    }

    /// One chat in a line or two: what it was about, where it stands, and the
    /// last thing each side said.
    private static func summary(_ task: StewardTask) -> String {
        func cut(_ text: String) -> String {
            let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
        }
        var line = "\(stamp(task.createdAt)) \"\(cut(task.goal))\", \(task.messages.count) messages, \(task.statusLine(connected: true))"
        if let owner = task.messages.last(where: { $0.author == .owner }), owner.text != task.goal {
            line += ". Owner last said: \"\(cut(owner.text))\""
        }
        if let steward = task.messages.last(where: { $0.author == .steward }) {
            line += ". Steward last said: \"\(cut(steward.text))\""
        }
        return line
    }

    /// The next 14 days of events, or `nil` when Steward may not read them.
    private static func events(from now: Date) -> [String]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(DailyReview.horizon), calendars: nil)
        return store.events(matching: predicate).prefix(60).map { event in
            let when = event.isAllDay ? day(event.startDate) : "\(stamp(event.startDate))–\(time(event.endDate))"
            return "\(when) \(event.title ?? "Untitled")"
        }
    }

    /// Open reminders due in the next 14 days, or `nil` when not allowed.
    private nonisolated static func reminders(from now: Date) async -> [String]? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                              ending: now.addingTimeInterval(DailyReview.horizon), calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                let lines = (found ?? []).prefix(40).map { reminder in
                    let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return "\(reminder.title ?? "Untitled")\(due.map { ", due \(stamp($0))" } ?? "")"
                }
                continuation.resume(returning: Array(lines))
            }
        }
    }

    private nonisolated static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// "Sat 2026-11-14 18:30": unambiguous for a model.
    private nonisolated static func stamp(_ date: Date) -> String { formatter("EEE yyyy-MM-dd HH:mm").string(from: date) }
    private nonisolated static func day(_ date: Date) -> String { formatter("EEE yyyy-MM-dd").string(from: date) + " all day" }
    private nonisolated static func time(_ date: Date) -> String { formatter("HH:mm").string(from: date) }
}

// MARK: Nudges

/// The review's heads-ups, as visible local notifications, held until the
/// end of the owner's Quiet Hours when one would land inside them.
@MainActor
enum ReviewNudges {
    static let prefix = "review.nudge."

    static func schedule(_ nudges: [ReviewNudge]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard !nudges.isEmpty else { return }

        // Never a permission prompt from a background review: if the owner
        // hasn't been asked yet, nudges go quietly to Notification Center.
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) == true else { return }
        default: return
        }

        let quiet = quietHours()
        for nudge in nudges {
            let date = quiet?.deliveryTime(for: nudge.at) ?? nudge.at
            let content = UNMutableNotificationContent()
            content.title = nudge.title
            content.body = nudge.body
            content.sound = .default
            content.threadIdentifier = "review"
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(identifier: prefix + nudge.id.uuidString, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }

    /// The Steward tab's Quiet Hours, when turned on.
    static func quietHours(defaults: UserDefaults = .standard) -> QuietHours? {
        guard defaults.bool(forKey: StewardRules.quietKey) else { return nil }
        let from = defaults.object(forKey: StewardRules.quietFromKey) as? Int ?? StewardRules.defaultFrom
        let to = defaults.object(forKey: StewardRules.quietToKey) as? Int ?? StewardRules.defaultTo
        return QuietHours(from: from, to: to)
    }
}

#if DEBUG
/// `-reviewModel scripted`: a fixed review instead of a model, for trying the
/// review without a model quota. Made up. One finding touches a topic that
/// is off by default, to show the filter drop it.
enum ReviewDemo {
    static func turn(now: Date) -> AssistantTurn {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let tomorrowLate = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0,
                                                 of: now.addingTimeInterval(86_400)) ?? now.addingTimeInterval(86_400)
        func evidence(_ source: String, _ text: String) -> JSONValue {
            .object(["source": .string(source), "text": .string(text)])
        }
        func point(_ label: String, _ value: Double) -> JSONValue {
            .object(["label": .string(label), "value": .number(value)])
        }
        let insights: [JSONValue] = [
            .object([
                "kind": .string("about_you"), "lead": .bool(true),
                "title": .string("Evenings are when you hand things over"),
                "detail": .string("You started 5 of your last 7 chats after 6 pm. The two in the morning were both quick questions."),
                "confidence": .string("fairly_sure"), "basis": .string("7 chats"),
                "evidence": .array([evidence("chat", "5 of 7 chats this week started after 6 pm")]),
                "remember": .string("Hands tasks to Steward in the evening"),
                "chart": .object(["type": .string("chart"), "style": .string("bars"), "unit": .string("chats started"),
                                  "points": .array([point("Morning", 2), point("Afternoon", 0), point("Evening", 5)]),
                                  "highlight": .number(2)]),
                "offer": .object(["label": .string("Line up my evenings"),
                                  "request": .string("Each evening at 7, show me what's waiting for me.")]),
            ]),
            .object([
                "kind": .string("goal"), "title": .string("Half marathon in April"),
                "detail": .string("You have no runs in your calendar this week, and two late meetings on Tuesday and Thursday."),
                "status": .string("Needs a plan"), "status_needs_you": .bool(true),
                "confidence": .string("hunch"), "basis": .string("your goals and calendar"),
                "evidence": .array([evidence("you", "Your goal: half marathon in April"),
                                    evidence("calendar", "Meetings until 8 pm on Tuesday and Thursday")]),
                "offer": .object(["label": .string("Plan around late meetings"),
                                  "request": .string("When I have a meeting after 7 pm, move that day's run to the morning and remind me the night before.")]),
            ]),
            .object([
                "kind": .string("change"), "title": .string("You've been sleeping less before deadlines"),
                "detail": .string("Late-night chats doubled in the days before each due date."),
                "confidence": .string("hunch"), "basis": .string("4 chats"),
                "evidence": .array([evidence("chat", "4 chats after midnight this week")]),
            ]),
            .object([
                "kind": .string("change"), "title": .string("More is waiting on companies than on you"),
                "detail": .string("Three of your four open tasks wait on a company's reply; only one needs you."),
                "confidence": .string("sure"), "basis": .string("4 open tasks"),
                "evidence": .array([evidence("task", "3 tasks waiting on a reply, 1 asking you a question")]),
            ]),
        ]
        let nudges: [JSONValue] = [.object([
            "title": .string("Passport form due Friday"),
            "body": .string("Twenty minutes with your old passport at hand."),
            "at": .string(formatter.string(from: tomorrowLate)),
        ])]
        return AssistantTurn(toolCalls: [ToolCall(id: "review-demo", name: "submit_review",
                                                  arguments: ["insights": .array(insights), "nudges": .array(nudges)])])
    }
}
#endif
