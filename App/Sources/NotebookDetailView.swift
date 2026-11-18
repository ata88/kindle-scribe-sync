import AppKit
import KSSCore
import SwiftUI

struct NotebookDetailView: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                ForEach(notebook.pages) { page in
                    PageCard(notebook: notebook, page: page)
                }
            }
            .padding(24)
            .frame(maxWidth: 1200)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(notebook.title).font(.largeTitle.bold()).textSelection(.enabled)
                HStack(spacing: 10) {
                    if !notebook.folderPath.isEmpty {
                        Label(notebook.folderPath.joined(separator: " / "), systemImage: "folder")
                    }
                    if let d = notebook.syncedAt {
                        Label(d.formatted(date: .abbreviated, time: .shortened), systemImage: "arrow.triangle.2.circlepath")
                    }
                    if notebook.noteID != nil { Label("in Apple Notes", systemImage: "note.text") }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.drafts[notebook.id] != nil {
                Button("Korrekturen sichern") { model.saveAllDrafts() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
            }
            Button {
                let text = notebook.pages.map { model.draft(notebookID: notebook.id, page: $0.index) ?? $0.text }
                    .joined(separator: "\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("# \(notebook.title)\n\n" + text, forType: .string)
            } label: { Label("Alles kopieren", systemImage: "doc.on.doc") }
        }
    }
}

struct PageCard: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord
    let page: PageRecord
    @State private var editorHeight: CGFloat = 120
    @State private var zoom = false

    private var text: Binding<String> {
        Binding(get: { model.draft(notebookID: notebook.id, page: page.index) ?? page.text },
                set: { model.setDraft(notebookID: notebook.id, page: page.index, text: $0) })
    }

    private var isDraft: Bool { model.draft(notebookID: notebook.id, page: page.index) != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            pageImage
                .frame(width: 280)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Seite \(page.index + 1)").font(.headline)
                    if page.isCorrected { tag("korrigiert", .blue) }
                    if isDraft { tag("ungesichert", .orange) }
                    Spacer()
                    pageMenu
                }
                switch page.status {
                case .pending:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.progress.phase == .recognizing ? "Wird erkannt …" : "Wartet auf Texterkennung")
                            .foregroundStyle(.secondary)
                    }
                    if page.ocrText != nil { editor }   // earlier text stays editable
                case .failed:
                    Label(page.error ?? "Texterkennung fehlgeschlagen", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if page.ocrText != nil { editor }
                case .recognized:
                    editor
                }
                if !page.figures.isEmpty { figures }
                if isDraft {
                    HStack {
                        Button("Sichern") {
                            let t = text.wrappedValue
                            Task { await model.saveCorrection(notebookID: notebook.id, page: page.index, text: t) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Verwerfen") { model.setDraft(notebookID: notebook.id, page: page.index, text: page.text) }
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private var editor: some View {
        SpellCheckingEditor(text: text, height: $editorHeight)
            .frame(height: editorHeight)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder private var pageImage: some View {
        if let img = NSImage(contentsOf: model.store.url(for: page.imageFile)) {
            Image(nsImage: img)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .onTapGesture { zoom = true }
                .help("Klicken zum Vergrößern")
                .popover(isPresented: $zoom) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 760).background(.white)
                }
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).aspectRatio(0.71, contentMode: .fit)
        }
    }

    private var figures: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Grafiken (in Apple Notes an der Stelle des Platzhalters)").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(page.figures) { f in
                        if let file = f.imageFile, let img = NSImage(contentsOf: model.store.url(for: file)) {
                            VStack(spacing: 2) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 140).background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text("[[Grafik \(f.id)]]").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var pageMenu: some View {
        Menu {
            Button("Text kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text.wrappedValue, forType: .string)
            }
            if page.isCorrected {
                Button("Korrekturen zurücksetzen") {
                    Task { await model.revertCorrection(notebookID: notebook.id, page: page.index) }
                }
            }
            Divider()
            Button("Seite neu erkennen") { model.rerecognize(notebookID: notebook.id, page: page.index) }
            if let m = page.model, let d = page.recognizedAt {
                Divider()
                Text("Erkannt mit \(m), \(d.formatted(date: .abbreviated, time: .shortened))")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.15)))
            .foregroundStyle(c)
    }
}
