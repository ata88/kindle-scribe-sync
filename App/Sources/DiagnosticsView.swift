import AppKit
import KSSCore
import MLX
import SwiftUI

/// Everything the app does in the background, visible in one place.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var category: EventLog.Category?
    @State private var onlyProblems = false
    @State private var query = ""

    private var events: [EventLog.Event] {
        let q = query.lowercased()
        return model.recentEvents.reversed().filter {
            (category == nil || $0.category == category) && (!onlyProblems || $0.level != .info)
                && (q.isEmpty || $0.message.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // a plain Grid: lazy grids re-measure live-updating cards (memory) and can loop
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow(alignment: .top) { syncCard; MemoryCard(); powerCard }
                    GridRow(alignment: .top) { amazonCard; libraryCard; processCard }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("", selection: $category) {
                        Text(L("Alle Bereiche")).tag(EventLog.Category?.none)
                        ForEach(EventLog.Category.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Toggle(L("Nur Probleme"), isOn: $onlyProblems).toggleStyle(.checkbox)
                    TextField(L("Protokoll durchsuchen"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Spacer()
                    Button { copyLog() } label: { Label(L("Kopieren"), systemImage: "doc.on.doc") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support]) } label: {
                        Label(L("Datenordner"), systemImage: "folder")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                List(events) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.date.formatted(.dateTime.hour().minute().second().locale(Loc.locale)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(e.category.title).font(.caption.weight(.medium))
                            .foregroundStyle(color(e.category)).frame(width: 80, alignment: .leading)
                        if e.level != .info {
                            Image(systemName: e.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(e.level == .error ? Color.red : Color.orange).font(.caption)
                        }
                        Text(e.message).font(.callout).textSelection(.enabled)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .overlay {
                    if events.isEmpty {
                        ContentUnavailableView(L("Keine Einträge"), systemImage: "list.bullet.rectangle",
                                               description: Text(L("Hier erscheint, was die App im Hintergrund tut.")))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("Diagnose"))
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.log.text(), forType: .string)
    }

    private func color(_ c: EventLog.Category) -> Color {
        switch c {
        case .sync: return Theme.accent
        case .amazon: return .orange
        case .model: return .purple
        case .notes: return .yellow
        case .power: return .green
        case .app, .update: return .secondary
        }
    }

    // MARK: cards

    private func card<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: icon).font(.headline)
                content()
            }
        }
    }

    private var syncCard: some View {
        card(L("Abgleich"), "arrow.triangle.2.circlepath") {
            InfoRow(label: L("Status"), value: model.isSyncing ? (model.activityLine ?? L("läuft")) : L("wartet"))
            InfoRow(label: L("Intervall"), value: L("alle %ld Min., solange die App läuft", model.settings.syncIntervalMinutes))
            InfoRow(label: L("Nächster"), value: model.nextScheduledSync.map {
                $0.formatted(.dateTime.hour().minute().locale(Loc.locale)) } ?? "–")
            InfoRow(label: L("Letzter"), value: model.lastSync.map {
                $0.formatted(.dateTime.hour().minute().locale(Loc.locale)) } ?? "–")
            HStack {
                Button(L("Jetzt")) { model.syncNow(reason: L("Diagnose")) }.disabled(model.isSyncing)
                Button(L("Abbrechen")) { model.cancelSync() }.disabled(!model.isSyncing)
            }
            .controlSize(.small)
        }
    }

    private var powerCard: some View {
        let policy = AppModel.recognitionPolicy(modelID: model.settings.modelID)
        return card(L("Energie"), "bolt.batteryblock") {
            InfoRow(label: L("Quelle"), value: model.power.state.description)
            InfoRow(label: L("Wach halten"), value: model.power.holdingAwake ? L("ja (Netzteil)") : L("nein"))
            InfoRow(label: L("Erkennung jetzt"), value: policy.0 ? L("erlaubt") : policy.1)
            InfoRow(label: L("Bei Akku"), value: model.settings.batteryMode.label)
        }
    }

    private var amazonCard: some View {
        card("Amazon", "person.crop.circle") {
            switch model.auth.state {
            case .signedIn: InfoRow(label: L("Sitzung"), value: L("angemeldet"))
            case .unknown: InfoRow(label: L("Sitzung"), value: L("gespeichert (wird beim Abgleich geprüft)"))
            case .needsLogin(let why): InfoRow(label: L("Sitzung"), value: why)
            }
            if let s = AmazonSession.load() {
                InfoRow(label: L("Gesichert"), value: s.savedAt.formatted(date: .abbreviated, time: .shortened))
                InfoRow(label: L("Marktplatz"), value: s.marketplaceID ?? L("noch nicht ermittelt"), mono: true)
            }
            InfoRow(label: L("Server"), value: "read.amazon.com", mono: true)
        }
    }

    private var libraryCard: some View {
        let pages = model.notebooks.flatMap(\.pages)
        return card(L("Bibliothek & Notizen"), "books.vertical") {
            InfoRow(label: L("Notizbücher"), value: "\(model.notebooks.count)")
            InfoRow(label: L("Seiten"), value: L("%ld · %ld warten · %ld korrigiert", pages.count,
                                                 pages.filter { $0.status != .recognized }.count,
                                                 pages.filter(\.isCorrected).count))
            InfoRow(label: L("Notizen-App"), value: model.settings.notesEnabled
                    ? "\(model.settings.notesAccount) › \(model.settings.notesFolder)" : L("aus"))
            InfoRow(label: L("Verknüpft"), value: L("%ld Notizen", model.notebooks.filter { $0.noteID != nil }.count))
        }
    }

    private var processCard: some View {
        card(L("Prozesse"), "list.bullet.rectangle") {
            InfoRow(label: L("Hintergrunddienste"), value: L("keine"))
            InfoRow(label: L("Diese App"), value: "PID \(ProcessInfo.processInfo.processIdentifier)", mono: true)
            InfoRow(label: L("Nach „Beenden“"), value: L("läuft nichts mehr"))
            InfoRow(label: L("WebKit-Helfer"), value: L("nur während der Amazon-Anmeldung"))
        }
    }
}

/// The only card that refreshes on a timer – cheap and isolated.
private struct MemoryCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Surface {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                VStack(alignment: .leading, spacing: 7) {
                    Label(L("KI-Modell & Speicher"), systemImage: "cpu").font(.headline)
                    let info = ModelCatalog.info(model.settings.modelID)
                    InfoRow(label: L("Modell"), value: info.title)
                    InfoRow(label: L("Installiert"), value: ModelManager.isInstalled(info.id)
                            ? ProcessMemory.format(ModelManager.installedSize(info.id)) : L("nein"))
                    InfoRow(label: L("Im Speicher"), value: model.modelLoaded ? L("ja – Texterkennung läuft") : L("nein"))
                    InfoRow(label: L("GPU-Speicher"), value: ProcessMemory.format(UInt64(max(0, Memory.activeMemory + Memory.cacheMemory))), mono: true)
                    InfoRow(label: L("App gesamt"), value: ProcessMemory.format(ProcessMemory.footprint()), mono: true)
                }
            }
        }
    }
}

extension EventLog.Category {
    var title: String {
        switch self {
        case .sync: return L("Abgleich")
        case .amazon: return "Amazon"
        case .model: return L("KI-Modell")
        case .notes: return L("Notizen")
        case .power: return L("Energie")
        case .app: return "App"
        case .update: return L("Updates")
        }
    }
}
