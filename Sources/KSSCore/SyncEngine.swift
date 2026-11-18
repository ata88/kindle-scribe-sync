import Foundation

/// Platform image operations (CoreGraphics on macOS, fakes in tests).
public protocol ImageTools: Sendable {
    /// Hash of the decoded pixels, so re-encoded identical pages compare equal.
    func pixelHash(_ png: Data) -> String?
    func pixelSize(_ png: Data) -> (width: Int, height: Int)?
    /// Crop a figure; implementations may tighten the box to the ink inside it.
    func cropFigure(_ png: Data, box: NormRect) -> (png: Data, box: NormRect)?
}

/// Writes a notebook into Apple Notes and returns the note's id.
public protocol NotesPublisher: Sendable {
    func publish(html: String, existingNoteID: String?, folderPath: [String]) async throws -> String
}

public struct SyncSettings: Sendable {
    public var renderSize = RenderSize()
    public var notesEnabled = true
    public var notesRootFolder = "Kindle Scribe"
    public var attachPageImages = false
    public init() {}
}

public struct SyncProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, listing, downloading, recognizing, publishing }
    public var phase: Phase
    /// Notebook title the phase works on ("" while listing).
    public var detail: String
    public var done: Int
    public var total: Int
    public var notebookID: String?
    public var pageIndex: Int?

    public init(phase: Phase, detail: String, done: Int, total: Int, notebookID: String? = nil, pageIndex: Int? = nil) {
        self.phase = phase; self.detail = detail; self.done = done; self.total = total
        self.notebookID = notebookID; self.pageIndex = pageIndex
    }

    public static let idle = SyncProgress(phase: .idle, detail: "", done: 0, total: 0)
}

public struct SyncReport: Sendable {
    public var checked = 0
    public var downloadedNotebooks: [String] = []
    public var recognizedPages = 0
    public var deferredPages = 0
    public var published: [String] = []
    public var deleted: [String] = []
    public var errors: [String] = []
}

