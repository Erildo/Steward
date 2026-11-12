import Foundation
import Observation
import StewardCore

/// The Tasks tab's view of the owner's cases, grouped by who acts next.
/// It only reads case files; the agent moves them forward elsewhere.
@Observable
final class TasksModel {
    private(set) var cases: [CaseFile] = []
    private(set) var couldNotRead = false
    /// True when the tab shows sample errands, so the view can say so.
    let isSample: Bool

    private let store: CaseStore

    init(store: CaseStore, isSample: Bool) {
        self.store = store
        self.isSample = isSample
    }

    func reload() {
        do {
            cases = try store.all()
            couldNotRead = false
        } catch {
            couldNotRead = true
        }
    }

    /// Approvals, questions, and cases Steward handed back to the owner.
    var needsYou: [CaseFile] {
        cases.filter { TaskStatus(of: $0) == .needsYou }
            .sorted { lastActivity($0) > lastActivity($1) }
    }

    /// Cases Steward is working on or waiting on the company for, soonest wake first.
    var onIt: [CaseFile] {
        cases.filter { TaskStatus(of: $0) == .onIt }
            .sorted { nextWake($0) < nextWake($1) }
    }

    /// Finished cases, done or not, most recent first.
    var finished: [CaseFile] {
        cases.filter {
            let status = TaskStatus(of: $0)
            return status == .done || status == .stopped
        }
        .sorted { ($0.closure?.date ?? $0.createdAt) > ($1.closure?.date ?? $1.createdAt) }
    }

    func file(_ id: UUID) -> CaseFile? {
        cases.first { $0.id == id }
    }

    private func lastActivity(_ file: CaseFile) -> Date {
        file.events.last?.date ?? file.createdAt
    }

    private func nextWake(_ file: CaseFile) -> Date {
        if case .waitingForReply(_, let until) = file.state { return until }
        return .distantPast
    }
}

/// Who acts next on a case. Drives the circle on the right of each task.
enum TaskStatus: Equatable {
    case needsYou, onIt, done, stopped

    init(of file: CaseFile) {
        switch file.state {
        case .needsApproval, .needsAnswer:
            self = .needsYou
        case .new, .waitingForReply:
            self = .onIt
        case .closed:
            switch file.closure?.status {
            case .done: self = .done
            case .needsOwner: self = .needsYou
            case .failed, nil: self = .stopped
            }
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .needsYou: "Needs you"
        case .onIt: "Steward is on it"
        case .done: "Done"
        case .stopped: "Not finished"
        }
    }
}

extension CaseFile {
    /// One line on where the case stands, in the owner's terms.
    var statusLine: String {
        switch state {
        case .new:
            return "Getting started"
        case .needsApproval:
            return "Approve the email to \(company.name)"
        case .needsAnswer(_, let question):
            return "Steward asks: \(question)"
        case .waitingForReply(_, let until):
            return "Waiting for \(company.name) · follows up \(until.taskDay)"
        case .closed:
            guard let closure else { return "Closed" }
            switch closure.status {
            case .done: return "Confirmed by \(company.name) · \(closure.date.taskDay)"
            case .needsOwner: return "Over to you: \(closure.summary)"
            case .failed: return "Couldn't finish: \(closure.summary)"
            }
        }
    }
}

extension Date {
    /// "today", "tomorrow", "Thu" within a week, otherwise "14 Nov".
    var taskDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "today" }
        if calendar.isDateInTomorrow(self) { return "tomorrow" }
        if calendar.isDateInYesterday(self) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: self)).day ?? 0
        if (2...6).contains(days) { return formatted(.dateTime.weekday(.abbreviated)) }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

extension TasksModel {
    /// Launch states, like chat's and feed's: `-uiState tasks` shows sample
    /// errands and `-uiState tasksEmpty` the first run, both in a temporary
    /// folder. Otherwise the tab reads the owner's real case files.
    static func launch() -> TasksModel {
        switch UserDefaults.standard.string(forKey: "uiState") {
        case "tasks":
            let store = temporaryStore()
            for file in TasksSample.cases() { try? store.save(file) }
            return TasksModel(store: store, isSample: true)
        case "tasksEmpty":
            return TasksModel(store: temporaryStore(), isSample: true)
        default:
            return TasksModel(store: CaseService.store, isSample: false)
        }
    }

    private static func temporaryStore() -> CaseStore {
        CaseStore(folder: URL.temporaryDirectory.appending(path: "tasks-sample-\(UUID().uuidString)"))
    }
}

