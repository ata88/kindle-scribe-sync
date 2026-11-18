import AppKit
import KSSCore
import MLX
import SwiftUI

/// Everything the app does in the background, visible in one place.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var category: EventLog.Category?
    @State private var onlyProblems = false

    private var events: [EventLog.Event] {
        model.recentEvents.reversed().filter {
            (category == nil || $0.category == category) && (!onlyProblems || $0.level != .info)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                cards.padding(16)
            }
            Divider()
            HStack {
                Picker("Bereich", selection: $category) {
                    Text("Alle").tag(EventLog.Category?.none)
                    ForEach(EventLog.Category.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                .frame(width: 220)
                Toggle("Nur Probleme", isOn: $onlyProblems)
                Spacer()
                Button("Protokoll kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.text(), forType: .string)
                }
                Button("Datenordner zeigen") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support]) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Table(events) {
                TableColumn("Zeit") { e in
                    Text(e.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                }
                .width(80)
                TableColumn("Bereich") { e in Text(e.category.rawValue) }.width(90)
                TableColumn("Ereignis") { e in
                    HStack(spacing: 6) {
                        if e.level != .info {
                            Image(systemName: e.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(e.level == .error ? Color.red : Color.orange)
                        }
                        Text(e.message).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Diagnose")
    }

    private var cards: some View {
        let footprint = ProcessMemory.footprint()
        let pages = model.notebooks.flatMap(\.pages)
        let pending = pages.filter { $0.status != .recognized }.count
        let policy = AppModel.recognitionPolicy(modelID: model.settings.modelID)
        return Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                card("Hintergrund-Sync", "arrow.triangle.2.circlepath") {
                    line("Status", model.isSyncing ? (model.progressLine ?? "läuft") : "wartet")
                    line("Intervall", "alle \(model.settings.syncIntervalMinutes) Min., solange die App läuft")
                    if let n = model.nextScheduledSync { line("Nächster", "ca. \(n.formatted(date: .omitted, time: .shortened))") }
                    line("Letzter", model.lastSync.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                    HStack {
                        Button("Jetzt") { model.syncNow(reason: "Diagnose") }.disabled(model.isSyncing)
                        Button("Abbrechen") { model.cancelSync() }.disabled(!model.isSyncing)
                    }
                }
                card("KI-Modell", "cpu") {
                    let info = ModelCatalog.info(model.settings.modelID)
                    line("Modell", info.title)
                    line("Installiert", ModelManager.isInstalled(info.id)
                         ? ProcessMemory.format(ModelManager.installedSize(info.id)) : "nein")
                    line("Im RAM", model.modelLoaded ? "ja – Texterkennung läuft" : "nein")
                    line("GPU-Speicher", ProcessMemory.format(UInt64(max(0, Memory.activeMemory + Memory.cacheMemory))))
                    line("App gesamt", ProcessMemory.format(footprint))
                }
                card("Energie", "bolt.batteryblock") {
                    line("Quelle", model.power.description)
                    line("Bei Akku", model.settings.batteryMode.label)
                    line("Erkennung jetzt", policy.0 ? "erlaubt" : policy.1)
                    line("Mac wecken", "nie – Sync läuft nur im Wachzustand")
                }
            }
            GridRow {
                card("Amazon", "person.crop.circle") {
                    switch model.auth.state {
                    case .signedIn: line("Sitzung", "angemeldet")
                    case .unknown: line("Sitzung", "gespeichert (wird beim Sync geprüft)")
                    case .needsLogin(let why): line("Sitzung", why)
                    }
                    if let s = AmazonSession.load() {
                        line("Gesichert", s.savedAt.formatted(date: .abbreviated, time: .shortened))
                        line("Marktplatz", s.marketplaceID ?? "noch nicht ermittelt")
                    }
                    line("Server", "read.amazon.com")
                }
                card("Bibliothek & Apple Notes", "books.vertical") {
                    line("Notizbücher", "\(model.notebooks.count)")
                    line("Seiten", "\(pages.count) · \(pending) warten · \(pages.filter(\.isCorrected).count) korrigiert")
                    line("Apple Notes", model.settings.notesEnabled
                         ? "\(model.settings.notesAccount) › \(model.settings.notesFolder)" : "aus")
                    line("Notizen", "\(model.notebooks.filter { $0.noteID != nil }.count) verknüpft")
                }
                card("Prozesse", "list.bullet.rectangle") {
                    line("Hintergrunddienste", "keine")
                    line("Diese App", "PID \(ProcessInfo.processInfo.processIdentifier)")
                    line("Nach „Beenden“", "läuft nichts mehr")
                    line("WebKit-Helfer", "nur während Amazon-Anmeldung")
                }
            }
        }
    }

    private func card<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(v).textSelection(.enabled)
        }
        .font(.callout)
    }
}
