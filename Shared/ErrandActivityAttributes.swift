import ActivityKit
import Foundation

nonisolated struct ErrandActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        nonisolated enum Phase: String, Codable, Hashable {
            case working, needsYou, done
        }

        var phase: Phase
        var step: String
        var number: Int
        var total: Int
    }

    let errandTitle: String
}