/// Demo cases for `-uiState tasks`. Companies and people are fictional.
enum TasksSample {
    static func cases(now: Date = .now) -> [CaseFile] {
        func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86_400) }

        var gym = make("Cancel gym membership", "FitWorld Berlin", "fitworld.example", "DE", playbook: "cancel/de-gym", created: day(-1))
        gym.events = [
            .init(date: day(-1), kind: "opened", detail: "Cancel gym membership with FitWorld Berlin"),
            .init(date: day(-0.1), kind: "approval_asked", detail: "Draft to kuendigung@fitworld.example: Cancellation of membership 48213"),
        ]
        gym.state = .needsApproval(callID: "sample-1", draft: .init(
            direction: .outgoing, date: day(-0.1), from: gym.owner.caseAddress, to: "kuendigung@fitworld.example",
            subject: "Cancellation of membership 48213",
            body: "Hello,\n\nI'm cancelling my membership 48213 with notice, as section 7 of your terms allows. Please confirm in writing the date it ends.\n\nThank you,\nAlex Weber"
        ))

        var energy = make("Dispute estimated energy bill", "Stadtwerk Nord", "stadtwerk-nord.example", "DE", playbook: "dispute/de-energy", created: day(-3))
        energy.events = [
            .init(date: day(-3), kind: "opened", detail: "Dispute estimated energy bill with Stadtwerk Nord"),
            .init(date: day(-0.3), kind: "ask_owner", detail: "Do you have a photo of the meter from 1 October?"),
        ]
        energy.state = .needsAnswer(callID: "sample-2", question: "Do you have a photo of the meter from 1 October?")

        var headphones = make("Refund for faulty headphones", "SoundHouse", "soundhouse.example", "UK", playbook: "refund/gb-retail", created: day(-5))
        headphones.events = [
            .init(date: day(-5), kind: "opened", detail: "Refund for faulty headphones with SoundHouse"),
            .init(date: day(-4), kind: "email_out", detail: "Sent to returns@soundhouse.example: Refund under the Consumer Rights Act"),
            .init(date: day(-2), kind: "email_in", detail: "Reply from returns@soundhouse.example: Your return 7731"),
            .init(date: day(-1), kind: "email_out", detail: "Sent to returns@soundhouse.example: Re: Your return 7731"),
            .init(date: day(-1), kind: "waiting", detail: "Waiting for a reply."),
        ]
        headphones.state = .waitingForReply(callID: "sample-3", until: day(2))

        var broadband = make("Complain about broadband outage", "Fibrelink", "fibrelink.example", "UK", playbook: "complain/gb-broadband", created: day(-8))
        broadband.events = [
            .init(date: day(-8), kind: "opened", detail: "Complain about broadband outage with Fibrelink"),
            .init(date: day(-7), kind: "email_out", detail: "Sent to complaints@fibrelink.example: Formal complaint, account FL-2290"),
            .init(date: day(-7), kind: "waiting", detail: "Waiting for a reply."),
        ]
        broadband.state = .waitingForReply(callID: "sample-4", until: day(9))

        var mealkit = make("Cancel meal kit subscription", "Fresh Fork", "freshfork.example", "UK", playbook: "cancel/gb-subscription", created: day(-12))
        mealkit.events = [
            .init(date: day(-12), kind: "opened", detail: "Cancel meal kit subscription with Fresh Fork"),
            .init(date: day(-11), kind: "email_out", detail: "Sent to help@freshfork.example: Please cancel my subscription"),
            .init(date: day(-9), kind: "email_in", detail: "Reply from help@freshfork.example: Your subscription is cancelled"),
            .init(date: day(-9), kind: "closed", detail: "done: Fresh Fork cancelled the subscription. No more boxes or charges."),
        ]
        mealkit.state = .closed
        mealkit.closure = .init(status: .done, summary: "Fresh Fork cancelled the subscription. No more boxes or charges.",
                                evidence: "We can confirm your subscription has been cancelled and no further payments will be taken.", date: day(-9))

        var phone = make("Cancel phone contract", "Telesul", "telesul.example", "BR", playbook: nil, created: day(-20))
        phone.events = [
            .init(date: day(-20), kind: "opened", detail: "Cancel phone contract with Telesul"),
            .init(date: day(-18), kind: "email_in", detail: "Reply from atendimento@telesul.example: Cancellations by phone only"),
            .init(date: day(-18), kind: "closed", detail: "failed: Telesul only cancels by phone, with the account holder."),
        ]
        phone.state = .closed
        phone.closure = .init(status: .failed, summary: "Telesul only cancels by phone, with the account holder.",
                              evidence: "", date: day(-18))

        return [gym, energy, headphones, broadband, mealkit, phone]
    }

    private static func make(_ errand: String, _ company: String, _ domain: String, _ country: String, playbook: String?, created: Date) -> CaseFile {
        CaseFile(
            errand: errand, createdAt: created,
            owner: .init(name: "Alex Weber", caseAddress: "case@steward.example", accountRef: "",
                         facts: "", goal: errand),
            company: .init(name: company, domain: domain, email: "help@\(domain)", country: country),
            playbook: playbook
        )
    }
}
