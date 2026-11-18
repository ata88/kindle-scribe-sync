import KSSCore
import SwiftUI

/// First-run setup: three clear steps, each turns green when done.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    private var signedIn: Bool {
        if case .needsLogin = model.auth.state { return false }
        return AmazonSession.load() != nil
    }
    private var modelReady: Bool { ModelManager.isInstalled(model.settings.modelID) }
    private var info: ModelInfo { ModelCatalog.info(model.settings.modelID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 72, height: 72)
                    Text(L("Willkommen bei Scribe Sync"))
                        .font(.system(size: 30, weight: .bold))
                    Text(L("Deine Kindle-Scribe-Notizbücher erscheinen automatisch hier und in der App Notizen – als Text zum Kopieren, Durchsuchen und Korrigieren. Die Handschrift liest eine KI direkt auf deinem Mac."))
                        .font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    StepCard(number: 1, title: L("Bei Amazon anmelden"), done: signedIn,
                             text: L("Mit deinen normalen Amazon-Zugangsdaten – auch für amazon.de-Konten.")) {
                        Button(L("Anmelden …")) { model.auth.showLogin = true }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                    StepCard(number: 2, title: L("KI-Modell laden"), done: modelReady,
                             text: L("%@ · ca. %ld GB, einmalig. Läuft komplett auf deinem Mac und ist nur während der Texterkennung im Arbeitsspeicher.",
                                     info.title, Int(info.approxGB.rounded()))) {
                        if model.models.downloading != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: model.models.progress).frame(width: 260)
                                Text(model.models.progressText).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button(L("Modell laden")) { model.models.download(info) }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                        }
                    }
                    StepCard(number: 3, title: L("Fertig"), done: !model.notebooks.isEmpty,
                             text: L("Die App gleicht ab, solange sie läuft – auch mit geschlossenem Fenster. Beenden über die Menüleiste oder das Dock.")) {
                        if model.isSyncing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.activityLine ?? L("Synchronisiere …")).font(.callout)
                            }
                        } else {
                            Button(L("Jetzt synchronisieren")) { model.syncNow(reason: L("Einrichtung")) }
                                .disabled(!signedIn)
                        }
                    }
                }
                Text(L("Tipp: In den Einstellungen kannst du festlegen, wie die App im Akkubetrieb arbeitet, und sie beim Anmelden am Mac starten."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }
}

private struct StepCard<Action: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(done ? Theme.accent : Color.secondary.opacity(0.15)).frame(width: 32, height: 32)
                if done {
                    Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !done { action.padding(.top, 4) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(done ? Theme.accent.opacity(0.4) : Theme.hairline.opacity(0.6), lineWidth: done ? 1 : 0.5))
        .animation(.snappy, value: done)
    }
}

/// The panel behind the menu bar icon.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scribe Sync").font(.headline)
                    Text(model.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.syncNow(reason: L("Menüleiste")) } label: {
                    if model.isSyncing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .buttonStyle(.borderless)
                .help(L("Jetzt synchronisieren"))
                .disabled(model.isSyncing)
            }
            if model.isSyncing, let f = model.progressFraction {
                ProgressView(value: f).controlSize(.small)
            }
            ForEach(model.attention) { AttentionCard(item: $0) }

            let recent = model.notebooks.sorted { ($0.syncedAt ?? .distantPast) > ($1.syncedAt ?? .distantPast) }.prefix(5)
            if !recent.isEmpty {
                Text(L("Zuletzt geändert")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(Array(recent)) { nb in
                        Button {
                            model.open(notebookID: nb.id, page: nil)
                            openWindow(id: "main")
                        } label: {
                            HStack {
                                Image(systemName: "book.closed").foregroundStyle(.secondary)
                                Text(nb.title).lineLimit(1)
                                Spacer()
                                if let d = nb.syncedAt {
                                    Text(d, format: .relative(presentation: .named).locale(Loc.locale))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                    }
                }
            }
            Divider()
            HStack {
                Button(L("Öffnen")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Button(L("Diagnose")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "diagnostics")
                }
                Button(L("Einstellungen")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button(L("Beenden")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 330)
    }
}
