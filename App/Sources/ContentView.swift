import KSSCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(search: search)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                StatusBanner()
                if let nb = model.notebook(model.selectedNotebookID) {
                    NotebookDetailView(notebook: nb)
                        .id(nb.id)
                } else if model.notebooks.isEmpty {
                    OnboardingView()
                } else {
                    ContentUnavailableView("Kein Notizbuch ausgewählt", systemImage: "book.closed",
                                           description: Text("Wähle links ein Notizbuch."))
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Notizen durchsuchen")
        .toolbar {
            ToolbarItem(placement: .status) { SyncStatusView() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.syncNow(reason: "Symbolleiste")
                } label: {
                    Label("Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Jetzt synchronisieren (⌘R)")
                .disabled(model.isSyncing)
            }
        }
        .sheet(isPresented: Binding(get: { model.auth.showLogin }, set: { model.auth.showLogin = $0 })) {
            AmazonLoginView().environmentObject(model)
        }
        .onAppear {
            if model.selectedNotebookID == nil { model.selectedNotebookID = model.notebooks.first?.id }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    let search: String

    private var filtered: [NotebookRecord] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.notebooks }
        return model.notebooks.filter { nb in
            nb.title.lowercased().contains(q) || nb.pages.contains { $0.text.lowercased().contains(q) }
        }
    }

    private var groups: [(String, [NotebookRecord])] {
        Dictionary(grouping: filtered) { $0.folderPath.joined(separator: " / ") }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) }
    }

    var body: some View {
        List(selection: Binding(get: { model.selectedNotebookID }, set: { model.selectedNotebookID = $0 })) {
            ForEach(groups, id: \.0) { folder, notebooks in
                Section(folder.isEmpty ? "Notizbücher" : folder) {
                    ForEach(notebooks) { nb in
                        NotebookRow(notebook: nb, hasDraft: model.drafts[nb.id] != nil).tag(nb.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct NotebookRow: View {
    let notebook: NotebookRecord
    let hasDraft: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(notebook.title).lineLimit(1)
                Text("\(notebook.pages.count) Seite\(notebook.pages.count == 1 ? "" : "n")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hasDraft {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange)
                    .help("Ungesicherte Korrekturen")
            }
            switch notebook.status {
            case .downloading, .recognizing:
                ProgressView().controlSize(.small)
            case .partial, .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .help(notebook.error ?? "Nicht alle Seiten erkannt")
            default:
                if notebook.hasCorrections {
                    Image(systemName: "pencil").foregroundStyle(.secondary).help("Enthält manuelle Korrekturen")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Status

struct SyncStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.isSyncing {
                ProgressView().controlSize(.small)
            } else if model.modelLoaded {
                Image(systemName: "cpu").foregroundStyle(.orange).help("KI-Modell ist geladen")
            }
            Text(model.progressLine ?? model.statusLine)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: 420)
    }
}

struct StatusBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if case .needsLogin(let why) = model.auth.state, !model.notebooks.isEmpty {
            banner("person.crop.circle.badge.exclamationmark", "Amazon: \(why)", "Anmelden") { model.auth.showLogin = true }
        } else if !ModelManager.isInstalled(model.settings.modelID), !model.notebooks.isEmpty, model.models.downloading == nil {
            banner("cpu", "Das KI-Modell für die Texterkennung ist noch nicht geladen.", "Jetzt laden") {
                model.models.download(ModelCatalog.info(model.settings.modelID))
            }
        } else if let id = model.models.downloading {
            HStack {
                Text("KI-Modell \(ModelCatalog.info(id).title) wird geladen – \(model.models.progressText)").font(.callout)
                ProgressView(value: model.models.progress).frame(maxWidth: 240)
                Button("Abbrechen") { model.models.cancel() }
            }
            .padding(10).frame(maxWidth: .infinity).background(.bar)
        }
    }

    private func banner(_ icon: String, _ text: String, _ action: String, _ fn: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button(action, action: fn)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    private var signedIn: Bool { if case .needsLogin = model.auth.state { return false } else { return true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Willkommen bei Scribe Sync").font(.largeTitle.bold())
            Text("Deine Kindle-Scribe-Notizbücher erscheinen automatisch hier und in Apple Notes – als Text, den du kopieren und korrigieren kannst.")
                .font(.title3).foregroundStyle(.secondary)

            step(1, "Bei Amazon anmelden", done: signedIn,
                 detail: "Mit deinen normalen Amazon-Zugangsdaten (auch amazon.de).") {
                Button("Anmelden …") { model.auth.showLogin = true }
            }
            let rec = ModelCatalog.recommended
            step(2, "KI-Modell laden", done: ModelManager.isInstalled(model.settings.modelID),
                 detail: "\(ModelCatalog.info(model.settings.modelID).title), ca. \(Int(ModelCatalog.info(model.settings.modelID).approxGB)) GB. Läuft komplett auf deinem Mac und ist nur während der Texterkennung im Arbeitsspeicher. Empfohlen für deinen Mac (\(ModelCatalog.physicalRAMGB) GB RAM): \(rec.title).") {
                if model.models.downloading != nil {
                    ProgressView(value: model.models.progress).frame(width: 180)
                } else {
                    Button("Laden") { model.models.download(ModelCatalog.info(model.settings.modelID)) }
                }
            }
            step(3, "Fertig", done: !model.notebooks.isEmpty,
                 detail: "Die App synchronisiert, solange sie läuft – auch wenn das Fenster geschlossen ist. Beenden über das Menüleisten-Symbol oder das Dock.") {
                Button("Jetzt synchronisieren") { model.syncNow(reason: "Einrichtung") }.disabled(!signedIn || model.isSyncing)
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func step<A: View>(_ n: Int, _ title: String, done: Bool, detail: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title).foregroundStyle(done ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !done { action().padding(.top, 4) }
            }
        }
    }
}
