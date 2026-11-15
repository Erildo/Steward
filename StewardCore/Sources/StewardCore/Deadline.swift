import Foundation

/// Runs `work` and gives up after `seconds`, without waiting for `work` to
/// notice. A task group can't do this: it waits for every child, so a network
/// read that never returns (as after a failed TLS handshake) would hang it
/// forever. Here `work` runs unstructured; on timeout it is cancelled,
/// `onTimeout` runs (close the connection there), and the caller moves on.
public func withDeadline<T: Sendable>(
    _ seconds: Double,
    onTimeout: @escaping @Sendable () -> Void = {},
    timeoutError: @escaping @Sendable () -> any Error,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = RaceBox<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            box.start(continuation,
                      worker: { try await work() },
                      timer: {
                          try? await Task.sleep(for: .seconds(seconds))
                          guard !Task.isCancelled else { return }
                          if box.finish(.failure(timeoutError())) { onTimeout() }
                      })
        }
    } onCancel: {
        // The caller gave up: answer now, even if the work is stuck.
        box.finish(.failure(CancellationError()))
    }
}

/// One race between the work and the clock: the first to finish resumes the
/// caller, exactly once, and stops the other.
final class RaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var done = false
    private var tasks: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<T, any Error>,
               worker: @escaping @Sendable () async throws -> T,
               timer: @escaping @Sendable () async -> Void) {
        let early: Result<T, any Error>? = lock.withLock {
            if done { return pending }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early); return }
        let w = Task { do { self.finish(.success(try await worker())) } catch { self.finish(.failure(error)) } }
        let t = Task { await timer() }
        let lateStop: Bool = lock.withLock {
            tasks = [w, t]
            return done
        }
        if lateStop { w.cancel(); t.cancel() }
    }

    /// Returns true for the one call that settled the race.
    @discardableResult
    func finish(_ result: Result<T, any Error>) -> Bool {
        let (won, continuation, tasks): (Bool, CheckedContinuation<T, any Error>?, [Task<Void, Never>]) = lock.withLock {
            if done { return (false, nil, []) }
            done = true
            let c = self.continuation
            self.continuation = nil
            if c == nil { pending = result }
            return (true, c, self.tasks)
        }
        guard won else { return false }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
        return true
    }
}

/// Lets exactly one of several racers resume a continuation.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