public actor SyncEngine {
    private let store: LibraryStore
    private let source: NotebookSource
    private let recognizer: PageRecognizer
    private let images: ImageTools
    private let notes: NotesPublisher?
    private let log: EventLog
    private var settings: SyncSettings
    private let recognitionAllowed: @Sendable () -> (Bool, String)
    private let onProgress: @Sendable (SyncProgress) -> Void
    private let onChange: @Sendable (NotebookRecord) -> Void
    private let onPartialText: @Sendable (String, Int, String) -> Void
    private var running = false

    public init(store: LibraryStore, source: NotebookSource, recognizer: PageRecognizer, images: ImageTools,
                notes: NotesPublisher?, log: EventLog, settings: SyncSettings = SyncSettings(),
                recognitionAllowed: @escaping @Sendable () -> (Bool, String) = { (true, "") },
                onProgress: @escaping @Sendable (SyncProgress) -> Void = { _ in },
                onChange: @escaping @Sendable (NotebookRecord) -> Void = { _ in },
                onPartialText: @escaping @Sendable (String, Int, String) -> Void = { _, _, _ in }) {
        self.store = store; self.source = source; self.recognizer = recognizer; self.images = images
        self.notes = notes; self.log = log; self.settings = settings
        self.recognitionAllowed = recognitionAllowed; self.onProgress = onProgress; self.onChange = onChange
        self.onPartialText = onPartialText
    }

    public func update(settings: SyncSettings) { self.settings = settings }
    public var isRunning: Bool { running }

    // MARK: full pass

    public func run(force: Bool = false) async throws -> SyncReport {
        guard !running else {
            log.log(.sync, L("Abgleich läuft bereits – übersprungen"))
            return SyncReport()
        }
        running = true
        defer { running = false; onProgress(.idle) }
        var report = SyncReport()
        log.log(.sync, force ? L("Vollständiger Neuabgleich gestartet") : L("Abgleich gestartet"))

        onProgress(SyncProgress(phase: .listing, detail: "", done: 0, total: 0))
        let items = try await source.listItems()
        log.log(.amazon, L("%ld Notizbücher in der Amazon-Cloud", items.count))
        var touched = Set<String>()

        // phase 1: download changed notebooks
        for (n, item) in items.enumerated() {
            try Task.checkCancellation()
            report.checked += 1
            onProgress(SyncProgress(phase: .downloading, detail: item.title, done: n, total: items.count, notebookID: item.id))
            do {
                if try await fetch(item, force: force) {
                    touched.insert(item.id)
                    report.downloadedNotebooks.append(item.title)
                }
            } catch let e as AmazonError {
                if case .authExpired = e { throw e }
                report.errors.append("\(item.title): \(e.localizedDescription)")
                log.log(.amazon, "\(item.title): \(e.localizedDescription)", level: .error)
            }
        }

        // phase 2: recognize every pending page in one batch (model loaded once)
        let (recognized, deferred, recognizedNotebooks) = try await recognizePending(&report)
        report.recognizedPages = recognized
        report.deferredPages = deferred
        touched.formUnion(recognizedNotebooks)

        // phase 3: publish what changed
        for id in touched.sorted() {
            if let title = try await publishIfNeeded(id, report: &report) { report.published.append(title) }
        }
        // also retry notebooks whose last publish failed
        for nb in store.all() where nb.noteID == nil && nb.status == .done && notes != nil && !touched.contains(nb.id) {
            if let title = try await publishIfNeeded(nb.id, report: &report) { report.published.append(title) }
        }

        // deleted on the Scribe: keep our copy and the note, just mark it
        let remote = Set(items.map(\.id))
        for var nb in store.all() where !remote.contains(nb.id) {
            nb.status = .deleted
            try store.save(nb)
            onChange(nb)
            report.deleted.append(nb.title)
            log.log(.sync, L("„%@“ existiert nicht mehr auf dem Scribe (Kopie und Notiz bleiben erhalten)", nb.title))
        }

        log.log(.sync, L("Abgleich fertig: %ld geprüft, %ld geladen, %ld Seiten erkannt", report.checked,
                         report.downloadedNotebooks.count, report.recognizedPages)
                + (report.deferredPages > 0 ? L(", %ld zurückgestellt", report.deferredPages) : "")
                + (report.errors.isEmpty ? "" : L(", %ld Fehler", report.errors.count)),
                level: report.errors.isEmpty ? .info : .warning)
        return report
    }

    /// Download a notebook if it changed. Returns true if anything changed.
    private func fetch(_ item: RemoteItem, force: Bool) async throws -> Bool {
        var nb = store.notebook(item.id) ?? NotebookRecord(id: item.id, title: item.title, folderPath: item.folderPath)
        let renamed = nb.title != item.title || nb.folderPath != item.folderPath
        nb.title = item.title
        nb.folderPath = item.folderPath
        // images are complete locally (pages may still wait for recognition – that is fine)
        let settled = !nb.modificationTime.isEmpty && ![.new, .downloading, .error].contains(nb.status)

        if !force, settled, let hint = item.modifiedHint, hint == nb.modificationTime {
            if renamed { try store.save(nb); onChange(nb) }
            return renamed
        }
        let meta = try await source.openNotebook(item.id)
        let mtime = item.modifiedHint ?? meta.modificationTime
        if !force, settled, mtime == nb.modificationTime, meta.totalPages == nb.pages.count {
            if renamed { try store.save(nb); onChange(nb) }
            return renamed
        }

        log.log(.amazon, L("„%@“: %ld Seite(n) werden geladen", item.title, meta.totalPages))
        nb.status = .downloading
        onChange(nb)
        let pngs = try await source.renderNotebook(item.id, meta: meta, size: settings.renderSize)

        let old = nb.pages
        let byHash = Dictionary(old.filter { $0.status == .recognized }.map { ($0.imageHash, $0) },
                                uniquingKeysWith: { a, _ in a })
        var pages: [PageRecord] = []
        var newOrChanged = 0
        for (i, png) in pngs.enumerated() {
            let hash = images.pixelHash(png) ?? String(png.hashValue)
            let name = String(format: "page-%04d.png", i + 1)
            if !force, i < old.count, old[i].imageHash == hash, old[i].status == .recognized {
                pages.append(old[i]); continue
            }
            let file = try store.writeImage(png, notebookID: item.id, name: name)
            if !force, var moved = byHash[hash] {
                // same page content moved to another position: reuse transcript + corrections
                moved.index = i
                moved.imageFile = file
                moved.figures = try relocateFigures(moved.figures, png: png, notebookID: item.id, page: i)
                pages.append(moved)
                continue
            }
            newOrChanged += 1
            if i < old.count, old[i].ocrText != nil {
                // the page was extended/changed: keep old text and corrections for the merge
                var p = old[i]
                p.imageHash = hash; p.imageFile = file; p.status = .pending; p.error = nil
                pages.append(p)
            } else {
                pages.append(PageRecord(index: i, imageHash: hash, imageFile: file))
            }
        }
        for gone in old where gone.index >= pngs.count {
            store.removeImage(gone.imageFile)
            gone.figures.compactMap(\.imageFile).forEach(store.removeImage)
        }
        nb.pages = pages
        nb.modificationTime = mtime
        nb.status = pages.contains { $0.status != .recognized } ? .recognizing : .done
        nb.error = nil
        nb.syncedAt = Date()
        try store.save(nb)
        onChange(nb)
        log.log(.amazon, L("„%@“: %ld neue oder geänderte Seite(n)", item.title, newOrChanged))
        return true
    }

    private func relocateFigures(_ figures: [Figure], png: Data, notebookID: String, page: Int) throws -> [Figure] {
        try figures.map { f in
            var f = f
            if let crop = images.cropFigure(png, box: f.box) {
                f.imageFile = try store.writeImage(crop.png, notebookID: notebookID,
                                                   name: String(format: "fig-%04d-%d.png", page + 1, f.id))
            }
            return f
        }
    }

    // MARK: recognition

    private func recognizePending(_ report: inout SyncReport) async throws -> (Int, Int, Set<String>) {
        let queue = store.all().flatMap { nb in nb.pages.filter { $0.status != .recognized }.map { (nb.id, $0.index) } }
        guard !queue.isEmpty else { return (0, 0, []) }
        let (allowed, reason) = recognitionAllowed()
        guard allowed else {
            log.log(.power, L("%ld Seite(n) warten auf Texterkennung: %@", queue.count, reason))
            return (0, queue.count, [])
        }

        log.log(.model, L("Lade KI-Modell %@ für %ld Seite(n)", recognizer.modelName, queue.count))
        let started = Date()
        do {
            try await recognizer.prepare()
        } catch {
            log.log(.model, L("Modell konnte nicht geladen werden: %@", error.localizedDescription), level: .error)
            report.errors.append(L("KI-Modell: %@", error.localizedDescription))
            return (0, queue.count, [])
        }
        var done = 0
        var notebooks = Set<String>()
        do {
            for (n, (nbID, idx)) in queue.enumerated() {
                try Task.checkCancellation()
                guard var nb = store.notebook(nbID), let pi = nb.pages.firstIndex(where: { $0.index == idx }) else { continue }
                onProgress(SyncProgress(phase: .recognizing, detail: nb.title, done: n, total: queue.count, notebookID: nbID, pageIndex: idx))
                let ok = await recognize(&nb, pageIndex: pi)
                if ok { done += 1 } else { report.errors.append(L("„%@“ Seite %ld nicht erkannt", nb.title, idx + 1)) }
                if !nb.pages.contains(where: { $0.status == .pending }) {
                    nb.status = nb.pages.contains { $0.status == .failed } ? .partial : .done
                }
                try store.save(nb)
                onChange(nb)
                notebooks.insert(nbID)
            }
        } catch {
            await recognizer.release()
            log.log(.model, L("Modell entladen (abgebrochen)"))
            throw error
        }
        await recognizer.release()
        let secs = Int(Date().timeIntervalSince(started))
        log.log(.model, L("%ld Seite(n) in %ld s erkannt – Modell aus dem Arbeitsspeicher entfernt", done, secs))
        return (done, 0, notebooks)
    }

    private func recognize(_ nb: inout NotebookRecord, pageIndex pi: Int) async -> Bool {
        var page = nb.pages[pi]
        guard let png = store.readImage(page.imageFile) else {
            page.status = .failed; page.error = L("Seitenbild fehlt"); nb.pages[pi] = page
            return false
        }
        let previousTail = pi > 0 ? String(nb.pages[pi - 1].text.suffix(300)) : ""
        let earlier = page.ocrText == nil ? nil : page.text
        let ctx = RecognitionContext(notebookTitle: nb.title, pageNumber: page.index + 1, pageCount: nb.pages.count,
                                     previousPageTail: previousTail, earlierText: earlier)
        do {
            let nbID = nb.id, pageIdx = page.index, partial = onPartialText
            let result = try await recognizer.recognize(png: png, context: ctx) { text in partial(nbID, pageIdx, text) }
            // keep manual corrections: merge them onto the new reading
            if let user = page.userText, let base = page.ocrText {
                let merged = Merge.threeWay(base: base, ours: user, theirs: result.markdown)
                page.userText = merged == result.markdown ? nil : merged
                log.log(.sync, L("„%@“ Seite %ld: manuelle Korrekturen übernommen", nb.title, page.index + 1))
            }
            page.ocrText = result.markdown
            // old figure crops of this page are replaced
            page.figures.compactMap(\.imageFile).forEach(store.removeImage)
            page.figures = result.figures.map { f in
                var f = f
                if let crop = images.cropFigure(png, box: f.box),
                   let file = try? store.writeImage(crop.png, notebookID: nb.id,
                                                    name: String(format: "fig-%04d-%d.png", page.index + 1, f.id)) {
                    f.box = crop.box
                    f.imageFile = file
                }
                return f
            }
            page.status = .recognized
            page.error = nil
            page.model = recognizer.modelName
            page.recognizedAt = Date()
            nb.pages[pi] = page
            return true
        } catch {
            page.status = .failed
            page.error = error.localizedDescription
            nb.pages[pi] = page
            log.log(.model, L("„%@“ Seite %ld: %@", nb.title, page.index + 1, error.localizedDescription), level: .error)
            return false
        }
    }

    // MARK: Apple Notes

    /// Publish if content or folder changed. Returns the title when written.
    private func publishIfNeeded(_ id: String, report: inout SyncReport) async throws -> String? {
        guard settings.notesEnabled, let notes, var nb = store.notebook(id), nb.status != .deleted else { return nil }
        guard !nb.pages.isEmpty, !nb.pages.contains(where: { $0.status == .pending }) else { return nil }
        let folder = [settings.notesRootFolder] + nb.folderPath
        let folderKey = folder.joined(separator: "/")
        let out = NotesRenderer.render(nb, figurePNG: { _, fig in fig.imageFile.flatMap(self.store.readImage) },
                                       pagePNG: settings.attachPageImages ? { self.store.readImage($0.imageFile) } : nil)
        if nb.noteID != nil, nb.publishedHash == out.contentHash, nb.noteFolder == folderKey { return nil }
        onProgress(SyncProgress(phase: .publishing, detail: nb.title, done: 0, total: 1))
        do {
            let noteID = try await notes.publish(html: out.html, existingNoteID: nb.noteID, folderPath: folder)
            let verb = nb.noteID == nil ? L("angelegt") : (noteID == nb.noteID ? L("aktualisiert") : L("neu angelegt (alte Notiz nicht mehr vorhanden)"))
            nb.noteID = noteID
            nb.noteFolder = folderKey
            nb.publishedHash = out.contentHash
            try store.save(nb)
            onChange(nb)
            log.log(.notes, L("„%@“ in Notizen %@", nb.title, verb))
            return nb.title
        } catch {
            report.errors.append(L("Notizen „%@“: %@", nb.title, error.localizedDescription))
            log.log(.notes, L("„%@“: %@", nb.title, error.localizedDescription), level: .error)
            return nil
        }
    }

    // MARK: user actions

    /// Save a manual correction of a page and push it to Apple Notes.
    public func saveCorrection(notebookID: String, pageIndex: Int, text: String) async throws {
        guard var nb = store.notebook(notebookID), let pi = nb.pages.firstIndex(where: { $0.index == pageIndex }) else { return }
        nb.pages[pi].userText = (text == nb.pages[pi].ocrText) ? nil : text
        try store.save(nb)
        onChange(nb)
        log.log(.sync, L("„%@“ Seite %ld: Korrektur gespeichert", nb.title, pageIndex + 1))
        var report = SyncReport()
        _ = try await publishIfNeeded(notebookID, report: &report)
        if let e = report.errors.first { throw NSError(domain: "Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
    }

    /// Discard the recognition of one page and read it again on the next pass.
    public func requeue(notebookID: String, pageIndex: Int) throws {
        guard var nb = store.notebook(notebookID), let pi = nb.pages.firstIndex(where: { $0.index == pageIndex }) else { return }
        nb.pages[pi].status = .pending
        nb.status = .recognizing
        try store.save(nb)
        onChange(nb)
    }

    public func republish(notebookID: String) async throws {
        guard var nb = store.notebook(notebookID) else { return }
        nb.publishedHash = nil
        try store.save(nb)
        var report = SyncReport()
        _ = try await publishIfNeeded(notebookID, report: &report)
    }
}
