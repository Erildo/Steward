import Foundation

/// The times of day Steward looks at its errands: collects replies, runs
/// follow-ups that came due, and moves each case one step. Between check-ins
/// nothing runs; a case is a file that names what wakes it (docs/adr/0003).
public struct CheckInWindows: Codable, Sendable, Equatable {
    /// Local hours, 0 to 23.
    public var hours: [Int]

    public init(hours: [Int]) {
        self.hours = Array(Set(hours.filter { (0...23).contains($0) })).sorted()
    }

    /// Morning, lunch and early evening.
    public static let standard = CheckInWindows(hours: [9, 13, 18])

    /// The first check-in strictly after `now`.
    public func next(after now: Date, calendar: Calendar = .current) -> Date {
        let hours = hours.isEmpty ? Self.standard.hours : hours
        let today = calendar.startOfDay(for: now)
        for day in 0...1 {
            guard let start = calendar.date(byAdding: .day, value: day, to: today) else { continue }
            for hour in hours {
                if let time = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start), time > now { return time }
            }
        }
        return now.addingTimeInterval(24 * 3600)
    }
}

/// What a check-in found, in words the owner sees in a notification. It says
/// how many things wait, never what they are: a notification can be read on a
/// locked screen.
public enum CheckInSummary {
    /// Cases that can't move until the owner taps yes or answers.
    public static func waitingOnOwner(_ cases: [CaseFile]) -> Int {
        cases.filter {
            switch $0.state {
            case .needsApproval, .needsAnswer: true
            default: false
            }
        }.count
    }

    /// True while any case waits for a company, so a missed check-in matters.
    public static func hasOpenWaits(_ cases: [CaseFile]) -> Bool {
        cases.contains { if case .waitingForReply = $0.state { true } else { false } }
    }

    /// The notification after a background check-in, or `nil` when nothing
    /// waits on the owner.
    public static func message(waitingOnOwner count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "One errand needs you before Steward can carry on."
        default: "\(count) errands need you before Steward can carry on."
        }
    }

    /// Shown only when iOS didn't give Steward its check-in: the owner opening
    /// the app does the same job.
    public static let missedCheckIn = "Steward couldn't check your errands for replies. Open it to catch up."
}
