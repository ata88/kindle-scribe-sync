import KSSCore
import SwiftUI
import UniformTypeIdentifiers

/// Middle column: what is in the Kindle library.
struct KindleLibraryListView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var lib: KindleLibraryService
    @AppStorage("kindleLibraryTab") private var tab = "documents"

    private var items: [KindleLibraryItem] {
        let list = tab == "books" ? lib.books : lib.documents
        let q = model.search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { $0.title.lowercased().contains(q) || $0.author.lowercased().contains(q) }
    }

    var body: some View {
        List(selection: $model.selectedLibraryItem) {
            ForEach(items) { item in
                KindleLibraryRow(item: item, busy: lib.busy.contains(item.asin)).tag(item.asin)
                    .contextMenu {
                        if item.kind == .document {
                            Button(L("Umbenennen …")) { model.libraryAction = .rename(item) }
                            Button(L("Löschen …"), role: .destructive) { model.libraryAction = .delete(item) }
                        }
                    }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("", selection: $tab) {
                Text(L("Dokumente (%ld)", lib.documents.count)).tag("documents")
                Text(L("Bücher (%ld)", lib.books.count)).tag("books")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(L("Kindle-Bibliothek"))
        .navigationSubtitle(lib.store)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker(L("Amazon-Shop"), selection: $lib.store) {
                        ForEach(KindleLibrary.stores, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Label(lib.store, systemImage: "globe") }
                .help(L("Amazon-Shop, bei dem dein Kindle registriert ist"))
            }
            ToolbarItem {
                Button { Task { await lib.reload() } } label: { Label(L("Neu laden"), systemImage: "arrow.clockwise") }
                    .help(L("Kindle-Bibliothek neu laden"))
                    .disabled(lib.phase == .loading)
            }
        }
        .overlay { overlay }
        .task(id: lib.store) { if lib.phase == .idle { await lib.reload() } }
        .sheet(isPresented: $lib.showSignIn) { KindleLibrarySignInView().environmentObject(model) }
    }

    @ViewBuilder private var overlay: some View {
        switch lib.phase {
        case .loading where items.isEmpty:
            ProgressView(L("Bibliothek wird geladen …"))
        case .needsSignIn:
            ContentUnavailableView {
                Label(L("Anmeldung nötig"), systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text(L("Einmal bei %@ anmelden, dann zeigt Scribe Sync hier alles, was in deiner Kindle-Bibliothek ist.", lib.store))
            } actions: {
                Button(L("Bei Amazon anmelden …")) { lib.showSignIn = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                StorePicker(lib: lib)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(L("Bibliothek nicht geladen"), systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                Button(L("Erneut versuchen")) { Task { await lib.reload() } }
                StorePicker(lib: lib)
            }
        default:
            if items.isEmpty && lib.phase == .loaded {
                ContentUnavailableView(tab == "books" ? L("Keine Bücher") : L("Keine Dokumente"), systemImage: "books.vertical",
                                       description: Text(model.search.isEmpty ? L("Hier ist noch nichts.") : L("Keine Treffer")))
            }
        }
    }
}

private struct StorePicker: View {
    @ObservedObject var lib: KindleLibraryService
    var body: some View {
        Picker(L("Amazon-Shop"), selection: $lib.store) {
            ForEach(KindleLibrary.stores, id: \.self) { Text($0).tag($0) }
        }
        .frame(maxWidth: 240)
    }
}

struct KindleLibraryRow: View {
    let item: KindleLibraryItem
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .book ? "book.closed" : "doc.text")
                .font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if !item.author.isEmpty { Text(item.author).lineLimit(1) }
                    if let d = item.acquired {
                        Text(d, format: .dateTime.day().month().year().locale(Loc.locale))
                    } else if !item.acquiredText.isEmpty {
                        Text(item.acquiredText)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 3)
    }
}

/// Right column: one item, with rename and delete.
struct KindleLibraryDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var lib: KindleLibraryService

    private var item: KindleLibraryItem? {
        (lib.documents + lib.books).first { $0.asin == model.selectedLibraryItem }
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: item.kind == .book ? "book.closed.fill" : "doc.text.fill")
                            .font(.system(size: 48)).foregroundStyle(Theme.accent)
                        Text(item.title).font(.system(size: 26, weight: .bold)).textSelection(.enabled)
                        if !item.author.isEmpty { Text(item.author).font(.title3).foregroundStyle(.secondary) }
                        Surface {
                            VStack(alignment: .leading, spacing: 6) {
                                InfoRow(label: L("Art"), value: item.kind == .book ? L("Gekauftes Buch") : L("Persönliches Dokument"))
                                if let d = item.acquired {
                                    InfoRow(label: L("Hinzugefügt"), value: d.formatted(date: .long, time: .shortened))
                                } else if !item.acquiredText.isEmpty {
                                    InfoRow(label: L("Hinzugefügt"), value: item.acquiredText)
                                }
                                InfoRow(label: "ASIN", value: item.asin, mono: true)
                            }
                        }
                        if item.kind == .document {
                            HStack {
                                Button { model.libraryAction = .rename(item) } label: { Label(L("Umbenennen …"), systemImage: "pencil") }
                                Button(role: .destructive) { model.libraryAction = .delete(item) } label: {
                                    Label(L("Löschen …"), systemImage: "trash")
                                }
                            }
                            .controlSize(.large)
                            .disabled(lib.busy.contains(item.asin))
                            Text(L("Löschen entfernt das Dokument aus deiner Kindle-Bibliothek und von allen Geräten."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(L("Gekaufte Bücher zeigt Scribe Sync nur an. Löschen würde den Kauf endgültig entfernen – das geht bewusst nur auf der Amazon-Website."))
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(36)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .background(Theme.paper)
            } else {
                ContentUnavailableView(L("Nichts ausgewählt"), systemImage: "books.vertical",
                                       description: Text(L("Wähle ein Buch oder Dokument aus der Liste.")))
            }
        }
        .navigationTitle(item?.title ?? L("Kindle-Bibliothek"))
    }
}

/// Rename and delete dialogs, attached once to the main window.
struct LibraryActionsModifier: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.libraryAction?.isDelete == true },
                                                                  set: { if !$0 { model.libraryAction = nil } }),
                                titleVisibility: .visible) {
                Button(L("Löschen"), role: .destructive) {
                    guard case .delete(let item)? = model.libraryAction else { return }
                    model.libraryAction = nil
                    Task {
                        do { try await model.kindleLibrary.delete(item) }
                        catch { model.libraryError = error.localizedDescription }
                    }
                }
                Button(L("Abbrechen"), role: .cancel) { model.libraryAction = nil }
            } message: {
                Text(L("Das Dokument verschwindet aus der Kindle-Bibliothek und von allen Geräten. Das lässt sich nicht rückgängig machen."))
            }
            .sheet(isPresented: Binding(get: { model.libraryAction?.isRename == true },
                                        set: { if !$0 { model.libraryAction = nil } })) {
                if case .rename(let item)? = model.libraryAction { RenameSheet(item: item).environmentObject(model) }
            }
            .alert(L("Aktion fehlgeschlagen"), isPresented: Binding(get: { model.libraryError != nil },
                                                                    set: { if !$0 { model.libraryError = nil } })) {
                Button("OK") { model.libraryError = nil }
            } message: { Text(model.libraryError ?? "") }
    }

    private var deleteTitle: String {
        if case .delete(let item)? = model.libraryAction { return L("„%@“ löschen?", item.title) }
        return ""
    }
}

