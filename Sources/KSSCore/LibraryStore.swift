import Foundation

/// File-based library: one JSON file per notebook plus page and figure PNGs.
///
///     <root>/notebooks/<safe-id>.json
///     <root>/pages/<safe-id>/page-0001.png
///     <root>/pages/<safe-id>/fig-0001-1.png
public final class LibraryStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notebooks"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pages"),
                                                withIntermediateDirectories: true)
    }

    public static func safeID(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private func notebookURL(_ id: String) -> URL {
        root.appendingPathComponent("notebooks").appendingPathComponent(Self.safeID(id) + ".json")
    }

    public func url(for relativeFile: String) -> URL {
        root.appendingPathComponent("pages").appendingPathComponent(relativeFile)
    }

    public func all(includeDeleted: Bool = false) -> [NotebookRecord] {
        lock.lock(); defer { lock.unlock() }
        let dir = root.appendingPathComponent("notebooks")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(NotebookRecord.self, from: Data(contentsOf: $0)) }
            .filter { includeDeleted || $0.status != .deleted }
            .sorted { ($0.folderPath.joined(separator: "/"), $0.title.lowercased())
                    < ($1.folderPath.joined(separator: "/"), $1.title.lowercased()) }
    }

    public func notebook(_ id: String) -> NotebookRecord? {
        lock.lock(); defer { lock.unlock() }
        return try? decoder.decode(NotebookRecord.self, from: Data(contentsOf: notebookURL(id)))
    }

    public func save(_ nb: NotebookRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try encoder.encode(nb)
        try data.write(to: notebookURL(nb.id), options: .atomic)
    }

    /// Write a page/figure image; returns the relative file name.
    @discardableResult
    public func writeImage(_ data: Data, notebookID: String, name: String) throws -> String {
        let rel = Self.safeID(notebookID) + "/" + name
        let url = url(for: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return rel
    }

    public func readImage(_ relativeFile: String) -> Data? {
        try? Data(contentsOf: url(for: relativeFile))
    }

    public func removeImage(_ relativeFile: String) {
        try? FileManager.default.removeItem(at: url(for: relativeFile))
    }
}
