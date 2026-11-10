import Foundation

/// Keeps the taste file, the current feed and the Share inbox as readable JSON in
/// a folder the owner controls. The Share extension only ever writes new files
/// into `inbox/`, so it never races the app over `taste.json`.
public struct FeedStore: Sendable {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var tasteURL: URL { folder.appending(path: "taste.json") }
    public var feedURL: URL { folder.appending(path: "feed.json") }
    public var inboxURL: URL { folder.appending(path: "inbox", directoryHint: .isDirectory) }

    public func loadTaste() throws -> TasteProfile {
        try read(TasteProfile.self, at: tasteURL) ?? TasteProfile()
    }

    public func save(_ taste: TasteProfile) throws {
        try write(taste, to: tasteURL)
    }

    public func loadFeed() throws -> FeedBatch? {
        try read(FeedBatch.self, at: feedURL)
    }

    public func save(_ feed: FeedBatch) throws {
        try write(feed, to: feedURL)
    }

    /// Called by the Share extension: drops one item into the inbox.
    public func enqueue(_ item: SharedItem) throws {
        try write(item, to: inboxURL.appending(path: "\(item.id.uuidString).json"))
    }

    /// Moves everything in the inbox into the taste file. Returns the items moved.
    @discardableResult
    public func mergeInbox() throws -> [SharedItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inboxURL.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let items = files.compactMap { try? read(SharedItem.self, at: $0) }
        guard !items.isEmpty else { return [] }
        var taste = try loadTaste()
        taste.add(shared: items)
        try save(taste)
        for file in files { try? fm.removeItem(at: file) }
        return items
    }

    /// Removes the taste file, the feed and the inbox.
    public func deleteEverything() throws {
        let fm = FileManager.default
        for url in [tasteURL, feedURL, inboxURL] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: Files

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Not `.completeFileProtection`: the Share extension may write while the
        // phone is locked, and the app may read just after unlock.
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
