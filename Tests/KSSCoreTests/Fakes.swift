import Foundation
@testable import KSSCore

/// A "page image" in tests is just UTF-8 text; the hash is the text itself.
func page(_ s: String) -> Data { Data(s.utf8) }

final class FakeSource: NotebookSource, @unchecked Sendable {
    struct NB { var title: String; var folder: [String]; var mtime: Int; var pages: [Data] }
    private let lock = NSLock()
    var notebooks: [String: NB] = [:]
    var renders = 0
    var opens = 0
    var authExpired = false

    func set(_ id: String, _ nb: NB) { lock.withLock { notebooks[id] = nb } }
    func mutate(_ id: String, _ f: (inout NB) -> Void) { lock.withLock { f(&notebooks[id]!) } }
    func remove(_ id: String) { lock.withLock { notebooks[id] = nil } }

    func listItems() async throws -> [RemoteItem] {
        if authExpired { throw AmazonError.authExpired("test") }
        return lock.withLock {
            notebooks.sorted { $0.key < $1.key }.map { RemoteItem(id: $0.key, title: $0.value.title, folderPath: $0.value.folder) }
        }
    }

    func openNotebook(_ id: String) async throws -> RemoteNotebookMeta {
        let nb = lock.withLock { opens += 1; return notebooks[id]! }
        return RemoteNotebookMeta(title: nb.title, totalPages: nb.pages.count, modificationTime: "\(nb.mtime)", renderingToken: "t")
    }

    func renderNotebook(_ id: String, meta: RemoteNotebookMeta, size: RenderSize) async throws -> [Data] {
        lock.withLock { renders += 1; return notebooks[id]!.pages }
    }
}

final class FakeRecognizer: PageRecognizer, @unchecked Sendable {
    let modelName = "fake-model"
    private let lock = NSLock()
    var prepares = 0, releases = 0
    var calls: [String] = []
    var contexts: [RecognitionContext] = []
    var failOn: Set<String> = []
    var loaded = false
    /// page content -> model output; default echoes "Text: <content>"
    var outputs: [String: String] = [:]

    func prepare() async throws { lock.withLock { prepares += 1; loaded = true } }
    func release() async { lock.withLock { releases += 1; loaded = false } }

    func recognize(png: Data, context: RecognitionContext,
                   onPartial: @escaping @Sendable (String) -> Void) async throws -> RecognitionResult {
        onPartial("…")
        let content = String(decoding: png, as: UTF8.self)
        let (fail, out) = lock.withLock { () -> (Bool, String?) in
            precondition(loaded, "recognize called without prepare")
            calls.append(content); contexts.append(context)
            return (failOn.contains(content), outputs[content])
        }
        if fail { throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
        return RecognitionPrompt.parse(out ?? "<text>\nText: \(content)\n</text>\n<grafiken>[]</grafiken>")
    }
}

struct FakeImages: ImageTools {
    func pixelHash(_ png: Data) -> String? { String(decoding: png, as: UTF8.self) }
    func pixelSize(_ png: Data) -> (width: Int, height: Int)? { (1000, 1400) }
    func cropFigure(_ png: Data, box: NormRect) -> (png: Data, box: NormRect)? {
        (Data("crop:\(box.x0)".utf8), box)
    }
}

final class FakeNotes: NotesPublisher, @unchecked Sendable {
    private let lock = NSLock()
    var notes: [String: (html: String, folder: [String])] = [:]
    var writes = 0
    var created = 0
    var lastImages: [URL] = []

    func publish(html: String, images: [URL], existingNoteID: String?, folderPath: [String]) async throws -> String {
        lock.withLock {
            writes += 1
            lastImages = images
            if let id = existingNoteID, notes[id] != nil {
                notes[id] = (html, folderPath)
                return id
            }
            created += 1
            let id = "x-coredata://note/\(created)"
            notes[id] = (html, folderPath)
            return id
        }
    }
}
