import Foundation

/// The agent's instructions and tools, rendered from the shared `Spec/` files
/// that the Stage 0 harness also loads.
enum Prompt {
    static func system(for file: CaseFile, today: Date, timeZone: TimeZone = .current) -> String {
        let owner = file.owner
        let block = file.playbook.map { Spec.render(Spec.playbook, ["playbook": $0]) }
            ?? Spec.render(Spec.noPlaybook, ["country": file.company.country ?? "your owner's country"])
        return Spec.render(Spec.system, [
            "today": day(today, timeZone: timeZone),
            "name": owner.name,
            "email": owner.caseAddress,
            "account_ref": owner.accountRef,
            "facts": owner.facts.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            "goal": owner.goal,
            "will_not": owner.willNot.isEmpty ? "nothing in particular" : owner.willNot.joined(separator: "; "),
            "company_email": file.company.email,
            "playbook_block": block,
        ])
    }

    /// "Tuesday 10 November 2026", the same form the harness uses.
    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// The core tools, as transcript replay offers them.
    static var tools: [ToolSpec] { Spec.tools(for: .transcript) }
}
