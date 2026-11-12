import Foundation

/// A task the owner keeps for themself: no company, no agent, just a to-do.
/// Errands Steward runs are case files; these sit beside them in Tasks.
struct OwnerTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var note: String = ""
    var due: Date?
    var createdAt: Date = .now
    var doneAt: Date?

    var isDone: Bool { doneAt != nil }
}

/// The owner's own tasks, as one readable JSON file next to their cases.
typealias OwnerTaskStore = JSONListStore<OwnerTask>

extension OwnerTask {
    /// Sample to-dos for `-uiState tasks`, beside the sample errands.
    static func samples(now: Date = .now) -> [OwnerTask] {
        func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86_400) }
        return [
            OwnerTask(title: "Renew passport", note: "Photos from the booth at the station.", due: day(3), createdAt: day(-2)),
            OwnerTask(title: "Send the landlord the meter reading", due: day(-1), createdAt: day(-4)),
            OwnerTask(title: "Find the warranty for the washing machine", createdAt: day(-1)),
            OwnerTask(title: "Book the car's MOT", createdAt: day(-9), doneAt: day(-3)),
            OwnerTask(title: "Return library books", createdAt: day(-50), doneAt: day(-40)),
        ]
    }
}
