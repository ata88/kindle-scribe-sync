import AppKit
import Combine
import KSSCore
import SwiftUI
import UniformTypeIdentifiers

/// Live recognition text, observed only by the few views that display it.
@MainActor
final class LivePreview: ObservableObject {
    @Published var value: (notebookID: String, page: Int, text: String)?
}

enum SidebarItem: Hashable {
    case all, recent, tasks, review
    case folder(String)

    var title: String {
        switch self {
        case .all: return L("Alle Notizbücher")
        case .recent: return L("Zuletzt geändert")
        case .tasks: return L("Aufgaben")
        case .review: return L("Zu prüfen")
        case .folder(let path): return path.components(separatedBy: "/").last ?? path
        }
    }

    var symbol: String {
        switch self {
        case .all: return "books.vertical"
        case .recent: return "clock"
        case .tasks: return "checklist"
        case .review: return "text.badge.checkmark"
        case .folder: return "folder"
        }
    }
}

/// Something the user should know or do – shown in the sidebar status area.
enum Attention: Hashable, Identifiable {
    case signIn(String)
    case modelMissing
    case error(String)
    var id: String {
        switch self {
        case .signIn: return "signIn"
        case .modelMissing: return "model"
        case .error(let e): return "error-\(e)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let log = EventLog(capacity: 3000, fileURL: AppPaths.logFile)
    let settings = AppSettings()
    let auth: AmazonAuth
    let models: ModelManager
    let updater = UpdaterController()
    let store: LibraryStore
    let power = PowerManager()
    let notifier = Notifier()
    private let scheduler = SyncScheduler()

    // navigation
    @Published var sidebar: SidebarItem? = .all
    @Published var selectedNotebookID: String?
    /// Page the reader should scroll to (set by tasks, search, notifications).
    @Published var scrollTarget: Int?
    @Published var search = ""
    @Published var showInspector = false

    // library + sync state
    @Published private(set) var notebooks: [NotebookRecord] = [] { didSet { recomputeDerived() } }
    /// Computed once per library change, not on every redraw.
    @Published private(set) var folders: [String] = []
    @Published private(set) var allTasks: [TaskItem] = []
    @Published private(set) var reviewCount = 0
    @Published private(set) var progress: SyncProgress = .idle
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncResult = ""
    @Published private(set) var lastError: String?
    @Published private(set) var modelLoaded = false
    @Published private(set) var recentEvents: [EventLog.Event] = []
    /// Text the model has read so far – separate object so only the views that show it redraw.
    let live = LivePreview()
    /// A page currently being edited (for the quit prompt).
    @Published var activeEdit: (notebookID: String, page: Int, text: String)?

    private var syncTask: Task<Void, Never>?
    /// A sync was requested while one was running (e.g. model finished downloading).
    private var resyncRequested = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var lastPreviewPublish = Date.distantPast

    private init() {
        auth = AmazonAuth(log: log)
        models = ModelManager(log: log)
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
        for publisher in [auth.objectWillChange.eraseToAnyPublisher(), models.objectWillChange.eraseToAnyPublisher(),
                          settings.objectWillChange.eraseToAnyPublisher(), power.objectWillChange.eraseToAnyPublisher(),
                          updater.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        recentEvents = log.events
        reloadNotebooks()
        if selectedNotebookID == nil { selectedNotebookID = notebooks.first?.id }
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log.log(.app, L("Scribe Sync %@ gestartet · %ld GB RAM · %@", v, ModelCatalog.physicalRAMGB, power.state.description))

        power.keepAwakeOnAC = settings.keepAwakeOnAC
        power.onChange = { [weak self] state in
            guard let self else { return }
            self.log.log(.power, L("Stromquelle: %@", state.description))
            if !state.onBattery { self.syncNow(reason: L("Netzteil angeschlossen")) }
        }
        power.start()
        settings.$keepAwakeOnAC.dropFirst().sink { [weak self] on in self?.power.keepAwakeOnAC = on }.store(in: &cancellables)

        notifier.setUp()
        notifier.onOpenNotebook = { [weak self] id in self?.open(notebookID: id, page: nil) }
        models.onInstalled = { [weak self] info in
            guard let self else { return }
            self.log.log(.model, L("%@ bereit – Texterkennung startet", info.title))
            self.syncNow(reason: L("Modell bereit"))
        }

        scheduler.start(interval: { [weak self] in
            TimeInterval(max(1, self?.settings.syncIntervalMinutes ?? 5) * 60)
        }, tick: { [weak self] in
            await self?.runSync(reason: L("Zeitplan"))
        })

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.power.refresh()
                self.log.log(.power, L("Mac aufgewacht (%@)", self.power.state.description))
                try? await Task.sleep(for: .seconds(15))
                self.syncNow(reason: L("nach dem Aufwachen"))
            }
        })
        if settings.spotlight { SpotlightIndex.index(notebooks) }
        Task {
            await self.recropFiguresAfterUpdate()
            try? await Task.sleep(for: .seconds(1.5))
            self.syncNow(reason: L("Programmstart"))
        }
    }

