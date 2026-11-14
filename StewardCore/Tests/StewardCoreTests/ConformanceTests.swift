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
    #expect(Spec.tools(for: .brief).map(\.name) == spec.compactMap { $0["name"] as? String })
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

// MARK: Brief and reviewer

private struct BriefCase: Decodable, CustomTestStringConvertible {
    struct Company: Decodable { var name, email: String }
    struct Instruction: Decodable { var day, text: String }
    struct Line: Decodable { var day, kind, detail: String }
    struct Mail: Decodable { var direction, day, from, to, subject, body: String }
    var name, today, errand, goal, notes, new: String
    var company: Company
    var instructions: [Instruction]
    var timeline: [Line]
    var emails: [Mail]
    var testDescription: String { name }
}

private struct BriefFixture: Decodable {
    struct Owner: Decodable { var name, goal: String }
    struct Verdict: Decodable { var reply: String; var reject: String? }
    struct Notes: Decodable { var text, saved: String; var cut: Bool }
    var briefs: [BriefCase]
    var review: Owner
    var verdicts: [Verdict]
    var notes: [Notes]
}

private let briefFixture: BriefFixture? = try? JSONDecoder().decode(BriefFixture.self, from: Data(contentsOf: cases.appending(path: "briefs.json")))

private func utcDay(_ iso: String) -> Date { try! Date(iso + "T12:00:00Z", strategy: .iso8601) }

/// Built as a real case file, so the test covers the app's own path from case to brief.
@Test(arguments: briefFixture?.briefs ?? [])
private func briefMatches(_ c: BriefCase) throws {
    let utc = TimeZone(identifier: "UTC")!
    var file = CaseFile(
        errand: c.errand,
        createdAt: utcDay(c.today),
        owner: .init(name: "Owner", caseAddress: "case@steward.example", accountRef: "", facts: "", goal: c.goal),
        company: .init(name: c.company.name, domain: "example", email: c.company.email)
    )
    file.standingInstructions = c.instructions.map { .init(date: utcDay($0.day), text: $0.text) }
    file.events = c.timeline.map { .init(date: utcDay($0.day), kind: $0.kind, detail: $0.detail) }
    file.emails = c.emails.map {
        .init(direction: $0.direction == "in" ? .incoming : .outgoing, date: utcDay($0.day), from: $0.from, to: $0.to, subject: $0.subject, body: $0.body)
    }
    file.notes = c.notes
    let expected = try String(contentsOf: cases.appending(path: "expected/\(c.name).txt"), encoding: .utf8)
    #expect(Brief.render(file, today: utcDay(c.today), new: c.new, timeZone: utc) == expected)
}

@Test func briefCasesWereFound() {
    #expect((briefFixture?.briefs.count ?? 0) >= 2)
}

@Test func reviewPromptMatches() throws {
    let fixture = try #require(briefFixture)
    var file = gymLike(domain: "fitwerk.example")
    file.owner.name = fixture.review.name
    file.owner.goal = fixture.review.goal
    let expected = try String(contentsOf: cases.appending(path: "expected/review_system.txt"), encoding: .utf8)
    #expect(Review.system(for: file) == expected)
}

@Test func reviewVerdictsMatch() throws {
    for v in try #require(briefFixture).verdicts {
        #expect(Review.verdict(v.reply) == (v.reject.map(Review.Verdict.reject) ?? .accept), "\(v.reply)")
    }
}

@Test func notesCapMatches() throws {
    for n in try #require(briefFixture).notes {
        let (saved, cut) = Brief.capNotes(n.text)
        #expect(saved == n.saved)
        #expect(cut == n.cut)
    }
}

@Test func toolsPerContext() {
    #expect(Spec.tools(for: .transcript).map(\.name) == ["send_email", "wait_for_reply", "ask_owner", "close_case"])
    #expect(Spec.tools(for: .brief).map(\.name) == ["send_email", "wait_for_reply", "ask_owner", "note", "close_case"])
}
