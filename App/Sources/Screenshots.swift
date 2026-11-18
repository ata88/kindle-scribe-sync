import AppKit
import KSSCore
import SwiftUI

extension Notification.Name {
    static let openDiagnosticsWindow = Notification.Name("ScribeSync.openDiagnostics")
}

/// `Scribe Sync --screenshots DIR` (with SCRIBE_SYNC_HOME pointing to an empty
/// folder): fills a demo library, opens the windows, saves PNGs and quits.
/// CI uses this so the UI can be reviewed without a Mac at hand.
@MainActor
enum Screenshots {
    static var requestedDirectory: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--screenshots"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    }

    static func run(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        makeDemoLibrary(model.store)
        model.reloadNotebooks()
        model.selectedNotebookID = "demo-kickoff"
        model.sidebar = .all
        await pause(1.5)

        guard let main = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("main") }) else {
            print("no main window"); exit(1)
        }
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        print("screen \(screen)")
        main.setFrame(screen.insetBy(dx: 8, dy: 8), display: true)
        main.makeKeyAndOrderFront(nil)
        await pause(2)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            model.showInspector = false
            model.selectedNotebookID = "demo-kickoff"
            await pause(1.5)
            capture(main, dir, "1-reader-\(suffix)")
            if suffix == "light" {
                dumpScrollViews(main)
                scrollAllToTop(main)
                await pause(0.8)
                capture(main, dir, "1b-reader-top-\(suffix)")
                dumpScrollViews(main)
            }
            model.showInspector = true
            await pause(1.5)
            capture(main, dir, "2-reader-inspector-\(suffix)")
            model.showInspector = false
            model.selectedNotebookID = "demo-ideas"
            await pause(1.5)
            capture(main, dir, "3-figures-\(suffix)")
            model.selectedNotebookID = "demo-pending"
            await pause(1.2)
            capture(main, dir, "4-pending-\(suffix)")
            model.sidebar = .tasks
            await pause(1.2)
            capture(main, dir, "5-tasks-\(suffix)")
            model.sidebar = .all
        }
        NSApp.appearance = NSAppearance(named: .aqua)

        NotificationCenter.default.post(name: .openDiagnosticsWindow, object: nil)
        await pause(2)
        if let diag = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("diagnostics") }) {
            diag.setFrame(screen.insetBy(dx: 30, dy: 20), display: true)
            await pause(1)
            capture(diag, dir, "6-diagnostics")
        }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        await pause(2)
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && !($0.identifier?.rawValue ?? "").hasPrefix("diagnostics")
            && $0.frame.width > 300 && $0.frame.width < 900 }) {
            capture(settings, dir, "7-settings")
        }

        // views that live in popovers / other states, rendered offscreen
        render(MenuBarPanel().environmentObject(model).tint(Theme.accent), size: NSSize(width: 330, height: 520), dir, "8-menubar")
        render(ActivityPanel().environmentObject(model).tint(Theme.accent), size: NSSize(width: 340, height: 360), dir, "9-activity")
        render(OnboardingView().environmentObject(model).tint(Theme.accent), size: NSSize(width: 900, height: 820), dir, "10-onboarding")
        print("screenshots written to \(dir.path)")
        exit(0)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = view as? NSScrollView { out.append(s) }
        for v in view.subviews { out += scrollViews(in: v) }
        return out
    }

    private static func dumpScrollViews(_ window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        print("window frame \(window.frame) content \(window.contentLayoutRect)")
        for s in scrollViews(in: root) {
            let doc = s.documentView
            print("scroll \(type(of: s)) frame=\(s.convert(s.bounds, to: nil)) insets=\(s.contentInsets) auto=\(s.automaticallyAdjustsContentInsets)",
                  "doc=\(doc.map { String(describing: type(of: $0)) } ?? "nil") docFrame=\(doc?.frame ?? .zero) flipped=\(doc?.isFlipped ?? false)",
                  "visible=\(s.documentVisibleRect)")
        }
    }

    private static func scrollAllToTop(_ window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        for s in scrollViews(in: root) {
            guard let doc = s.documentView else { continue }
            let y = doc.isFlipped ? -s.contentInsets.top : max(0, doc.frame.height - s.contentView.bounds.height)
            s.contentView.scroll(to: NSPoint(x: 0, y: y))
            s.reflectScrolledClipView(s.contentView)
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Real window pixels via screencapture (needs Screen Recording permission – CI grants it);
    /// falls back to drawing the view hierarchy, which misses materials and Metal layers.
    private static func capture(_ window: NSWindow, _ dir: URL, _ name: String) {
        let url = dir.appendingPathComponent(name + ".png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 20_000 {
            print("saved \(name) (screencapture)")
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        save(view, dir, name)
    }

    private static func render<V: View>(_ view: V, size: NSSize, _ dir: URL, _ name: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        save(host, dir, name)
        w.orderOut(nil)
    }

    private static func save(_ view: NSView, _ dir: URL, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent(name + ".png"))
            print("saved \(name)")
        }
    }

    // MARK: demo content

    private static func makeDemoLibrary(_ store: LibraryStore) {
        let tools = MacImageTools()
        func page(_ lines: [String], sketch: Bool = false) -> Data { SelfTest.syntheticPage(lines: lines, sketch: sketch) }

        let kickoffPages = [
            page(["Projekt Kickoff", "- Ziele klären", "- Budget prüfen", "Termin: Montag 10 Uhr"]),
            page(["Nächste Schritte", "- Angebot einholen", "- Team informieren"]),
        ]
        var kickoff = NotebookRecord(id: "demo-kickoff", title: "Projekt Kickoff", folderPath: ["Arbeit"],
                                     modificationTime: "1", status: .done, syncedAt: Date().addingTimeInterval(-3600),
                                     noteID: "x-coredata://demo/1", noteFolder: "Kindle Scribe/Arbeit")
        kickoff.pages = [
            PageRecord(index: 0, imageHash: "k0", imageFile: (try? store.writeImage(kickoffPages[0], notebookID: kickoff.id, name: "page-0001.png")) ?? "",
                       ocrText: "# Projekt Kickoff\n\nZiele für das **erste Quartal**:\n\n- Ziele klären mit dem Team\n- Budget prüfen und *freigeben*\n- [ ] Angebot von Müller einholen\n- [x] Raum reservieren\n\nTermin: Montag 10 Uhr im Konferenzraum[?]\n\n> Wichtig: Projetkplan bis Freitag fertigstellen.",
                       status: .recognized, model: "Qwen 3.5 · 9B", recognizedAt: Date()),
            PageRecord(index: 1, imageHash: "k1", imageFile: (try? store.writeImage(kickoffPages[1], notebookID: kickoff.id, name: "page-0002.png")) ?? "",
                       ocrText: "## Nächste Schritte\n\n1. Angebot einholen\n2. Team informieren\n3. Zeitplan abstimmen\n\n| Wer | Was | Bis |\n|---|---|---|\n| Anna | Budget | Fr |\n| Tom | Angebot | Mo |",
                       userText: "## Nächste Schritte\n\n1. Angebot einholen\n2. Team informieren\n3. Zeitplan abstimmen\n\n| Wer | Was | Bis |\n|---|---|---|\n| Anna | Budget | Freitag |\n| Tom | Angebot | Montag |",
                       status: .recognized, model: "Qwen 3.5 · 9B", recognizedAt: Date()),
        ]
        try? store.save(kickoff)

        let ideaPNG = page(["Idee: Gartenhaus", "Maße grob 3 x 2 m"], sketch: true)
        var ideas = NotebookRecord(id: "demo-ideas", title: "Ideen & Skizzen", folderPath: ["Privat"], modificationTime: "1",
                                   status: .done, syncedAt: Date().addingTimeInterval(-86_400))
        let ideaFile = (try? store.writeImage(ideaPNG, notebookID: ideas.id, name: "page-0001.png")) ?? ""
        var fig = Figure(id: 1, box: NormRect(x0: 0.58, y0: 0.53, x1: 0.88, y1: 0.78))
        if let crop = tools.cropFigure(ideaPNG, box: fig.box) {
            fig.box = crop.box
            fig.imageFile = try? store.writeImage(crop.png, notebookID: ideas.id, name: "fig-0001-1.png")
        }
        ideas.pages = [PageRecord(index: 0, imageHash: "i0", imageFile: ideaFile,
                                  ocrText: "# Idee: Gartenhaus\n\nMaße grob 3 x 2 m, Dach leicht geneigt.\n\n[[Grafik 1]]\n\nMaterial: Lärche, unbehandelt.",
                                  figures: [fig], status: .recognized, model: "Qwen 3.5 · 9B", recognizedAt: Date())]
        try? store.save(ideas)

        var pending = NotebookRecord(id: "demo-pending", title: "Besprechung Dienstag", folderPath: ["Arbeit"],
                                     modificationTime: "1", status: .recognizing, syncedAt: Date())
        let pendingPNG = page(["Besprechung", "- Punkt eins"])
        pending.pages = [
            PageRecord(index: 0, imageHash: "p0", imageFile: (try? store.writeImage(pendingPNG, notebookID: pending.id, name: "page-0001.png")) ?? "",
                       status: .pending),
            PageRecord(index: 1, imageHash: "p1", imageFile: (try? store.writeImage(pendingPNG, notebookID: pending.id, name: "page-0002.png")) ?? "",
                       status: .failed, error: "Das KI-Modell ist noch nicht geladen."),
        ]
        try? store.save(pending)

        var shopping = NotebookRecord(id: "demo-shopping", title: "Einkauf", modificationTime: "1", status: .done,
                                      syncedAt: Date().addingTimeInterval(-7200))
        let shopPNG = page(["Einkaufsliste", "- Milch", "- Brot"])
        shopping.pages = [PageRecord(index: 0, imageHash: "s0",
                                     imageFile: (try? store.writeImage(shopPNG, notebookID: shopping.id, name: "page-0001.png")) ?? "",
                                     ocrText: "# Einkaufsliste\n\n- [ ] Milch\n- [ ] Brot\n- [x] Äpfel\n- [ ] Kaffee",
                                     status: .recognized, model: "Qwen 3.5 · 9B", recognizedAt: Date())]
        try? store.save(shopping)
    }
}
