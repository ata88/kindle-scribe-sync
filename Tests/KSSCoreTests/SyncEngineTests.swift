import Foundation
import Testing
@testable import KSSCore

struct Harness {
    let dir: URL
    let store: LibraryStore
    let source = FakeSource()
    let recognizer = FakeRecognizer()
    let notes = FakeNotes()
    let log = EventLog()
    var allowed = true

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kss-\(UUID().uuidString)")
        store = try LibraryStore(root: dir)
    }

    func engine(allowed: Bool = true) -> SyncEngine {
        SyncEngine(store: store, source: source, recognizer: recognizer, images: FakeImages(), notes: notes, log: log,
                   recognitionAllowed: { (allowed, "Akkubetrieb") })
    }
}

@Suite struct SyncEngineTests {
    @Test func fullFlowLoadsModelOnlyWhenNeeded() async throws {
        let h = try Harness()
        h.source.set("a", .init(title: "Meeting", folder: ["Arbeit"], mtime: 1, pages: [page("p1"), page("p2")]))
        let r1 = try await h.engine().run()
        #expect(r1.recognizedPages == 2)
        #expect(h.recognizer.prepares == 1 && h.recognizer.releases == 1)
        #expect(h.notes.created == 1)
        let note = try #require(h.notes.notes.values.first)
        #expect(note.folder == ["Kindle Scribe", "Arbeit"])
        #expect(note.html.contains("Text: p2"))

        // nothing changed -> no render, no model load, no Notes write
        let renders = h.source.renders
        _ = try await h.engine().run()
        #expect(h.source.renders == renders)
        #expect(h.recognizer.prepares == 1)
        #expect(h.notes.writes == 1)
    }

    @Test func extendedPageUpdatesSameNoteAndKeepsCorrection() async throws {
        let h = try Harness()
        h.recognizer.outputs["v1"] = "<text>Termin mit Muller</text><grafiken>[]</grafiken>"
        h.recognizer.outputs["v2"] = "<text>Termin mit Muller\nDanach Sport</text><grafiken>[]</grafiken>"
        h.source.set("a", .init(title: "Tag", folder: [], mtime: 1, pages: [page("v1")]))
        let engine = h.engine()
        _ = try await engine.run()
        try await engine.saveCorrection(notebookID: "a", pageIndex: 0, text: "Termin mit Müller")
        #expect(h.notes.writes == 2 && h.notes.created == 1)

        // user writes more on the same page
        h.source.mutate("a") { $0.pages = [page("v2")]; $0.mtime = 2 }
        _ = try await engine.run()
        let nb = try #require(h.store.notebook("a"))
        #expect(nb.pages[0].text == "Termin mit Müller\nDanach Sport")
        #expect(nb.pages[0].ocrText == "Termin mit Muller\nDanach Sport")
        #expect(h.notes.created == 1, "must update the existing note, not create a new one")
        #expect(h.notes.notes.values.first!.html.contains("Termin mit Müller"))
        // the model was told what the page said before
        #expect(h.recognizer.contexts.last?.earlierText == "Termin mit Müller")
    }

    @Test func correctionMatchingOCRClearsUserText() async throws {
        let h = try Harness()
        h.source.set("a", .init(title: "T", folder: [], mtime: 1, pages: [page("x")]))
        let engine = h.engine()
        _ = try await engine.run()
        try await engine.saveCorrection(notebookID: "a", pageIndex: 0, text: "Text: x")
        #expect(h.store.notebook("a")!.pages[0].userText == nil)
    }

    @Test func insertedPageOnlyRecognizesNewOne() async throws {
        let h = try Harness()
        h.source.set("a", .init(title: "T", folder: [], mtime: 1, pages: [page("a"), page("b")]))
        _ = try await h.engine().run()
        h.source.mutate("a") { $0.pages.insert(page("new"), at: 0); $0.mtime = 2 }
        _ = try await h.engine().run()
        #expect(h.recognizer.calls == ["a", "b", "new"])
        #expect(h.store.notebook("a")!.pages.map(\.text) == ["Text: new", "Text: a", "Text: b"])
    }

    @Test func recognitionDeferredOnBatteryPolicy() async throws {
        let h = try Harness()
        h.source.set("a", .init(title: "T", folder: [], mtime: 1, pages: [page("a")]))
        let r = try await h.engine(allowed: false).run()
        #expect(r.deferredPages == 1)
        #expect(h.recognizer.prepares == 0)
        #expect(h.notes.writes == 0, "nothing is published while pages wait")
        // later on AC power the waiting page is recognized without re-downloading
        let renders = h.source.renders
        let r2 = try await h.engine(allowed: true).run()
        #expect(r2.recognizedPages == 1 && h.source.renders == renders)
        #expect(h.notes.writes == 1)
    }

    @Test func failedPageIsRetriedAndModelAlwaysReleased() async throws {
        let h = try Harness()
        h.recognizer.failOn = ["b"]
        h.source.set("a", .init(title: "T", folder: [], mtime: 1, pages: [page("a"), page("b")]))
        let r = try await h.engine().run()
        #expect(!r.errors.isEmpty)
        #expect(h.recognizer.releases == h.recognizer.prepares)
        #expect(h.store.notebook("a")!.status == .partial)
        h.recognizer.failOn = []
        _ = try await h.engine().run()
        #expect(h.store.notebook("a")!.status == .done)
        #expect(h.recognizer.calls.filter { $0 == "b" }.count == 2)
    }

    @Test func figuresAreCroppedAndEmbedded() async throws {
        let h = try Harness()
        h.recognizer.outputs["sketch"] = """
        <text>
        Idee
        [[Grafik 1]]
        </text>
        <grafiken>[{"id": 1, "box": [100, 200, 600, 700]}]</grafiken>
        """
        h.source.set("a", .init(title: "T", folder: [], mtime: 1, pages: [page("sketch")]))
        _ = try await h.engine().run()
        let p = h.store.notebook("a")!.pages[0]
        #expect(p.figures.count == 1 && p.figures[0].imageFile != nil)
        #expect(h.notes.notes.values.first!.html.contains("<img src=\"data:image/png;base64,"))
        #expect(!h.notes.notes.values.first!.html.contains("Skizze"))
    }

    @Test func authErrorPropagates() async throws {
        let h = try Harness()
        h.source.authExpired = true
        await #expect(throws: AmazonError.self) { try await h.engine().run() }
    }

    @Test func deletedNotebookKeepsData() async throws {
        let h = try Harness()
        h.source.set("a", .init(title: "Weg", folder: [], mtime: 1, pages: [page("a")]))
        _ = try await h.engine().run()
        h.source.remove("a")
        let r = try await h.engine().run()
        #expect(r.deleted == ["Weg"])
        #expect(h.store.notebook("a")?.status == .deleted)
        #expect(h.notes.notes.count == 1)
    }

    @Test func renameMovesNoteWithoutRecognition() async throws {
        let h = try Harness()
        h.source.set("a", .init(title: "Alt", folder: [], mtime: 1, pages: [page("a")]))
        _ = try await h.engine().run()
        h.source.mutate("a") { $0.title = "Neu"; $0.folder = ["Privat"] }
        _ = try await h.engine().run()
        #expect(h.recognizer.calls.count == 1)
        #expect(h.notes.created == 1)
        #expect(h.notes.notes.values.first!.folder == ["Kindle Scribe", "Privat"])
        #expect(h.notes.notes.values.first!.html.contains("Neu"))
    }
}
