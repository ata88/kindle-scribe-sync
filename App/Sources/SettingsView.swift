import KSSCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("Allgemein"), systemImage: "gearshape") }
            SyncSettingsView().tabItem { Label(L("Abgleich"), systemImage: "arrow.triangle.2.circlepath") }
            RecognitionSettings().tabItem { Label(L("Texterkennung"), systemImage: "cpu") }
            NotesSettings().tabItem { Label(L("Notizen"), systemImage: "note.text") }
            AccountSettings().tabItem { Label("Amazon", systemImage: "person.crop.circle") }
            UpdateSettings().tabItem { Label(L("Updates"), systemImage: "arrow.down.circle") }
        }
        .environmentObject(model)
        .frame(width: 600)
        .frame(minHeight: 420)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section {
                Picker(L("Sprache"), selection: Binding(get: { model.settings.language },
                                                       set: { model.settings.language = $0; languageChanged = true })) {
                    Text(L("Wie macOS")).tag(AppLanguage.system)
                    Text("Deutsch").tag(AppLanguage.de)
                    Text("English").tag(AppLanguage.en)
                }
                if languageChanged {
                    HStack {
                        Text(L("Menüs wechseln nach einem Neustart der App.")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Jetzt neu starten")) { relaunch() }.controlSize(.small)
                    }
                }
            }
            Section {
                Toggle(L("Beim Anmelden am Mac öffnen"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.log.log(.app, L("Anmeldeobjekt: %@", error.localizedDescription), level: .warning)
                        }
                    }
                Text(L("Startet die App selbst – sichtbar in Dock und Menüleiste. Es gibt keinen versteckten Hintergrunddienst."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Mitteilung bei neu erkannten Seiten"), isOn: Binding(get: { model.settings.notifications }, set: { on in
                    model.settings.notifications = on
                    if on { Task { _ = await model.notifier.requestAuthorization() } }
                }))
                Toggle(L("In Spotlight durchsuchbar"), isOn: Binding(get: { model.settings.spotlight }, set: { on in
                    model.settings.spotlight = on
                    if on { SpotlightIndex.index(model.notebooks) } else { SpotlightIndex.removeAll() }
                }))
            }
        }
        .formStyle(.grouped)
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

