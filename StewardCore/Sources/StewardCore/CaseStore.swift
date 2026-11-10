import Foundation

/// Keeps each case as one readable JSON file in a folder the owner controls
/// (in the app: the app's documents, backed up to their own iCloud).
public struct CaseStore: Sendable {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func save(_ file: CaseFile) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url(for: file.id), options: [.atomic, .completeFileProtection])
    }

    public func load(_ id: UUID) throws -> CaseFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaseFile.self, from: Data(contentsOf: url(for: id)))
    }

    public func all() throws -> [CaseFile] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .map(load)
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }
}
