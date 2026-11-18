import AppKit
import Combine
import KSSCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let log = EventLog(capacity: 3000, fileURL: AppPaths.logFile)
    let settings = AppSettings()
    let auth: AmazonAuth
    let models: ModelManager
    let updater = UpdaterController()
    let store: LibraryStore

    @Published private(set) var notebooks: [NotebookRecord] = []
    @Published var selectedNotebookID: String?
    /// Unsaved edits: notebook id -> page index -> text
    @Published private(set) var drafts: [String: [Int: String]] = [:]
    @Published private(set) var progress: SyncProgress = .idle
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncResult = ""
    @Published private(set) var lastError: String?
    @Published private(set) var modelLoaded = false
    @Published private(set) var power = PowerState.current()
    @Published private(set) var recentEvents: [EventLog.Event] = []
    @Published private(set) var nextScheduledSync: Date?

    private var scheduler: NSBackgroundActivityScheduler?
    private var syncTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private init() {
        auth = AmazonAuth(log: log)
        models = ModelManager(log: log)
        // a broken library folder must not crash the app: fall back to a temp dir and say so
        if let s = try? LibraryStore(root: AppPaths.library) {
            store = s
        } else {
            store = try! LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("ScribeSync"))
        }
        log.observe { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.recentEvents.append(event)
                if self.recentEvents.count > 3000 { self.recentEvents.removeFirst(500) }
            }
        }
        // forward nested observable changes so views refresh
        auth.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        models.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        recentEvents = log.events
        reloadNotebooks()
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log.log(.app, "Scribe Sync \(v) gestartet · \(ModelCatalog.physicalRAMGB) GB RAM · \(power.description)")
        if !ModelManager.isInstalled(settings.modelID) {
            log.log(.model, "KI-Modell noch nicht installiert – Einstellungen › Texterkennung", level: .warning)
        }
        scheduleBackgroundSync()

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.power = PowerState.current()
                self.log.log(.power, "Mac aufgewacht (\(self.power.description))")
                // a user-initiated wake: catch up shortly after, never wake the Mac ourselves
                try? await Task.sleep(for: .seconds(20))
                self.syncNow(reason: "nach dem Aufwachen")
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.power = PowerState.current() }
        })
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.syncNow(reason: "Programmstart")
        }
    }

    func shutdown() {
        scheduler?.invalidate()
        scheduler = nil
        syncTask?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        log.log(.app, "Scribe Sync beendet – keine Hintergrundaktivität mehr")
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Scribe Sync" }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// macOS decides the exact moment (energy, thermal state, user activity) and
    /// never wakes a sleeping Mac for it. Only runs while the app runs.
    func scheduleBackgroundSync() {
        scheduler?.invalidate()
        let s = NSBackgroundActivityScheduler(identifier: "io.github.ata88.scribesync.sync")
        s.repeats = true
        s.interval = TimeInterval(max(1, settings.syncIntervalMinutes) * 60)
        s.tolerance = min(120, s.interval / 4)
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else { completion(.finished); return }
                if s.shouldDefer { completion(.deferred); return }
                await self.runSync(reason: "Zeitplan")
                self.nextScheduledSync = Date().addingTimeInterval(s.interval)
                completion(.finished)
            }
        }
        scheduler = s
        nextScheduledSync = Date().addingTimeInterval(s.interval)
        log.log(.sync, "Automatischer Sync alle \(settings.syncIntervalMinutes) Min. (macOS wählt den energiegünstigsten Moment)")
    }

    // MARK: sync

    func syncNow(reason: String, force: Bool = false) {
        guard !isSyncing else { return }
        syncTask = Task { await runSync(reason: reason, force: force) }
    }

    func cancelSync() { syncTask?.cancel() }

    /// Thread-safe (called from the sync engine): reads UserDefaults and IOKit directly.
    nonisolated static func recognitionPolicy(modelID: String) -> (Bool, String) {
        let d = UserDefaults.standard
        let p = PowerState.current()
        if !ModelManager.isInstalled(modelID) { return (false, "KI-Modell nicht installiert") }
        guard p.onBattery else { return (true, "") }
        let mode = BatteryMode(rawValue: d.string(forKey: "batteryMode") ?? "") ?? .normal
        if mode != .normal { return (false, "Akkubetrieb – Erkennung startet am Netzteil") }
        if p.lowPowerMode { return (false, "Stromsparmodus aktiv") }
        let minPct = d.integer(forKey: "minBatteryPercent")
        if let pct = p.batteryPercent, pct < minPct { return (false, "Akku unter \(minPct) %") }
        return (true, "")
    }

    private func makeEngine() -> SyncEngine? {
        guard let session = AmazonSession.load() else { return nil }
        let client = AmazonClient(jar: session.jar, marketplaceID: session.marketplaceID,
                                  userAgent: session.userAgent.isEmpty ? Self.fallbackUA : session.userAgent,
                                  onSessionChange: { jar, mp in
                                      var s = session
                                      s.jar = jar
                                      if let mp { s.marketplaceID = mp }
                                      s.save()
                                  })
        let modelInfo = ModelCatalog.info(settings.modelID)
        let recognizer = MLXRecognizer(model: modelInfo) { loaded in
            Task { @MainActor in AppModel.shared.modelLoaded = loaded }
        }
        let notesAccount = settings.notesAccount
        return SyncEngine(
            store: store, source: client, recognizer: recognizer, images: MacImageTools(),
            notes: settings.notesEnabled ? NotesScripting(accountName: { notesAccount }) : nil,
            log: log, settings: settings.syncSettings,
            recognitionAllowed: { [modelID = modelInfo.id] in AppModel.recognitionPolicy(modelID: modelID) },
            onProgress: { p in Task { @MainActor in AppModel.shared.progress = p } },
            onChange: { nb in Task { @MainActor in AppModel.shared.updateNotebook(nb) } })
    }

    static let fallbackUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func runSync(reason: String, force: Bool = false) async {
        guard !isSyncing else { return }
        power = PowerState.current()
        if power.onBattery && settings.batteryMode == .pause && reason == "Zeitplan" {
            log.log(.power, "Akkubetrieb – automatischer Sync pausiert")
            return
        }
        guard AmazonSession.load() != nil else {
            auth.state = .needsLogin("Noch nicht angemeldet")
            return
        }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false; progress = .idle }
        log.log(.sync, "Sync (\(reason))")
        for attempt in 0..<2 {
            guard let engine = makeEngine() else { return }
            do {
                let report = try await engine.run(force: force)
                lastSync = Date()
                auth.state = .signedIn
                lastSyncResult = summary(report)
                if !report.errors.isEmpty { lastError = report.errors.first }
                return
            } catch let e as AmazonError {
                if case .authExpired = e, attempt == 0, await auth.silentRefresh() { continue }
                lastError = e.localizedDescription
                if case .authExpired = e { auth.state = .needsLogin("Anmeldung abgelaufen") }
                log.log(.sync, e.localizedDescription, level: .error)
                return
            } catch is CancellationError {
                log.log(.sync, "Sync abgebrochen")
                return
            } catch {
                lastError = error.localizedDescription
                log.log(.sync, error.localizedDescription, level: .error)
                return
            }
        }
    }

    private func summary(_ r: SyncReport) -> String {
        var parts: [String] = []
        if r.recognizedPages > 0 { parts.append("\(r.recognizedPages) Seite(n) erkannt") }
        if r.deferredPages > 0 { parts.append("\(r.deferredPages) warten") }
        if !r.published.isEmpty { parts.append("\(r.published.count) Notiz(en) aktualisiert") }
        return parts.isEmpty ? "Alles aktuell" : parts.joined(separator: " · ")
    }

    // MARK: notebooks & corrections

    func reloadNotebooks() { notebooks = store.all() }

    private func updateNotebook(_ nb: NotebookRecord) {
        if let i = notebooks.firstIndex(where: { $0.id == nb.id }) {
            if nb.status == .deleted { notebooks.remove(at: i) } else { notebooks[i] = nb }
        } else if nb.status != .deleted {
            notebooks = store.all()
        }
    }

    func notebook(_ id: String?) -> NotebookRecord? { notebooks.first { $0.id == id } }

    func draft(notebookID: String, page: Int) -> String? { drafts[notebookID]?[page] }

    func setDraft(notebookID: String, page: Int, text: String) {
        let saved = notebook(notebookID)?.pages.first { $0.index == page }?.text
        if text == saved { drafts[notebookID]?[page] = nil } else { drafts[notebookID, default: [:]][page] = text }
        if drafts[notebookID]?.isEmpty == true { drafts[notebookID] = nil }
    }

    var hasUnsavedDrafts: Bool { !drafts.isEmpty }

    func saveAllDrafts() {
        let pending = drafts
        drafts = [:]
        Task {
            for (nbID, pages) in pending {
                for (page, text) in pages.sorted(by: { $0.key < $1.key }) {
                    await saveCorrection(notebookID: nbID, page: page, text: text)
                }
            }
        }
    }

    func saveCorrection(notebookID: String, page: Int, text: String) async {
        guard let engine = makeEngine() ?? offlineEngine() else { return }
        do {
            try await engine.saveCorrection(notebookID: notebookID, pageIndex: page, text: text)
        } catch {
            lastError = error.localizedDescription
        }
        reloadNotebooks()
    }

    func revertCorrection(notebookID: String, page: Int) async {
        guard let ocr = notebook(notebookID)?.pages.first(where: { $0.index == page })?.ocrText else { return }
        drafts[notebookID]?[page] = nil
        if drafts[notebookID]?.isEmpty == true { drafts[notebookID] = nil }
        await saveCorrection(notebookID: notebookID, page: page, text: ocr)
    }

    func rerecognize(notebookID: String, page: Int) {
        Task {
            guard let engine = makeEngine() ?? offlineEngine() else { return }
            try? await engine.requeue(notebookID: notebookID, pageIndex: page)
            reloadNotebooks()
            syncNow(reason: "Seite neu erkennen")
        }
    }

    func republishAll() {
        Task {
            guard let engine = makeEngine() ?? offlineEngine() else { return }
            for nb in notebooks { try? await engine.republish(notebookID: nb.id) }
            reloadNotebooks()
            log.log(.notes, "Alle Notizen neu geschrieben")
        }
    }

    /// For corrections while signed out: Notes publishing works without Amazon.
    private func offlineEngine() -> SyncEngine? {
        let notesAccount = settings.notesAccount
        struct NoSource: NotebookSource {
            func listItems() async throws -> [RemoteItem] { throw AmazonError.authExpired("offline") }
            func openNotebook(_ id: String) async throws -> RemoteNotebookMeta { throw AmazonError.authExpired("offline") }
            func renderNotebook(_ id: String, meta: RemoteNotebookMeta, size: RenderSize) async throws -> [Data] { [] }
        }
        return SyncEngine(store: store, source: NoSource(),
                          recognizer: MLXRecognizer(model: ModelCatalog.info(settings.modelID)) { _ in },
                          images: MacImageTools(),
                          notes: settings.notesEnabled ? NotesScripting(accountName: { notesAccount }) : nil,
                          log: log, settings: settings.syncSettings)
    }

    // MARK: status for menu bar / toolbar

    var menuBarSymbol: String {
        if isSyncing { return "arrow.triangle.2.circlepath" }
        if case .needsLogin = auth.state { return "exclamationmark.triangle" }
        if lastError != nil { return "exclamationmark.triangle" }
        return "pencil.and.scribble"
    }

    var statusLine: String {
        if isSyncing { return "Synchronisiere …" }
        if case .needsLogin(let why) = auth.state { return "Amazon: \(why)" }
        if let lastSync {
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: "de_DE")
            return "Zuletzt synchronisiert \(f.localizedString(for: lastSync, relativeTo: Date()))"
        }
        return "Bereit"
    }

    var progressLine: String? {
        switch progress.phase {
        case .idle: return lastError ?? (lastSyncResult.isEmpty ? nil : lastSyncResult)
        case .listing: return "Notizbücher werden abgerufen"
        case .downloading: return "Lade „\(progress.detail)“"
        case .recognizing: return "Erkenne \(progress.detail) (\(progress.done + 1)/\(progress.total))"
        case .publishing: return "Apple Notes: „\(progress.detail)“"
        }
    }
}
