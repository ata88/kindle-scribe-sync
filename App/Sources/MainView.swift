import AppKit
import CoreSpotlight
import KSSCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var columns = NavigationSplitViewVisibility.all
    /// The sidebar was hidden only to make room for the original scan.
    @State private var hidSidebarForInspector = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } content: {
            Group {
                switch model.sidebar {
                case .tasks: TaskListView()
                case .sendToKindle: SendHistoryView(stk: model.sendToKindle)
                case .kindleLibrary: KindleLibraryListView(lib: model.kindleLibrary)
                default: NotebookListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 440)
        } detail: {
            DetailRoot()
        }
        .onChange(of: model.showInspector) { _, open in
            // a narrow window cannot hold four columns: make room by hiding the sidebar meanwhile
            let width = NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") }?.frame.width ?? 2000
            if open, width < 1280, columns == .all {
                withAnimation(.snappy) { columns = .doubleColumn }
                hidSidebarForInspector = true
            } else if !open, hidSidebarForInspector {
                withAnimation(.snappy) { columns = .all }
                hidSidebarForInspector = false
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: Text(L("Suchen")))
        .modifier(LibraryActionsModifier())
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SyncButton() }
        }
        .sheet(isPresented: Binding(get: { model.auth.showLogin }, set: { model.auth.showLogin = $0 })) {
            AmazonLoginView().environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiagnosticsWindow)) { _ in
            openWindow(id: "diagnostics")
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                model.open(notebookID: id, page: nil)
            }
        }
    }
}

struct SyncButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.syncNow(reason: L("manuell"))
        } label: {
            if model.isSyncing {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                Label(L("Synchronisieren"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .help(L("Jetzt synchronisieren (⌘R)"))
        .disabled(model.isSyncing)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.sidebar) {
            Section(L("Bibliothek")) {
                row(.all, count: model.notebooks.count)
                row(.recent, count: nil)
                row(.tasks, count: model.openTaskCount)
                row(.review, count: model.reviewCount)
            }
            Section("Kindle") {
                row(.sendToKindle, count: model.sendToKindle.jobs.filter { $0.state != .sent }.count)
                    .dropDestination(for: URL.self) { urls, _ in model.sendToKindle(urls); return true }
                    .help(L("Dateien hierher ziehen, um sie an den Kindle zu senden"))
                row(.kindleLibrary, count: nil)
            }
            if !model.folders.isEmpty {
                Section(L("Ordner")) {
                    ForEach(model.folders, id: \.self) { path in
                        let depth = path.components(separatedBy: "/").count - 1
                        row(.folder(path), count: model.notebooks.filter { $0.folderPath.joined(separator: "/") == path }.count)
                            .padding(.leading, CGFloat(depth) * 12)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
    }

    private func row(_ item: SidebarItem, count: Int?) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(count ?? 0)
            .tag(item)
    }
}

/// Bottom of the sidebar: what the app is doing, and anything that needs the user.
struct SidebarStatus: View {
    @EnvironmentObject var model: AppModel
    @State private var showPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.attention) { AttentionCard(item: $0) }
            Button { showPanel.toggle() } label: {
                HStack(spacing: 8) {
                    ZStack {
                        if model.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: model.attention.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(model.attention.isEmpty ? Theme.accent : Theme.warm)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in   // keeps "5 min ago" current
                            Text(model.statusLine).font(.callout).lineLimit(1).truncationMode(.middle)
                        }
                        if let f = model.progressFraction, model.isSyncing {
                            ProgressView(value: f).progressViewStyle(.linear).controlSize(.mini)
                        } else if model.modelLoaded {
                            Text(L("KI-Modell aktiv")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .popover(isPresented: $showPanel, arrowEdge: .top) { ActivityPanel().environmentObject(model) }
        }
        .padding(10)
        .animation(.snappy, value: model.attention)
    }
}

struct AttentionCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let item: Attention

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title).font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: icon).foregroundStyle(Theme.warm)
            }
            // No fixedSize here: the split view measures the sidebar at a tiny width, and a
            // vertically fixed text then reports a huge minimum height for the whole window.
            Text(message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(4)
            Button(action: act) { Text(actionTitle).frame(maxWidth: .infinity) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warm.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.warm.opacity(0.25), lineWidth: 0.5))
    }

    private var icon: String {
        switch item {
        case .signIn: return "person.crop.circle.badge.exclamationmark"
        case .modelMissing: return "cpu"
        case .error: return "exclamationmark.triangle"
        }
    }
    private var title: String {
        switch item {
        case .signIn: return L("Amazon-Anmeldung nötig")
        case .modelMissing: return L("KI-Modell fehlt")
        case .error: return L("Letzter Abgleich mit Fehler")
        }
    }
    private var message: String {
        switch item {
        case .signIn(let why): return why
        case .modelMissing: return L("Für die Texterkennung wird das Modell einmalig geladen (ca. %ld GB).",
                                     Int(ModelCatalog.info(model.settings.modelID).approxGB.rounded()))
        case .error(let e): return e
        }
    }
    private var actionTitle: String {
        switch item {
        case .signIn: return L("Anmelden …")
        case .modelMissing: return L("Modell laden")
        case .error: return L("Details")
        }
    }
    private func act() {
        switch item {
        case .signIn: model.auth.showLogin = true
        case .modelMissing: model.models.download(ModelCatalog.info(model.settings.modelID))
        case .error: openWindow(id: "diagnostics")
        }
    }
}

