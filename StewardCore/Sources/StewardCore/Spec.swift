import Foundation

/// The agent spec shared with the Stage 0 harness, loaded from `Spec/`:
///
/// - `system.txt`, `playbook.txt`, `no_playbook.txt`: prompt templates with
///   `{name}` placeholders and no other braces.
/// - `brief.txt`: the case brief the agent sees at each wake in brief mode.
/// - `review.txt`: the reviewer's instructions before a "done" is accepted.
/// - `tools.json`: the tools as the model sees them, as JSON Schema. A tool
///   with `"context": "brief"` is offered only in brief mode.
/// - `rules.json`: numbers and wording for the gate and the loop.
///
/// `harness/src/steward_harness/spec.py` loads the same files, and
/// `Tests/Conformance` holds cases both must render and judge identically.
/// Edit the files, never the code: nothing the model is told or held to is
/// written in Swift, so a Stage 0 result describes this code. Any change to them
/// changes the harness fingerprint, which marks earlier results out of date.
enum Spec {
    struct Rules: Decodable {
        struct Days: Decodable { var min: Int; var max: Int }
        struct Messages: Decodable {
            var wrongRecipient: String
            var privateDetail: String
            var evidenceMissing: String
            var evidenceUnmatched: String
            var evidenceUnsigned: String
            var reviewRejected: String
            var notesSaved: String
            var notesCut: String
        }
        struct BriefRules: Decodable {
            var fullEmails: Int
            var olderEmailChars: Int
            var timelineKinds: [String]
            var nothing: String
        }
        struct Instructions: Decodable {
            var answer: String
            var declined: String
            var reopened: String
        }
        /// How each kind of wake is told to the agent in brief mode.
        struct New: Decodable {
            var start, resume, approved, approvedEdited, declined, answer, mail, timer, reopened, review: String
        }
        struct OutcomeCheck: Decodable {
            var minDays: Int
            var maxDays: Int
            var defaultDays: Int
            var defaultQuestion: String
        }
        var minimumEvidence: Int
        var waitDays: Days
        var notesMaxWords: Int
        var continuePrompt: String
        var messages: Messages
        var brief: BriefRules
        var instructions: Instructions
        var new: New
        var outcomeCheck: OutcomeCheck
    }

    private struct Tool: Decodable {
        var name: String
        var context: String?
        var description: String
        var parameters: JSONValue
    }

    static let system = text("system.txt")
    static let playbook = text("playbook.txt")
    static let noPlaybook = text("no_playbook.txt")
    static let brief = text("brief.txt")
    static let review = text("review.txt")
    static let rules: Rules = decode("rules.json")
    private static let allTools: [Tool] = decode("tools.json")

    /// The tools offered in a context: transcript replay gets the core tools,
    /// brief mode adds the ones marked `"context": "brief"` (the notes).
    static func tools(for context: AgentContext) -> [ToolSpec] {
        allTools
            .filter { $0.context == nil || $0.context == context.rawValue }
            .map { ToolSpec(name: $0.name, description: $0.description, parameters: $0.parameters) }
    }

    /// Fills `{key}` placeholders in one pass, so a value that itself contains
    /// braces (a playbook, an email) is never read as a placeholder.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let key = String(rest[rest.index(after: open)..<close])
            guard let value = values[key] else {
                preconditionFailure("Spec template needs a value for {\(key)}")
            }
            out += value
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static let folder: URL = {
        guard let url = Bundle.module.url(forResource: "Spec", withExtension: nil) else {
            preconditionFailure("The Spec folder is missing from the StewardCore bundle.")
        }
        return url
    }()

    private static func data(_ name: String) -> Data {
        do { return try Data(contentsOf: folder.appending(path: name)) }
        catch { preconditionFailure("Can't read Spec/\(name): \(error)") }
    }

    /// The file's text, less the one trailing newline every file ends with.
    private static func text(_ name: String) -> String {
        let text = String(decoding: data(name), as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    private static func decode<T: Decodable>(_ name: String) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data(name)) }
        catch { preconditionFailure("Spec/\(name) doesn't match what the core expects: \(error)") }
    }
}