struct SyncSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker(L("Abgleich alle"), selection: Binding(get: { model.settings.syncIntervalMinutes },
                                                             set: { model.settings.syncIntervalMinutes = $0 })) {
                    ForEach([2, 5, 10, 15, 30, 60], id: \.self) { m in Text(L("%ld Minuten", m)).tag(m) }
                }
                Text(L("Solange die App läuft – auch mit geschlossenem Fenster. Zusätzlich nach dem Aufwachen und beim Anschließen ans Netzteil."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Am Netzteil")) {
                Toggle(L("Mac wach halten, damit im Hintergrund abgeglichen wird"),
                       isOn: Binding(get: { model.settings.keepAwakeOnAC }, set: { model.settings.keepAwakeOnAC = $0 }))
                Text(L("So kommen neue Notizen auch dann über iCloud aufs iPhone, wenn du nicht am Mac bist. Der Bildschirm darf ausgehen. Mit zugeklapptem Deckel schläft ein MacBook trotzdem – das kann keine App ändern."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Im Akkubetrieb")) {
                Picker(L("Verhalten"), selection: Binding(get: { model.settings.batteryMode },
                                                         set: { model.settings.batteryMode = $0 })) {
                    ForEach(BatteryMode.allCases) { Text($0.label).tag($0) }
                }
                if model.settings.batteryMode == .normal {
                    Picker(L("Texterkennung erst ab"), selection: Binding(get: { model.settings.minBatteryPercent },
                                                                          set: { model.settings.minBatteryPercent = $0 })) {
                        ForEach([0, 15, 25, 40, 60], id: \.self) { p in Text(p == 0 ? L("sofort") : "\(p) %").tag(p) }
                    }
                }
                Text(L("Im Akkubetrieb wird der Mac nie geweckt oder wach gehalten. Im Stromsparmodus wartet die Texterkennung bis zum Netzteil."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct RecognitionSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { info in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: model.settings.modelID == info.id ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(model.settings.modelID == info.id ? Theme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(info.title).font(.headline)
                                if info.id == ModelCatalog.recommended.id { Pill(text: L("empfohlen"), tint: Theme.accent) }
                            }
                            Text(info.note).font(.caption).foregroundStyle(.secondary)
                            Text(L("ca. %@ GB · ab %ld GB RAM", String(format: "%.1f", info.approxGB), info.minRAMGB))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        modelButton(info)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.settings.modelID = info.id }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text(L("Die Modelle laufen vollständig auf deinem Mac. Geladen wird nur, während neue Seiten gelesen werden – danach ist der Arbeitsspeicher sofort wieder frei."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let err = model.models.lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func modelButton(_ info: ModelInfo) -> some View {
        if model.models.downloading == info.id {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: model.models.progress).frame(width: 120)
                Button(L("Abbrechen")) { model.models.cancel() }.controlSize(.small)
            }
        } else if ModelManager.isInstalled(info.id) {
            Button(L("Löschen"), role: .destructive) { model.models.delete(info.id) }.controlSize(.small)
        } else {
            Button(L("Laden")) {
                model.settings.modelID = info.id
                model.models.download(info)
            }
            .controlSize(.small)
            .disabled(model.models.downloading != nil)
        }
    }
}

struct NotesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var accounts: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle(L("Notizbücher in der App Notizen spiegeln"), isOn: Binding(get: { model.settings.notesEnabled },
                                                                               set: { model.settings.notesEnabled = $0 }))
                Picker(L("Account"), selection: Binding(get: { model.settings.notesAccount },
                                                        set: { model.settings.notesAccount = $0 })) {
                    ForEach(Array(Set(accounts + [model.settings.notesAccount])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .task { accounts = NotesScripting.accountNames() }
                TextField(L("Ordner"), text: Binding(get: { model.settings.notesFolder }, set: { model.settings.notesFolder = $0 }))
                Toggle(L("Komplettes Seitenbild zusätzlich anhängen"), isOn: Binding(get: { model.settings.attachPageImages },
                                                                                     set: { model.settings.attachPageImages = $0 }))
            } footer: {
                Text(L("Jedes Notizbuch ist genau eine Notiz, die bei Änderungen aktualisiert wird – über iCloud auch auf iPhone und iPad. Korrekturen bitte in Scribe Sync machen: Änderungen direkt in Notizen werden beim nächsten Abgleich überschrieben."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(L("Alle Notizen jetzt neu schreiben")) { model.republishAll() }
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                switch model.auth.state {
                case .needsLogin(let why):
                    LabeledContent(L("Status"), value: why)
                    Button(L("Bei Amazon anmelden …")) { model.auth.showLogin = true }
                default:
                    LabeledContent(L("Status"), value: L("Angemeldet"))
                    if let s = AmazonSession.load() {
                        LabeledContent(L("Gesichert am"), value: s.savedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(L("Abmelden"), role: .destructive) { model.auth.signOut() }
                }
            } footer: {
                Text(L("Die Anmeldung liegt verschlüsselt im macOS-Schlüsselbund. Scribe-Notizbücher werden für alle Länder über read.amazon.com abgerufen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { model.auth.showLogin }, set: { model.auth.showLogin = $0 })) {
            AmazonLoginView().environmentObject(model)
        }
    }
}

struct UpdateSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Version"), value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                if model.updater.isAvailable {
                    Toggle(L("Automatisch nach Updates suchen"), isOn: Binding(get: { model.updater.automaticallyChecks },
                                                                              set: { model.updater.automaticallyChecks = $0 }))
                    if let d = model.updater.lastCheck {
                        LabeledContent(L("Zuletzt geprüft"), value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(L("Jetzt nach Updates suchen")) { model.updater.checkForUpdates() }
                        .disabled(!model.updater.canCheckForUpdates)
                } else {
                    Text(L("Entwicklungs-Build ohne Update-Funktion.")).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L("Updates kommen signiert aus den GitHub-Releases von ata88/kindle-scribe-sync. Vor der Installation siehst du, was neu ist."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
