import Foundation

/// Where the feed's files live: the app group container, so the Share extension
/// can drop items into the same inbox the app reads. Backed up with the phone.
nonisolated enum FeedFolder {
    static let appGroup = "group.com.steward.app"

    /// Falls back to this process's documents if the app group isn't signed in,
    /// in which case the Share extension and the app can't see each other's files.
    static var url: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container.appending(path: "Feed", directoryHint: .isDirectory)
        }
        return URL.documentsDirectory.appending(path: "Feed", directoryHint: .isDirectory)
    }
}
