import Foundation

/// The rules every draft must pass before the owner even sees it.
/// The owner's tap is the second layer; this is the first, and it is mechanical.
public enum Gate {
    public enum Verdict: Equatable, Sendable {
        case askOwner
        case blocked(String)
    }

    public static func check(to: String, subject: String, body: String, in file: CaseFile) -> Verdict {
        let recipient = to.trimmingCharacters(in: .whitespaces).lowercased()
        let domain = file.company.domain.lowercased()
        guard recipient.hasSuffix("@" + domain) else {
            return .blocked("Recipient \(recipient) is not at \(domain).")
        }
        let text = normalise(subject + "\n" + body)
        for secret in file.owner.secrets where !secret.isEmpty && text.contains(normalise(secret)) {
            return .blocked("The email contains a private detail the owner never shares by email.")
        }
        return .askOwner
    }

    static func normalise(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}
