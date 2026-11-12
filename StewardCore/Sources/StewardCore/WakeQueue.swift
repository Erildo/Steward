import Foundation

/// Runs one wake per case at a time.
///
/// `Agent.wake` works on a copy of the case file. If two wakes start on the same
/// case together (a tap in the app and a notification action, say), both copies
/// would still be waiting for approval, and both would send. The queue makes the
/// second wake wait until the first has finished and been saved, so it reads the
/// case as the first left it. Different cases still run side by side.
public actor WakeQueue {
    private var tails: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Runs `work` after every earlier piece of work for `id` has finished,
    /// whether it succeeded or threw.
    public func run<T: Sendable>(_ id: UUID, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tails[id]
        let task = Task {
            _ = await previous?.result
            return try await work()
        }
        let tail = Task { _ = await task.result }
        tails[id] = tail
        let result = await task.result
        if tails[id] == tail { tails[id] = nil }
        return try result.get()
    }
}
