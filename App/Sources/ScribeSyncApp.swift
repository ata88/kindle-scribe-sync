import AppKit
import KSSCore
import SwiftUI

@main
struct ScribeSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Scribe Sync", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
                .tint(Theme.accent)
        }
        .defaultSize(WindowSizing.main)
        .commands { AppCommands(model: model) }

        Window(L("Diagnose"), id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
                .tint(Theme.accent)
        }
        .defaultSize(WindowSizing.diagnostics)

        Settings {
            SettingsView()
                .environmentObject(model)
                .tint(Theme.accent)
        }

        MenuBarExtra {
            MenuBarPanel().environmentObject(model).tint(Theme.accent)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("Nach Updates suchen …")) { model.updater.checkForUpdates() }
                .disabled(!model.updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu(L("Abgleich")) {
            Button(L("Jetzt synchronisieren")) { model.syncNow(reason: L("manuell")) }
                .keyboardShortcut("r")
                .disabled(model.isSyncing)
            Button(L("Abgleich abbrechen")) { model.cancelSync() }
                .disabled(!model.isSyncing)
            Divider()
            Button(L("Diagnose")) { openWindow(id: "diagnostics") }
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button(L("Original ein-/ausblenden")) { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
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
        if let dir = Screenshots.requestedDirectory {
            Task { @MainActor in await Screenshots.run(into: dir) }
            return
        }
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in AppModel.shared.showMainWindow() } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if let edit = model.activeEdit {
            let alert = NSAlert()
            alert.messageText = L("Ungesicherte Korrektur")
            alert.informativeText = L("Soll deine Korrektur vor dem Beenden gesichert werden?")
            alert.addButton(withTitle: L("Sichern und beenden"))
            alert.addButton(withTitle: L("Verwerfen"))
            alert.addButton(withTitle: L("Abbrechen"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    await model.saveCorrection(notebookID: edit.notebookID, page: edit.page, text: edit.text)
                    model.activeEdit = nil
                    model.shutdown()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        model.shutdown()
        return .terminateNow
    }
}

/// Default window sizes that always fit the screen – a window taller than the
/// display would otherwise be laid out with its top and bottom cut off.
enum WindowSizing {
    static func fitted(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        guard let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: min(width, (screen.width * 0.92).rounded()),
                      height: min(height, (screen.height * 0.92).rounded()))
    }
    static var main: CGSize { fitted(1320, 840) }
    static var diagnostics: CGSize { fitted(980, 720) }
}
