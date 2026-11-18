import Foundation

/// In-memory activity log for the diagnostics window (and a small file log).
public final class EventLog: @unchecked Sendable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case sync = "Sync", amazon = "Amazon", model = "KI-Modell", notes = "Apple Notes",
             power = "Energie", app = "App", update = "Updates"
    }
    public enum Level: String, Codable, Sendable { case info, warning, error }

    public struct Event: Identifiable, Codable, Sendable, Hashable {
        public var id = UUID()
        public var date: Date
        public var category: Category
        public var level: Level
        public var message: String
    }

    private let lock = NSLock()
    private var buffer: [Event] = []
    private let capacity: Int
    private let fileURL: URL?
    private var observers: [UUID: @Sendable (Event) -> Void] = [:]

    public init(capacity: Int = 2000, fileURL: URL? = nil) {
        self.capacity = capacity
        self.fileURL = fileURL
    }

    public var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public func log(_ category: Category, _ message: String, level: Level = .info) {
        let e = Event(date: Date(), category: category, level: level, message: message)
        lock.lock()
        buffer.append(e)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let obs = Array(observers.values)
        lock.unlock()
        appendToFile(e)
        obs.forEach { $0(e) }
    }

    @discardableResult
    public func observe(_ fn: @escaping @Sendable (Event) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = fn; lock.unlock()
        return id
    }

    public func text() -> String {
        let f = ISO8601DateFormatter()
        return events.map { "\(f.string(from: $0.date)) [\($0.level.rawValue)] \($0.category.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }

    private func appendToFile(_ e: Event) {
        guard let fileURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: e.date)) [\(e.level.rawValue)] \(e.category.rawValue): \(e.message)\n"
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            // keep the file small: trim when > 2 MB
            if let size = try? h.offset(), size > 2_000_000 {
                try? h.close()
                if let data = try? Data(contentsOf: fileURL) {
                    try? data.suffix(1_000_000).write(to: fileURL)
                }
            }
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }
}
