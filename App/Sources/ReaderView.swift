import AppKit
import KSSCore
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord
    @State private var visiblePage: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ReaderHeader(notebook: notebook)
                        .padding(.bottom, 18)
                    ForEach(notebook.pages) { page in
                        PageSection(notebook: notebook, page: page, isLast: page.index == notebook.pages.last?.index)
                            .id(page.index)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: Theme.readingWidth)
                .padding(.horizontal, 44)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $visiblePage, anchor: .top)
            .defaultScrollAnchor(.top)
            .background(Theme.paper)
            .onAppear { jump(proxy) }
            .onChange(of: model.scrollTarget) { _, _ in jump(proxy) }
        }
        .navigationTitle(notebook.title)
        .navigationSubtitle(notebook.folderPath.joined(separator: " › "))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    NotebookActions(notebook: notebook)
                } label: {
                    Label(L("Teilen"), systemImage: "square.and.arrow.up")
                }
                .help(L("Kopieren, exportieren oder in Notizen öffnen"))
                Button {
                    withAnimation(.snappy) { model.showInspector.toggle() }
                } label: {
                    Label(L("Original"), systemImage: "sidebar.right")
                }
                .help(L("Originalseite zeigen (⌥⌘I)"))
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .inspector(isPresented: $model.showInspector) {
            ScanInspector(notebook: notebook, page: visiblePage ?? 0)
                .inspectorColumnWidth(min: 260, ideal: 360, max: 560)
        }
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let target = model.scrollTarget else { return }
        withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) }
        DispatchQueue.main.async { model.scrollTarget = nil }
    }
}

