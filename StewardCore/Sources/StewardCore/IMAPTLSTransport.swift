import Foundation
import Network

/// IMAP over TLS (port 993) with Network.framework. The system checks the
/// server's certificate; there is no plain-text fallback.
public final class IMAPTLSTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "steward.imap")

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(host: String, port: UInt16) async throws -> IMAPTLSTransport {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw IMAPError(.malformed, "That port isn't valid.") }
        let transport = IMAPTLSTransport(NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tls))
        try await transport.start()
        return transport
    }

    private func start() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: IMAPError(.closed, "Couldn't reach the mail server: \(error.localizedDescription)")) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: IMAPError(.closed, "The connection was cancelled.")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: IMAPError(.closed, error.localizedDescription)) } else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if let error { continuation.resume(throwing: IMAPError(.closed, error.localizedDescription)) }
                else if isComplete { continuation.resume(returning: Data()) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    public func close() async {
        connection.cancel()
    }

    /// Lets exactly one state change resume the continuation.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
