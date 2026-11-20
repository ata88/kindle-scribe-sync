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
                .frame(minWidth: WindowSizing.mainMinimum.width, minHeight: WindowSizing.mainMinimum.height)
                .tint(Theme.accent)
        }
        .defaultSize(WindowSizing.main)
        .commands { AppCommands(model: model) }

        Window(L("Diagnose"), id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(model)
                .frame(minWidth: WindowSizing.diagnosticsMinimum.width, minHeight: WindowSizing.diagnosticsMinimum.height)
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
        if FigureLab.requested {
            Task.detached { exit(await FigureLab.run()) }
            return
        }
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

    /// Files dropped on the Dock icon or opened with Scribe Sync go to the Kindle.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !SelfTest.requested, !FigureLab.requested, Screenshots.requestedDirectory == nil else { return }
        Task { @MainActor in AppModel.shared.sendToKindle(urls) }
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
    /// Never below the content's minimum size: asking for less makes AppKit and SwiftUI
    /// disagree about the window size.
    static func fitted(_ width: CGFloat, _ height: CGFloat, minimum: CGSize) -> CGSize {
        guard let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: max(minimum.width, min(width, (screen.width * 0.92).rounded())),
                      height: max(minimum.height, min(height, (screen.height * 0.92).rounded())))
    }
    static let mainMinimum = CGSize(width: 980, height: 600)
    static let diagnosticsMinimum = CGSize(width: 820, height: 560)
    static var main: CGSize { fitted(1320, 840, minimum: mainMinimum) }
    static var diagnostics: CGSize { fitted(980, 720, minimum: diagnosticsMinimum) }
}
