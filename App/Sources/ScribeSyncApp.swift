import AppKit
import SwiftUI

@main
struct ScribeSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Scribe Sync", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 780)
        .commands { AppCommands(model: model) }

        Window("Diagnose", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 920, height: 640)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { model.updater.checkForUpdates() }
                .disabled(!model.updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Korrekturen sichern") { model.saveAllDrafts() }
                .keyboardShortcut("s")
                .disabled(!model.hasUnsavedDrafts)
        }
        CommandMenu("Sync") {
            Button("Jetzt synchronisieren") { model.syncNow(reason: "manuell") }
                .keyboardShortcut("r")
                .disabled(model.isSyncing)
            Divider()
            Button("Diagnose") { openWindow(id: "diagnostics") }
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
    }
}

/// App lifecycle: closing the window keeps the app (and its menu bar item) running;
/// Quit from the Dock or menu bar ends everything – no helper processes remain.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.requested {
            Task.detached {
                let code = await SelfTest.run()
                exit(code)
            }
            return
        }
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if model.hasUnsavedDrafts {
            let alert = NSAlert()
            alert.messageText = "Ungesicherte Korrekturen"
            alert.informativeText = "Sollen deine Korrekturen vor dem Beenden gesichert werden?"
            alert.addButton(withTitle: "Sichern und beenden")
            alert.addButton(withTitle: "Verwerfen")
            alert.addButton(withTitle: "Abbrechen")
            switch alert.runModal() {
            case .alertFirstButtonReturn: model.saveAllDrafts()
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        model.shutdown()
        return .terminateNow
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        if let detail = model.progressLine { Text(detail) }
        Divider()
        Button("Jetzt synchronisieren") { model.syncNow(reason: "Menüleiste") }
            .disabled(model.isSyncing)
        Button("Scribe Sync öffnen") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Diagnose …") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "diagnostics")
        }
        Divider()
        Button("Nach Updates suchen …") { model.updater.checkForUpdates() }
        Divider()
        Button("Scribe Sync beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