private struct RenameSheet: View {
    @EnvironmentObject var model: AppModel
    let item: KindleLibraryItem
    @State private var title = ""
    @State private var author = ""
    @State private var original: URL?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Umbenennen")).font(.title2.weight(.semibold))
            Text(L("Amazon kann Dokumente nicht umbenennen. Scribe Sync sendet das Dokument deshalb unter dem neuen Namen erneut und löscht danach die alte Fassung. Lesezeichen und Notizen auf dem Kindle gehören zur alten Fassung."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(L("Titel"), text: $title)
                TextField(L("Autor"), text: $author)
            }
            .formStyle(.grouped)
            .frame(height: 120)

            if let original {
                Label(original.lastPathComponent, systemImage: "doc.fill").font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("Die Originaldatei wurde nicht mit Scribe Sync gesendet."), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(Theme.warm)
                    Button(L("Originaldatei auswählen …")) { picking = true }
                }
            }
            if !model.sendToKindle.isReady, let hint = model.sendToKindle.readinessHint {
                Label(L("Zum Senden fehlt noch: %@", hint), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warm)
            }
            HStack {
                Spacer()
                Button(L("Abbrechen")) { model.libraryAction = nil }.keyboardShortcut(.cancelAction)
                Button(L("Umbenennen")) {
                    guard let original else { return }
                    model.kindleLibrary.rename(item, to: title.trimmingCharacters(in: .whitespaces),
                                               author: author.trimmingCharacters(in: .whitespaces), original: original)
                    model.libraryAction = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(original == nil || title.trimmingCharacters(in: .whitespaces).isEmpty || title == item.title && author == item.author)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            title = item.title
            author = item.author
            original = model.kindleLibrary.original(for: item)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: SendToKindleView.types) { result in
            if case .success(let url) = result { original = url }
        }
    }
}
