import Foundation
import Testing
@testable import StewardCore

// The app must tell the model, and judge it, exactly as the Stage 0 harness does.
// Reads the shared cases in Tests/Conformance; harness/tests/test_conformance.py
// reads the same files.

private let cases = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Conformance")

private func json(_ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: cases.appending(path: name)))
}

private struct PromptCase: Decodable, CustomTestStringConvertible {
    struct Owner: Decodable { var name, email, account_ref, facts, goal: String; var will_not: [String] }
    struct Company: Decodable { var name, domain, email, country: String }
    var name, today: String
    var owner: Owner
    var company: Company
    var playbook: String?
    var testDescription: String { name }
}

private let promptCases: [PromptCase] = {
    (try? JSONDecoder().decode([PromptCase].self, from: Data(contentsOf: cases.appending(path: "prompts.json")))) ?? []
}()

@Test(arguments: promptCases)
private func systemPromptMatches(_ c: PromptCase) throws {
    let utc = TimeZone(identifier: "UTC")!
    let today = try Date(c.today + "T12:00:00Z", strategy: .iso8601)
    var file = CaseFile(
        errand: "cancel",
        createdAt: today,
        owner: .init(name: c.owner.name, caseAddress: c.owner.email, accountRef: c.owner.account_ref, facts: c.owner.facts, goal: c.owner.goal, willNot: c.owner.will_not),
        company: .init(name: c.company.name, domain: c.company.domain, email: c.company.email, country: c.company.country)
    )
    file.playbook = c.playbook
    let expected = try String(contentsOf: cases.appending(path: "expected/\(c.name).txt"), encoding: .utf8)
    #expect(Prompt.system(for: file, today: today, timeZone: utc) == expected)
}

@Test func conformanceCasesWereFound() {
    #expect(promptCases.count >= 2)
}

@Test func toolsMatchTheSpec() throws {
    let spec = try #require(try json("../../Sources/StewardCore/Spec/tools.json") as? [[String: Any]])
    #expect(Prompt.tools.map(\.name) == spec.compactMap { $0["name"] as? String })
    #expect(Prompt.tools.map(\.name) == ["send_email", "wait_for_reply", "ask_owner", "close_case"])
}

@Test func sendRulesMatch() throws {
    let gate = try #require(try json("gate.json") as? [String: Any])
    let domain = try #require(gate["send_domain"] as? String)
    let sends = try #require(gate["send"] as? [[String: Any]])
    for send in sends {
        let to = send["to"] as! String
        var file = gymLike(domain: domain)
        file.owner.secrets = send["secrets"] as! [String]
        let verdict = Gate.check(to: to, subject: "Subject", body: send["body"] as! String, in: file)
        if let reason = send["reason"] as? String {
            #expect(verdict == .blocked(reason), "\(to)")
        } else {
            #expect(verdict == .askOwner, "\(to)")
        }
    }
}

@Test func evidenceRuleMatches() throws {
    let gate = try #require(try json("gate.json") as? [String: Any])
    var file = gymLike(domain: "fitwerk.example")
    file.emails = (gate["evidence_emails"] as! [[String: String]]).map {
        CaseFile.Email(direction: $0["direction"] == "in" ? .incoming : .outgoing, date: .now, from: "", to: "", subject: $0["subject"]!, body: $0["body"]!)
    }
    let messages = Spec.rules.messages
    for c in gate["evidence"] as! [[String: Any]] {
        let evidence = c["evidence"] as! String
        let want: String? = switch c["result"] as? String {
        case "evidence_missing": messages.evidenceMissing
        case "evidence_unmatched": messages.evidenceUnmatched
        default: nil
        }
        #expect(Gate.checkEvidence(evidence, in: file) == want, "\(evidence)")
    }
}

private func gymLike(domain: String) -> CaseFile {
    CaseFile(
        errand: "cancel",
        createdAt: .now,
        owner: .init(name: "Lena Hoffmann", caseAddress: "case@steward.example", accountRef: "", facts: "", goal: ""),
        company: .init(name: "FitWerk", domain: domain, email: "kundenservice@\(domain)")
    )
}