    /// Crop logic of this version; stored figures from older versions are cropped again once.
    private static let figureCropVersion = 2

    private func recropFiguresAfterUpdate() async {
        let key = "figureCropVersion"
        guard UserDefaults.standard.integer(forKey: key) < Self.figureCropVersion else { return }
        do {
            try await makeEngine(offline: true).recropAllFigures()
            UserDefaults.standard.set(Self.figureCropVersion, forKey: key)
            reloadNotebooks()
        } catch {
            log.log(.sync, error.localizedDescription, level: .warning)
        }
    }

    func shutdown() {
        scheduler.stop()
        syncTask?.cancel()
        power.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        log.log(.app, L("Scribe Sync beendet – keine Hintergrundaktivität mehr"))
    }

    var nextScheduledSync: Date? { scheduler.nextRun }

    // MARK: navigation

    func open(notebookID: String, page: Int?) {
        if notebook(notebookID)?.status == .deleted { return }
        if case .tasks = sidebar { } else if case .review = sidebar { } else { sidebar = .all }
        selectedNotebookID = notebookID
        scrollTarget = page
        showMainWindow()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("main") }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    private func recomputeDerived() {
        folders = Array(Set(notebooks.compactMap { $0.folderPath.isEmpty ? nil : $0.folderPath.joined(separator: "/") }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        allTasks = Tasks.items(in: notebooks)
        reviewCount = notebooks.filter { $0.pages.contains { Self.needsReview($0) } }.count
    }

    /// Notebooks of the current sidebar entry, filtered by the search field.
    var listedNotebooks: [NotebookRecord] {
        var list: [NotebookRecord]
        switch sidebar ?? .all {
        case .all, .tasks: list = notebooks
        case .recent:
            let cutoff = Date().addingTimeInterval(-14 * 86_400)
            list = notebooks.filter { ($0.syncedAt ?? .distantPast) > cutoff }
                .sorted { ($0.syncedAt ?? .distantPast) > ($1.syncedAt ?? .distantPast) }
        case .review:
            list = notebooks.filter { nb in nb.pages.contains { Self.needsReview($0) } }
        case .folder(let path):
            list = notebooks.filter { $0.folderPath.joined(separator: "/") == path }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { nb in nb.title.lowercased().contains(q) || nb.pages.contains { $0.text.lowercased().contains(q) } }
    }

    static func needsReview(_ p: PageRecord) -> Bool {
        p.status == .failed || p.text.contains("[?]") || p.text.contains("[unleserlich]")
    }

    var taskItems: [TaskItem] {
        let items = allTasks
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.text.lowercased().contains(q) || $0.notebookTitle.lowercased().contains(q) }
    }

    var openTaskCount: Int { allTasks.filter { !$0.done }.count }

    // MARK: attention

    var attention: [Attention] {
        var list: [Attention] = []
        if case .needsLogin(let why) = auth.state { list.append(.signIn(why)) }
        if !ModelManager.isInstalled(settings.modelID) && models.downloading == nil { list.append(.modelMissing) }
        if let e = lastError, !isSyncing { list.append(.error(e)) }
        return list
    }

    // MARK: sync

    func syncNow(reason: String, force: Bool = false) {
        guard !isSyncing else { resyncRequested = true; return }
        syncTask = Task { await runSync(reason: reason, force: force) }
    }

    func cancelSync() { syncTask?.cancel() }

    /// Thread-safe (called from the sync engine): reads UserDefaults and IOKit directly.
    nonisolated static func recognitionPolicy(modelID: String) -> (Bool, String) {
        let d = UserDefaults.standard
        let p = PowerState.current()
        if !ModelManager.isInstalled(modelID) { return (false, L("KI-Modell nicht installiert")) }
        guard p.onBattery else { return (true, "") }
        let mode = BatteryMode(rawValue: d.string(forKey: "batteryMode") ?? "") ?? .normal
        if mode != .normal { return (false, L("Akkubetrieb – Erkennung startet am Netzteil")) }
        if p.lowPowerMode { return (false, L("Stromsparmodus aktiv")) }
        let minPct = d.integer(forKey: "minBatteryPercent")
        if let pct = p.batteryPercent, pct < minPct { return (false, L("Akku unter %ld %%", minPct)) }
        return (true, "")
    }

    static let fallbackUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private func makeEngine(offline: Bool = false) -> SyncEngine {
        let source: NotebookSource
        if !offline, let session = AmazonSession.load() {
            source = AmazonClient(jar: session.jar, marketplaceID: session.marketplaceID,
                                  userAgent: session.userAgent.isEmpty ? Self.fallbackUA : session.userAgent,
                                  onSessionChange: { jar, mp in
                                      var s = AmazonSession.load() ?? session
                                      s.jar = jar
                                      if let mp { s.marketplaceID = mp }
                                      s.save()
                                  })
        } else {
            source = OfflineSource()
        }
        let info = ModelCatalog.info(settings.modelID)
        let recognizer = MLXRecognizer(model: info) { loaded in
            Task { @MainActor in AppModel.shared.modelLoaded = loaded }
        }
        let account = settings.notesAccount
        return SyncEngine(
            store: store, source: source, recognizer: recognizer, images: MacImageTools(),
            notes: settings.notesEnabled ? NotesScripting(accountName: { account }) : nil,
            log: log, settings: settings.syncSettings,
            recognitionAllowed: { [modelID = info.id] in AppModel.recognitionPolicy(modelID: modelID) },
            onProgress: { p in Task { @MainActor in AppModel.shared.progress = p } },
            onChange: { nb in Task { @MainActor in AppModel.shared.updateNotebook(nb) } },
            onPartialText: { id, page, text in Task { @MainActor in AppModel.shared.publishPreview(id, page, text) } })
    }

    private struct OfflineSource: NotebookSource {
        func listItems() async throws -> [RemoteItem] { throw AmazonError.authExpired("offline") }
        func openNotebook(_ id: String) async throws -> RemoteNotebookMeta { throw AmazonError.authExpired("offline") }
        func renderNotebook(_ id: String, meta: RemoteNotebookMeta, size: RenderSize) async throws -> [Data] { [] }
    }

    private func publishPreview(_ id: String, _ page: Int, _ text: String) {
        live.value = (id, page, text)
    }

    func runSync(reason: String, force: Bool = false) async {
        guard !isSyncing else { return }
        power.refresh()
        if power.state.onBattery && settings.batteryMode == .pause && reason == L("Zeitplan") {
            log.log(.power, L("Akkubetrieb – automatischer Abgleich pausiert"))
            return
        }
        guard AmazonSession.load() != nil else {
            auth.state = .needsLogin(L("Noch nicht angemeldet"))
            return
        }
        isSyncing = true
        lastError = nil
        defer {
            isSyncing = false; progress = .idle; live.value = nil
            if resyncRequested {
                resyncRequested = false
                syncNow(reason: L("Nachholen"))
            }
        }
        let recognizedBefore = Dictionary(uniqueKeysWithValues: notebooks.map {
            ($0.id, $0.pages.filter { $0.status == .recognized }.map(\.imageHash))
        })
        log.log(.sync, L("Abgleich (%@)", reason))
        for attempt in 0..<2 {
            let engine = makeEngine()
            do {
                let report = try await engine.run(force: force)
                lastSync = Date()
                auth.state = .signedIn
                lastSyncResult = summary(report)
                if !report.errors.isEmpty { lastError = report.errors.first }
                reloadNotebooks()
                afterSync(recognizedBefore: recognizedBefore)
                return
            } catch let e as AmazonError {
                if case .authExpired = e, attempt == 0, await auth.silentRefresh() { continue }
                lastError = e.localizedDescription
                if case .authExpired = e {
                    auth.state = .needsLogin(L("Anmeldung abgelaufen"))
                    if settings.notifications {
                        notifier.notifyAttention(L("Amazon-Anmeldung abgelaufen"), L("Bitte in Scribe Sync neu anmelden."))
                    }
                }
                log.log(.sync, e.localizedDescription, level: .error)
                return
            } catch is CancellationError {
                log.log(.sync, L("Abgleich abgebrochen"))
                return
            } catch {
                lastError = error.localizedDescription
                log.log(.sync, error.localizedDescription, level: .error)
                return
            }
        }
    }

    private func afterSync(recognizedBefore: [String: [String]]) {
        if settings.spotlight { SpotlightIndex.index(notebooks) }
        guard settings.notifications else { return }
        let fresh = notebooks.compactMap { nb -> (id: String, title: String, pages: Int)? in
            let before = Set(recognizedBefore[nb.id] ?? [])
            let new = nb.pages.filter { $0.status == .recognized && !before.contains($0.imageHash) }.count
            return new > 0 ? (nb.id, nb.title, new) : nil
        }
        if !fresh.isEmpty && !NSApp.isActive { notifier.notifyRecognized(fresh) }
    }

    private func summary(_ r: SyncReport) -> String {
        var parts: [String] = []
        if r.recognizedPages > 0 { parts.append(L("%ld Seite(n) erkannt", r.recognizedPages)) }
        if r.deferredPages > 0 { parts.append(L("%ld warten", r.deferredPages)) }
        if !r.published.isEmpty { parts.append(L("%ld Notiz(en) aktualisiert", r.published.count)) }
        return parts.isEmpty ? L("Alles aktuell") : parts.joined(separator: " · ")
    }

    // MARK: library

    func reloadNotebooks() { notebooks = store.all() }

    private func updateNotebook(_ nb: NotebookRecord) {
        if let i = notebooks.firstIndex(where: { $0.id == nb.id }) {
            if nb.status == .deleted { notebooks.remove(at: i) } else if notebooks[i] != nb { notebooks[i] = nb }
        } else if nb.status != .deleted {
            notebooks = store.all()
        }
        if selectedNotebookID == nil { selectedNotebookID = nb.id }
    }

    func notebook(_ id: String?) -> NotebookRecord? { notebooks.first { $0.id == id } }

    func saveCorrection(notebookID: String, page: Int, text: String) async {
        do {
            try await makeEngine(offline: true).saveCorrection(notebookID: notebookID, pageIndex: page, text: text)
        } catch {
            lastError = error.localizedDescription
        }
        reloadNotebooks()
        if settings.spotlight { SpotlightIndex.index(notebooks.filter { $0.id == notebookID }) }
    }

    func revertCorrection(notebookID: String, page: Int) async {
        guard let ocr = notebook(notebookID)?.pages.first(where: { $0.index == page })?.ocrText else { return }
        await saveCorrection(notebookID: notebookID, page: page, text: ocr)
    }

    func setTask(_ item: TaskItem, done: Bool) {
        guard let page = notebook(item.notebookID)?.pages.first(where: { $0.index == item.pageIndex }) else { return }
        let text = Tasks.toggled(page.text, line: item.line, done: done)
        Task { await saveCorrection(notebookID: item.notebookID, page: item.pageIndex, text: text) }
    }

    func rerecognize(notebookID: String, page: Int) {
        Task {
            try? await makeEngine(offline: true).requeue(notebookID: notebookID, pageIndex: page)
            reloadNotebooks()
            syncNow(reason: L("Seite neu erkennen"))
        }
    }

    func republishAll() {
        Task {
            let engine = makeEngine(offline: true)
            for nb in notebooks { try? await engine.republish(notebookID: nb.id) }
            reloadNotebooks()
            log.log(.notes, L("Alle Notizen neu geschrieben"))
        }
    }

    func openInNotes(_ nb: NotebookRecord) {
        guard let id = nb.noteID else { return }
        Task { await NotesScripting.show(noteID: id) }
    }

    func exportMarkdown(_ nb: NotebookRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = nb.title + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Self.markdown(nb).write(to: url, atomically: true, encoding: .utf8)
    }

    static func markdown(_ nb: NotebookRecord) -> String {
        "# \(nb.title)\n\n" + nb.pages.map { p in
            (nb.pages.count > 1 ? "## \(L("Seite %ld", p.index + 1))\n\n" : "") + p.text
        }.joined(separator: "\n\n")
    }

    // MARK: status texts

    var menuBarSymbol: String {
        if isSyncing { return "arrow.triangle.2.circlepath" }
        if !attention.isEmpty { return "exclamationmark.triangle" }
        return "pencil.and.scribble"
    }

    var statusLine: String {
        if isSyncing { return activityLine ?? L("Synchronisiere …") }
        if case .needsLogin = auth.state { return L("Anmeldung erforderlich") }
        if let lastSync {
            let f = RelativeDateTimeFormatter()
            f.locale = Loc.locale
            return L("Aktualisiert %@", f.localizedString(for: lastSync, relativeTo: Date()))
        }
        return L("Bereit")
    }

    var activityLine: String? {
        switch progress.phase {
        case .idle: return nil
        case .listing: return L("Notizbücher werden abgerufen")
        case .downloading: return L("Lade „%@“", progress.detail)
        case .recognizing:
            return L("Erkenne „%@“ · Seite %ld", progress.detail, (progress.pageIndex ?? 0) + 1)
        case .publishing: return L("Notizen: „%@“", progress.detail)
        }
    }

    var progressFraction: Double? {
        guard progress.total > 0 else { return nil }
        return min(1, Double(progress.done) / Double(progress.total))
    }
}
