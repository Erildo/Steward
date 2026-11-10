import Foundation
import StewardCore

/// Where the app keeps its cases: one readable JSON file each, in the app's
/// documents (backed up to the owner's own iCloud). Not wired to chat yet;
/// see docs/adr/0001-phone-is-the-brain.md for the plan.
enum CaseService {
    static let store = CaseStore(folder: URL.documentsDirectory.appending(path: "Cases"))
}