struct ReaderHeader: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notebook.title)
                .font(.system(size: 30, weight: .bold))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if !notebook.folderPath.isEmpty {
                    Label(notebook.folderPath.joined(separator: " › "), systemImage: "folder")
                }
                Label(notebook.pages.count == 1 ? L("1 Seite") : L("%ld Seiten", notebook.pages.count),
                      systemImage: "doc.on.doc")
                if let d = notebook.syncedAt {
                    Label { Text(d, format: .relative(presentation: .named).locale(Loc.locale)) }
                        icon: { Image(systemName: "clock") }
                }
                if notebook.noteID != nil {
                    Button { model.openInNotes(notebook) } label: {
                        Label(L("In Notizen"), systemImage: "note.text")
                    }
                    .buttonStyle(.link)
                    .help(L("Diese Notiz in der App Notizen öffnen"))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Page

struct PageSection: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord
    let page: PageRecord
    let isLast: Bool

    @State private var editing = false
    @State private var draft = ""
    @State private var editorHeight: CGFloat = 160
    @State private var misspelled: Set<String> = []
    @State private var hovering = false


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if !isLast {
                Divider().padding(.top, 22).padding(.bottom, 10)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: page.text) {
            misspelled = page.status == .recognized ? await SpellService.misspelled(in: page.text) : []
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            if notebook.pages.count > 1 {
                Text(L("Seite %ld", page.index + 1).uppercased())
                    .font(.caption.weight(.semibold)).tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            if page.isCorrected { Pill(text: L("korrigiert"), systemImage: "pencil.line", tint: .blue) }
            if !misspelled.isEmpty && !editing {
                Pill(text: misspelled.count == 1 ? L("1 Hinweis") : L("%ld Hinweise", misspelled.count),
                     systemImage: "textformat.abc.dottedunderline", tint: .red)
                    .help(L("Mögliche Rechtschreibfehler – Doppelklick zum Korrigieren"))
            }
            Spacer()
            if editing {
                Button(L("Abbrechen")) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Fertig")) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            } else if page.status == .recognized {
                HStack(spacing: 2) {
                    iconButton("pencil", L("Bearbeiten (Doppelklick)")) { startEditing() }
                    iconButton("doc.on.doc", L("Text kopieren")) { copy() }
                    iconButton("photo", L("Original zeigen")) {
                        model.showInspector = true
                        model.scrollTarget = page.index
                    }
                    Menu {
                        Button(L("Seite neu erkennen")) { model.rerecognize(notebookID: notebook.id, page: page.index) }
                        if page.isCorrected {
                            Button(L("Korrekturen zurücksetzen")) {
                                Task { await model.revertCorrection(notebookID: notebook.id, page: page.index) }
                            }
                        }
                        if let m = page.model, let d = page.recognizedAt {
                            Divider()
                            Text(L("Erkannt mit %@, %@", m, d.formatted(date: .abbreviated, time: .shortened)))
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
        }
        .frame(minHeight: 24)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if editing {
            PageEditor(text: $draft, height: $editorHeight)
                .frame(height: editorHeight)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                .onChange(of: draft) { _, t in model.activeEdit = (notebook.id, page.index, t) }
        } else {
            switch page.status {
            case .recognized:
                BlockStack(notebook: notebook, page: page, misspelled: misspelled)
                    .onTapGesture(count: 2) { startEditing() }
            case .pending:
                PendingPageView(notebook: notebook, page: page, waitingText: waitingText, live: model.live)
            case .failed:
                Surface {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("Texterkennung fehlgeschlagen"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warm).font(.callout.weight(.semibold))
                        if let e = page.error { Text(e).font(.caption).foregroundStyle(.secondary) }
                        Button(L("Erneut versuchen")) { model.rerecognize(notebookID: notebook.id, page: page.index) }
                            .controlSize(.small)
                    }
                }
                if page.ocrText != nil { BlockStack(notebook: notebook, page: page, misspelled: []) }
            }
        }
    }

    private var waitingText: String {
        let policy = AppModel.recognitionPolicy(modelID: model.settings.modelID)
        return policy.0 ? L("Wartet auf Texterkennung") : policy.1
    }

    // MARK: actions

    private func startEditing() {
        guard page.status != .pending else { return }
        draft = page.text
        withAnimation(.snappy) { editing = true }
    }

    private func cancel() {
        withAnimation(.snappy) { editing = false }
        model.activeEdit = nil
    }

    private func save() {
        let text = draft
        withAnimation(.snappy) { editing = false }
        model.activeEdit = nil
        guard text != page.text else { return }
        Task { await model.saveCorrection(notebookID: notebook.id, page: page.index, text: text) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(page.text, forType: .string)
    }
}

/// A page that is waiting for / being read by the model. Only this view observes
/// the live text, so the rest of the reader does not redraw five times a second.
struct PendingPageView: View {
    let notebook: NotebookRecord
    let page: PageRecord
    let waitingText: String
    @ObservedObject var live: LivePreview

    private var text: String? {
        guard let p = live.value, p.notebookID == notebook.id, p.page == page.index, !p.text.isEmpty else { return nil }
        return p.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text {
                Text(text).font(Theme.bodyFont).lineSpacing(Theme.bodyLineSpacing)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(L("Die KI liest diese Seite …"), systemImage: "sparkles")
                    .font(.caption).foregroundStyle(Theme.accent)
            } else if page.ocrText != nil {
                BlockStack(notebook: notebook, page: page, misspelled: []).opacity(0.55)
                Label(L("Seite wurde ergänzt – wird neu erkannt"), systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SkeletonLines()
                Label(waitingText, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Rendered markdown

struct BlockStack: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord
    let page: PageRecord
    let misspelled: Set<String>

    var body: some View {
        let blocks = MarkdownParser.blocks(page.text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(InlineStyler.attributed(text, misspelled: misspelled))
                .font(level == 1 ? .system(size: 22, weight: .bold) : level == 2 ? .system(size: 18, weight: .semibold)
                      : .system(size: 16, weight: .semibold))
                .padding(.top, level == 1 ? 6 : 4)
        case .paragraph(let text):
            Text(InlineStyler.attributed(text, misspelled: misspelled))
                .font(Theme.bodyFont).lineSpacing(Theme.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let indent, let marker, let text, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch marker {
                case .bullet:
                    Text("•").font(Theme.bodyFont).foregroundStyle(.secondary)
                case .number(let n):
                    Text("\(n).").font(Theme.bodyFont.monospacedDigit()).foregroundStyle(.secondary)
                case .check(let done):
                    Button {
                        model.setTask(TaskItem(notebookID: notebook.id, notebookTitle: notebook.title,
                                               pageIndex: page.index, line: line, text: text, done: done), done: !done)
                    } label: {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done ? Theme.accent : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help(done ? L("Als offen markieren") : L("Als erledigt markieren"))
                }
                Text(InlineStyler.attributed(text, misspelled: misspelled))
                    .font(Theme.bodyFont).lineSpacing(Theme.bodyLineSpacing)
                    .strikethrough({ if case .check(true) = marker { return true } else { return false } }(),
                                   color: .secondary)
                    .foregroundStyle({ if case .check(true) = marker { return Color.secondary } else { return Color.primary } }())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 20)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.6)).frame(width: 3)
                Text(InlineStyler.attributed(text, misspelled: misspelled))
                    .font(Theme.bodyFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(InlineStyler.attributed(cell, misspelled: misspelled))
                                .font(i == 0 ? Theme.bodyFont.weight(.semibold) : Theme.bodyFont)
                        }
                    }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        case .figure(let id):
            FigureView(page: page, figureID: id)
        case .spacer:
            Color.clear.frame(height: 2)
        }
    }
}

/// A cropped sketch, centred, at the width it has on the page.
struct FigureView: View {
    @EnvironmentObject var model: AppModel
    let page: PageRecord
    let figureID: Int
    @State private var zoom = false

    var body: some View {
        if let fig = page.figures.first(where: { $0.id == figureID }), let file = fig.imageFile {
            let fraction = min(1, max(0.32, fig.box.width * 1.05))
            CachedImage(url: model.store.url(for: file), maxPixel: 900,
                        placeholderAspect: max(0.2, fig.box.width / max(0.01, fig.box.height) * 0.707),
                        revision: "\(page.imageHash)|\(fig.box.x0),\(fig.box.y0),\(fig.box.x1),\(fig.box.y1)")
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.scanBackground))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .frame(maxWidth: Theme.readingWidth * fraction)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
                .onTapGesture { zoom = true }
                .help(L("Klicken zum Vergrößern"))
                .popover(isPresented: $zoom) {
                    ZoomableImage(url: model.store.url(for: file))
                        .frame(width: 720, height: 520)
                }
        } else {
            Label(L("Grafik %ld", figureID), systemImage: "scribble").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Inspector with the original scan

struct ScanInspector: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord
    let page: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Original")).font(.headline)
                Spacer()
                Text(L("Seite %ld von %ld", page + 1, notebook.pages.count))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(12)
            Divider()
            if let p = notebook.pages.first(where: { $0.index == page }) ?? notebook.pages.first {
                ZoomableImage(url: model.store.url(for: p.imageFile))
                    .id(p.imageFile + p.imageHash)
            }
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(notebook.pages) { p in
                        CachedImage(url: model.store.url(for: p.imageFile), maxPixel: 80, contentMode: .fill, revision: p.imageHash)
                            .frame(width: 44, height: 62)
                            .background(Theme.scanBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(p.index == page ? Theme.accent : Theme.hairline, lineWidth: p.index == page ? 2 : 0.5))
                            .onTapGesture { model.scrollTarget = p.index }
                    }
                }
                .padding(10)
            }
            .frame(height: 82)
        }
    }
}

/// NSScrollView with pinch/scroll zoom – smooth on large scans. Starts fitted
/// to the width and aligned to the top of the page.
struct ZoomableImage: NSViewRepresentable {
    let url: URL

    final class FlippedImageView: NSImageView {
        override var isFlipped: Bool { true }
    }

    final class FittingScrollView: NSScrollView {
        var imageSize: NSSize = .zero
        private var fitted = false

        override func layout() {
            super.layout()
            fitIfNeeded()
        }

        func fitIfNeeded(force: Bool = false) {
            guard imageSize.width > 0, contentSize.width > 10, !fitted || force else { return }
            fitted = true
            let fit = max(minMagnification, contentSize.width / imageSize.width)
            magnification = fit
            documentView?.scroll(.zero)   // flipped: (0,0) is the top-left corner
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FittingScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 6
        scroll.backgroundColor = .white
        scroll.drawsBackground = true
        let imageView = FlippedImageView()
        imageView.imageScaling = .scaleAxesIndependently
        scroll.documentView = imageView
        Task { @MainActor in
            guard let img = await ImageCache.shared.image(at: url, maxPixel: 2400) else { return }
            let size = NSSize(width: img.width, height: img.height)
            imageView.image = NSImage(cgImage: img, size: size)
            imageView.frame = NSRect(origin: .zero, size: size)
            scroll.imageSize = size
            scroll.fitIfNeeded(force: true)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

// MARK: - Editor

/// Plain-text editor with continuous spell checking (red dotted underline,
/// suggestions on right-click). Grows with its text.
struct PageEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 15)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: para,
                               .foregroundColor: NSColor.textColor]
        tv.textColor = .textColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            context.coordinator.updateHeight(tv)
        }
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        if tv.string != text { tv.string = text }
        context.coordinator.updateHeight(tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PageEditor
        init(_ parent: PageEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            updateHeight(tv)
        }

        func updateHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2 + 8)
            if abs(parent.height - h) > 1 {
                DispatchQueue.main.async { self.parent.height = max(80, h) }
            }
        }
    }
}

// MARK: - Spell checking for the read-only view

enum SpellService {
    private static let cache = NSCache<NSString, NSSet>()

    /// Lower-cased words macOS' spell checker does not know (language detected automatically).
    @MainActor static func misspelled(in text: String) async -> Set<String> {
        let key = text as NSString
        if let hit = cache.object(forKey: key) as? Set<String> { return hit }
        // drop markdown syntax and placeholders before checking
        let clean = text
            .replacingOccurrences(of: #"\[\[Grafik \d+\]\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[(\?|x|X| |unleserlich)\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[#*`>|]"#, with: " ", options: .regularExpression)
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        let results: [NSTextCheckingResult] = await withCheckedContinuation { cont in
            _ = checker.requestChecking(of: clean, range: NSRange(location: 0, length: (clean as NSString).length),
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: nil, inSpellDocumentWithTag: tag) { _, results, _, _ in
                cont.resume(returning: results)
            }
        }
        let ns = clean as NSString
        let words = Set(results.map { ns.substring(with: $0.range).lowercased() }
            .filter { $0.count > 1 && !$0.contains(where: \.isNumber) })
        cache.setObject(words as NSSet, forKey: key)
        return words
    }
}
