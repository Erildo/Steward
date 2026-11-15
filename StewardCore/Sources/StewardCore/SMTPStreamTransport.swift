import Foundation
import Security

/// SMTP over TLS with a URLSession stream task: TLS from the first byte on
/// port 465, or upgraded after STARTTLS on port 587 (iCloud only offers that).
/// The system checks the server's certificate; nothing is sent in the clear
/// past the greeting.
///
/// Every read and write has a hard deadline. After a failed TLS handshake a
/// stream task's read may never return, so on a deadline or an error the
/// connection is cancelled and the caller moves on.
public final class SMTPStreamTransport: NSObject, SMTPTransport, URLSessionDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionStreamTask!
    /// Tests only: the one self-signed certificate a local server may use.
    private let pinnedCertificate: Data?
    private let seconds: Double

    private init(server: SMTPServer, pinnedCertificate: Data?, seconds: Double) {
        self.pinnedCertificate = pinnedCertificate
        self.seconds = seconds
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        task = session.streamTask(withHostName: server.host, port: Int(server.port))
    }

    public static func connect(_ server: SMTPServer, pinnedCertificate: Data? = nil, seconds: Double = 20) async throws -> SMTPStreamTransport {
        let transport = SMTPStreamTransport(server: server, pinnedCertificate: pinnedCertificate, seconds: seconds)
        transport.task.resume()
        if !server.startTLS { transport.task.startSecureConnection() }
        return transport
    }

    public func send(_ data: Data) async throws {
        let task = self.task!, seconds = self.seconds
        try await guarded { try await task.write(data, timeout: seconds) }
    }

    public func receive() async throws -> Data {
        let task = self.task!, seconds = self.seconds
        return try await guarded {
            let (data, _) = try await task.readData(ofMinLength: 1, maxLength: 65_536, timeout: seconds)
            return data ?? Data()
        }
    }

    public func startTLS() async throws {
        task.startSecureConnection()
    }

    public func close() async {
        task.closeWrite()
        task.cancel()
        session.invalidateAndCancel()
    }

    /// One read or write, cut off at the deadline; any failure closes the
    /// connection, so nothing is left waiting on it.
    private func guarded<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = self.task!, session = self.session!
        let cancel: @Sendable () -> Void = { task.cancel(); session.invalidateAndCancel() }
        do {
            return try await withDeadline(seconds + 2, onTimeout: cancel, timeoutError: {
                SMTPError(.timeout, "The mail server took too long to answer.")
            }, work)
        } catch let error as SMTPError {
            throw error
        } catch {
            cancel()
            let ns = error as NSError
            if (error as? URLError)?.code == .timedOut || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ETIMEDOUT)) {
                throw SMTPError(.timeout, "The mail server took too long to answer.")
            }
            throw SMTPError(.closed, "Couldn't reach the mail server securely: \(error.localizedDescription)")
        }
    }

    // MARK: URLSessionDelegate

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let pinnedCertificate,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SecCertificateCopyData(leaf) as Data == pinnedCertificate
        else {
            // The system's own check, as for any connection.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
