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

    /// The rule for closing a case as done: the evidence must quote the
    /// company's own words from one of its emails. Fragments may be joined with
    /// "..." and each one must appear in the same email. Case, spacing and
    /// punctuation don't count, so typographic quotes or a dropped full stop
    /// don't fail a faithful quote. Returns why the evidence fails, or `nil`.
    public static func checkEvidence(_ evidence: String, in file: CaseFile) -> String? {
        let fragments = evidence
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .components(separatedBy: "...")
            .map(letters)
            .filter { !$0.isEmpty }
        guard fragments.reduce(0, { $0 + $1.count }) >= minimumEvidence else {
            return "for \"done\", quote the company's written confirmation as evidence. Quote it word for word, or close with another status."
        }
        let quoted = file.emails.contains { email in
            guard email.direction == .incoming else { return false }
            let text = letters(email.subject + "\n" + email.body)
            return fragments.allSatisfy(text.contains)
        }
        return quoted ? nil : "the evidence doesn't match any email from the company. Quote its confirmation word for word, or close with another status."
    }

    /// Fewer letters than this can't show a confirmation ("ok", "yes").
    static let minimumEvidence = 8

    /// Lowercased letters and digits only.
    static func letters(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    static func normalise(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}
