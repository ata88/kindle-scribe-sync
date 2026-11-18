import KSSCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            RecognitionSettings().tabItem { Label("Texterkennung", systemImage: "cpu") }
            NotesSettings().tabItem { Label("Apple Notes", systemImage: "note.text") }
            AccountSettings().tabItem { Label("Amazon", systemImage: "person.crop.circle") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .environmentObject(model)
        .frame(width: 560)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Stepper("Automatisch synchronisieren alle \(model.settings.syncIntervalMinutes) Min.",
                        value: Binding(get: { model.settings.syncIntervalMinutes },
                                       set: { model.settings.syncIntervalMinutes = $0; model.scheduleBackgroundSync() }),
                        in: 1...120)
                Text("Nur solange die App läuft. macOS wählt den energiegünstigsten Moment und weckt den Mac nie dafür auf.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Akkubetrieb") {
                Picker("Bei Akkubetrieb", selection: Binding(get: { model.settings.batteryMode },
                                                             set: { model.settings.batteryMode = $0 })) {
                    ForEach(BatteryMode.allCases) { Text($0.label).tag($0) }
                }
                if model.settings.batteryMode == .normal {
                    Stepper("Texterkennung erst ab \(model.settings.minBatteryPercent) % Akku",
                            value: Binding(get: { model.settings.minBatteryPercent },
                                           set: { model.settings.minBatteryPercent = $0 }),
                            in: 0...90, step: 5)
                }
                Text("Im Stromsparmodus wartet die Texterkennung immer bis zum Netzteil.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Beim Anmelden am Mac öffnen", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.log.log(.app, "Anmeldeobjekt: \(error.localizedDescription)", level: .warning)
                        }
                    }
                Text("Startet die App selbst (sichtbar in Dock und Menüleiste) – es gibt keinen versteckten Hintergrunddienst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecognitionSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { info in
                    HStack(alignment: .top) {
                        Image(systemName: model.settings.modelID == info.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.accentColor)
                            .onTapGesture { model.settings.modelID = info.id }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(info.title).font(.headline)
                                if info.id == ModelCatalog.recommended.id {
                                    Text("empfohlen").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Text(info.note).font(.caption).foregroundStyle(.secondary)
                            Text("ca. \(String(format: "%.1f", info.approxGB)) GB · ab \(info.minRAMGB) GB RAM")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        modelButton(info)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.settings.modelID = info.id }
                }
            } footer: {
                Text("Die Modelle laufen vollständig auf deinem Mac. Sie werden nur geladen, während neue Seiten erkannt werden, und danach sofort aus dem Arbeitsspeicher entfernt. Quelle: huggingface.co/mlx-community.")
            }
            if let err = model.models.lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func modelButton(_ info: ModelInfo) -> some View {
        if model.models.downloading == info.id {
            VStack(alignment: .trailing) {
                ProgressView(value: model.models.progress).frame(width: 120)
                Button("Abbrechen") { model.models.cancel() }.controlSize(.small)
            }
        } else if ModelManager.isInstalled(info.id) {
            Button("Löschen", role: .destructive) { model.models.delete(info.id) }
        } else {
            Button("Laden") {
                model.settings.modelID = info.id
                model.models.download(info)
            }
            .disabled(model.models.downloading != nil)
        }
    }
}

private struct NotesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var accounts: [String] = []

    var body: some View {
        Form {
            Toggle("Notizbücher in Apple Notes spiegeln", isOn: Binding(get: { model.settings.notesEnabled },
                                                                       set: { model.settings.notesEnabled = $0 }))
            Picker("Account", selection: Binding(get: { model.settings.notesAccount },
                                                 set: { model.settings.notesAccount = $0 })) {
                ForEach(Array(Set(accounts + [model.settings.notesAccount])).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .onAppear { accounts = NotesScripting.accountNames() }
            TextField("Ordner", text: Binding(get: { model.settings.notesFolder }, set: { model.settings.notesFolder = $0 }))
            Toggle("Komplettes Seitenbild zusätzlich anhängen", isOn: Binding(get: { model.settings.attachPageImages },
                                                                             set: { model.settings.attachPageImages = $0 }))
            Section {
                Button("Alle Notizen jetzt neu schreiben") { model.republishAll() }
            } footer: {
                Text("Jedes Notizbuch ist genau eine Notiz, die bei Änderungen aktualisiert wird. Korrekturen bitte in Scribe Sync machen – Änderungen direkt in Apple Notes werden beim nächsten Abgleich überschrieben.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            switch model.auth.state {
            case .needsLogin(let why):
                LabeledContent("Status", value: why)
                Button("Bei Amazon anmelden …") { model.auth.showLogin = true }
            default:
                LabeledContent("Status", value: "Angemeldet")
                if let s = AmazonSession.load() {
                    LabeledContent("Gesichert am", value: s.savedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Abmelden", role: .destructive) { model.auth.signOut() }
            }
            Text("Die Anmeldung liegt verschlüsselt im macOS-Schlüsselbund. Scribe-Notizbücher werden für alle Länder über read.amazon.com abgerufen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { model.auth.showLogin }, set: { model.auth.showLogin = $0 })) {
            AmazonLoginView().environmentObject(model)
        }
    }
}

private struct UpdateSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
            if model.updater.isAvailable {
                Toggle("Automatisch nach Updates suchen", isOn: Binding(get: { model.updater.automaticallyChecks },
                                                                       set: { model.updater.automaticallyChecks = $0 }))
                if let d = model.updater.lastCheck {
                    LabeledContent("Zuletzt geprüft", value: d.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Jetzt nach Updates suchen") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheckForUpdates)
                Text("Updates kommen signiert aus den GitHub-Releases von ata88/kindle-scribe-sync. Vor der Installation siehst du, was neu ist.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Entwicklungs-Build ohne Update-Funktion.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
