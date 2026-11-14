import Foundation

/// How the agent remembers a case between wakes (ADR 0002, decision 1).
public enum AgentContext: String, Codable, Sendable {
    /// The whole model conversation is kept and replayed at every wake.
    case transcript
    /// Each wake starts fresh from a brief rendered from the case file, plus
    /// the agent's own notes. The conversation lasts only within one wake.
    /// Ships as the default only once a Stage 0 "brief" arm matches or beats
    /// transcript replay on done rate and false "done" rate.
    case brief
}

/// The case brief: errand, goal, the owner's standing instructions, a
/// timeline, the emails, the agent's notes, and what is new this wake.
///
/// Rendered from `Spec/brief.txt`. The harness renders the same text from the
/// same inputs (`steward_harness/brief.py`), and `Tests/Conformance/briefs.json`
/// holds cases both must render identically.
enum Brief {
    struct Mail: Equatable {
        var incoming: Bool
        var day: String
        var from: String
        var to: String
        var subject: String
        var body: String
    }

    static func render(_ file: CaseFile, today: Date, new: String, timeZone: TimeZone = .current) -> String {
        let day = { (date: Date) in Prompt.day(date, timeZone: timeZone) }
        return render(
            today: day(today),
            errand: file.errand,
            company: file.company.name,
            companyEmail: file.company.email,
            goal: file.owner.goal,
            instructions: file.standingInstructions.map { (day($0.date), $0.text) },
            timeline: file.events.map { (day($0.date), $0.kind, $0.detail) },
            emails: file.emails.map {
                Mail(incoming: $0.direction == .incoming, day: day($0.date), from: $0.from, to: $0.to, subject: $0.subject, body: $0.body)
            },
            notes: file.notes,
            new: new
        )
    }

    /// The renderer itself, on plain values, so the conformance test and the
    /// harness can feed it exactly the same inputs.
    static func render(
        today: String,
        errand: String,
        company: String,
        companyEmail: String,
        goal: String,
        instructions: [(day: String, text: String)],
        timeline: [(day: String, kind: String, detail: String)],
        emails: [Mail],
        notes: String,
        new: String
    ) -> String {
        let rules = Spec.rules.brief
        let nothing = rules.nothing
        let kinds = Set(rules.timelineKinds)

        let instructionLines = instructions.map { "- \($0.day): \($0.text)" }
        let timelineLines = timeline.filter { kinds.contains($0.kind) }.map { "- \($0.day): \($0.detail)" }

        // The last few emails are always in full, and so is the company's
        // latest. Older ones are shortened so a month-long case stays small.
        let lastIncoming = emails.lastIndex { $0.incoming }
        let blocks = emails.enumerated().map { index, mail in
            let full = index >= emails.count - rules.fullEmails || index == lastIncoming
            let body = full ? mail.body : shorten(mail.body, to: rules.olderEmailChars)
            let text = mail.incoming ? "<email_content>\n\(body)\n</email_content>" : body
            return "[\(index + 1)] \(mail.day), from \(mail.from) to \(mail.to)\nSubject: \(mail.subject)\n\(text)"
        }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return Spec.render(Spec.brief, [
            "today": today,
            "errand": errand,
            "company": company,
            "company_email": companyEmail,
            "goal": goal,
            "instructions": instructionLines.isEmpty ? nothing : instructionLines.joined(separator: "\n"),
            "timeline": timelineLines.isEmpty ? nothing : timelineLines.joined(separator: "\n"),
            "emails": blocks.isEmpty ? nothing : blocks.joined(separator: "\n\n"),
            "notes": trimmedNotes.isEmpty ? nothing : trimmedNotes,
            "new": new,
        ])
    }

    /// The first `limit` characters, counted as Unicode scalars (as Python
    /// counts them), then a marker.
    static func shorten(_ text: String, to limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.prefix(limit))
        return String(out) + " […]"
    }

    /// The notes as saved: at most `notesMaxWords` words. Returns the notes and
    /// whether they were cut.
    static func capNotes(_ text: String) -> (String, Bool) {
        let limit = Spec.rules.notesMaxWords
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > limit else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), false) }
        return (words.prefix(limit).joined(separator: " "), true)
    }
}

/// The stronger model's check before a "done" is accepted (ADR 0002, decision 6).
enum Review {
    enum Verdict: Equatable {
        case accept
        case reject(String)
    }

    static func system(for file: CaseFile) -> String {
        Spec.render(Spec.review, ["name": file.owner.name, "goal": file.owner.goal])
    }

    static func proposal(summary: String, evidence: String) -> String {
        Spec.render(Spec.rules.new.review, ["summary": summary, "evidence": evidence])
    }

    /// Only a reply that starts with ACCEPT accepts. Anything else, a muddled
    /// reply included, sends the agent back to work.
    static func verdict(_ reply: String) -> Verdict {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("ACCEPT") { return .accept }
        if text.uppercased().hasPrefix("REJECT"), let colon = text.firstIndex(of: ":") {
            let reason = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty { return .reject(reason) }
        }
        return .reject("it gave no clear verdict.")
    }
}