/// Popover with everything that is going on right now.
struct ActivityPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Aktivität")).font(.headline)
                Spacer()
                Button(L("Diagnose")) { openWindow(id: "diagnostics") }.controlSize(.small)
            }
            if model.isSyncing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.activityLine ?? L("Synchronisiere …")).font(.callout)
                    if let f = model.progressFraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                    LiveSnippet(live: model.live)
                    Button(L("Abbrechen")) { model.cancelSync() }.controlSize(.small)
                }
            } else {
                Text(model.lastSyncResult.isEmpty ? model.statusLine : model.lastSyncResult).font(.callout)
            }
            if let downloading = model.models.downloading {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Lade %@", ModelCatalog.info(downloading).title)).font(.callout)
                    ProgressView(value: model.models.progress)
                    Text(model.models.progressText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            InfoRow(label: L("Nächster Abgleich"), value: model.nextScheduledSync.map {
                $0.formatted(.dateTime.hour().minute().locale(Loc.locale))
            } ?? "–")
            InfoRow(label: L("Strom"), value: model.power.state.description
                    + (model.power.holdingAwake ? " · " + L("hält wach") : ""))
            InfoRow(label: L("KI-Modell"), value: model.modelLoaded ? L("geladen") : L("nicht im Speicher"))
            Divider()
            Button {
                model.syncNow(reason: L("Aktivität"))
            } label: {
                Label(L("Jetzt synchronisieren"), systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(model.isSyncing)
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct LiveSnippet: View {
    @ObservedObject var live: LivePreview
    var body: some View {
        if let v = live.value, !v.text.isEmpty {
            Text(v.text.suffix(220))
                .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }
}

// MARK: - Notebook list

struct NotebookListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let list = model.listedNotebooks
        List(selection: $model.selectedNotebookID) {
            ForEach(list) { nb in
                NotebookRow(notebook: nb).tag(nb.id)
                    .contextMenu { NotebookActions(notebook: nb) }
            }
        }
        .listStyle(.inset)
        .navigationTitle((model.sidebar ?? .all).title)
        .navigationSubtitle(L("%ld Notizbücher", list.count))
        .overlay {
            if list.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? L("Keine Notizbücher") : L("Keine Treffer"),
                                       systemImage: model.search.isEmpty ? "book.closed" : "magnifyingglass",
                                       description: Text(model.search.isEmpty
                                                         ? L("Sobald der Scribe synchronisiert hat, erscheinen sie hier.")
                                                         : L("Für „%@“ wurde nichts gefunden.", model.search)))
            }
        }
    }
}

struct NotebookRow: View {
    let notebook: NotebookRecord

    private var snippet: String {
        let text = notebook.pages.first(where: { !$0.text.isEmpty })?.text ?? ""
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"^\s*(#+|[-*•]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+|>)\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
        }
        return lines.filter { !$0.isEmpty && !$0.hasPrefix("[[") && $0 != notebook.title }.prefix(2).joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedImage(url: notebook.pages.first.map { AppModel.shared.store.url(for: $0.imageFile) },
                        maxPixel: 96, contentMode: .fill, revision: notebook.pages.first?.imageHash ?? "")
                .frame(width: 42, height: 58)
                .background(Theme.scanBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(notebook.title).font(.headline).lineLimit(1)
                Text(snippet.isEmpty ? L("Noch kein Text") : snippet)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let d = notebook.syncedAt {
                        Text(d, format: .relative(presentation: .named).locale(Loc.locale))
                    }
                    Text("·")
                    Text(notebook.pages.count == 1 ? L("1 Seite") : L("%ld Seiten", notebook.pages.count))
                    Spacer(minLength: 0)
                    statusIcon
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusIcon: some View {
        switch notebook.status {
        case .downloading, .recognizing:
            Image(systemName: "hourglass").foregroundStyle(Theme.warm).help(L("Wird verarbeitet"))
        case .partial, .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                .help(notebook.error ?? L("Nicht alle Seiten erkannt"))
        default:
            if notebook.hasCorrections {
                Image(systemName: "pencil.line").foregroundStyle(.secondary).help(L("Enthält Korrekturen"))
            }
        }
    }
}

/// Shared actions for context menus and the share toolbar menu.
struct NotebookActions: View {
    @EnvironmentObject var model: AppModel
    let notebook: NotebookRecord

    var body: some View {
        Button(L("Text kopieren")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AppModel.markdown(notebook), forType: .string)
        }
        Button(L("Als Markdown exportieren …")) { model.exportMarkdown(notebook) }
        Divider()
        Button(L("In Notizen öffnen")) { model.openInNotes(notebook) }
            .disabled(notebook.noteID == nil)
    }
}

// MARK: - Tasks

struct TaskListView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showDoneTasks") private var showDone = false

    var body: some View {
        let items = model.taskItems.filter { showDone || !$0.done }
        let groups = Dictionary(grouping: items, by: \.notebookID)
        List {
            ForEach(model.notebooks.filter { groups[$0.id] != nil }) { nb in
                Section(nb.title) {
                    ForEach(groups[nb.id] ?? []) { item in TaskRow(item: item) }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(L("Aufgaben"))
        .navigationSubtitle(L("%ld offen", model.openTaskCount))
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showDone) { Label(L("Erledigte zeigen"), systemImage: "checkmark.circle") }
                    .help(L("Erledigte Aufgaben zeigen"))
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(L("Keine offenen Aufgaben"), systemImage: "checklist",
                                       description: Text(L("Checkboxen aus deinen Notizbüchern („☐ …“) erscheinen hier.")))
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let item: TaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { model.setTask(item, done: !item.done) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Theme.accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                Text(L("Seite %ld", item.pageIndex + 1)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.open(notebookID: item.notebookID, page: item.pageIndex) }
        .help(L("Klicken, um die Aufgabe im Notizbuch zu zeigen"))
        .contextMenu {
            Button(L("Im Notizbuch zeigen")) { model.open(notebookID: item.notebookID, page: item.pageIndex) }
        }
    }
}

// MARK: - Detail

struct DetailRoot: View {
    @EnvironmentObject var model: AppModel

    private var needsSetup: Bool {
        if case .needsLogin = model.auth.state, model.notebooks.isEmpty { return true }
        return model.notebooks.isEmpty && !ModelManager.isInstalled(model.settings.modelID)
    }

    var body: some View {
        if model.sidebar == .sendToKindle {
            SendToKindleView(stk: model.sendToKindle)
        } else if model.sidebar == .kindleLibrary {
            KindleLibraryDetailView(lib: model.kindleLibrary)
        } else if needsSetup || model.notebooks.isEmpty {
            OnboardingView()
        } else if let nb = model.notebook(model.selectedNotebookID) {
            ReaderView(notebook: nb).id(nb.id)
        } else {
            ContentUnavailableView(L("Kein Notizbuch ausgewählt"), systemImage: "book.closed",
                                   description: Text(L("Wähle ein Notizbuch aus der Liste.")))
        }
    }
}
