import AppKit
import KSSCore
import SwiftUI
import WebKit

/// Runs requests inside Amazon's logged-in "Manage Your Content and Devices" page,
/// in an invisible web view: same cookies, same token as a click in the browser.
@MainActor
final class MYCDPage: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: WKWebViewConfiguration())
    private var navigation: CheckedContinuation<Void, Error>?
    private(set) var loadedStore: String?
    private var token: String?
    private var attempt = 0

    override init() {
        super.init()
        webView.navigationDelegate = self
    }

    /// Opens the content list; throws `needsSignIn` when Amazon shows its sign-in page.
    func open(store: String) async throws {
        token = nil
        loadedStore = nil
        attempt += 1
        let mine = attempt
        Task { @MainActor [weak self] in   // no answer from Amazon: give up instead of waiting forever
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.attempt == mine, let n = self.navigation else { return }
            self.navigation = nil
            self.webView.stopLoading()
            n.resume(throwing: KindleLibraryError.badResponse(L("keine Antwort")))
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            navigation?.resume(throwing: CancellationError())
            navigation = cont
            webView.load(URLRequest(url: KindleLibrary.pageURL(store: store, books: false)))
        }
        if KindleLibrary.isSignInPage(webView.url) { throw KindleLibraryError.needsSignIn }
        let html = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
        var found = KindleLibrary.csrfToken(inPage: html)
        if found == nil {
            found = try? await webView.evaluateJavaScript("typeof csrfToken !== 'undefined' ? String(csrfToken) : null") as? String
        }
        guard let t = found, !t.isEmpty else {
            throw KindleLibrary.isSignInPage(webView.url) ? KindleLibraryError.needsSignIn
                : KindleLibraryError.badResponse("csrfToken")
        }
        token = t
        loadedStore = store
    }

    /// POST /hz/mycd/ajax with `data` (JSON) – returns the response text.
    func post(_ data: String, store: String) async throws -> String {
        if loadedStore != store || token == nil { try await open(store: store) }
        guard let token else { throw KindleLibraryError.needsSignIn }
        let script = """
        const r = await fetch(url, {method: 'POST', credentials: 'include',
            headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', 'X-Requested-With': 'XMLHttpRequest'},
            body: body});
        return await r.text();
        """
        let result = try await webView.callAsyncJavaScript(
            script, arguments: ["url": KindleLibrary.ajaxURL(store: store).absoluteString,
                                "body": KindleLibrary.formBody(data: data, csrfToken: token)],
            in: nil, contentWorld: .page)
        guard let text = result as? String else { throw KindleLibraryError.badResponse("fetch") }
        return text
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume(); self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error); self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error); self.navigation = nil
    }
}

/// The documents and books in the Kindle library: list, delete, rename.
@MainActor
final class KindleLibraryService: ObservableObject {
    enum Phase: Equatable { case idle, loading, needsSignIn, failed(String), loaded }

    @Published var store: String {
        didSet { UserDefaults.standard.set(store, forKey: "kindleStore"); documents = []; books = []; phase = .idle }
    }
    @Published private(set) var documents: [KindleLibraryItem] = []
    @Published private(set) var books: [KindleLibraryItem] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loadedAt: Date?
    @Published private(set) var busy: Set<String> = []   // ASINs with an action running
    @Published var showSignIn = false

    private let page = MYCDPage()
    private let log: EventLog
    private weak var sender: SendToKindleService?

    init(log: EventLog, sender: SendToKindleService) {
        self.log = log
        self.sender = sender
        store = UserDefaults.standard.string(forKey: "kindleStore") ?? Self.defaultStore
    }

    static var defaultStore: String {
        switch Locale.current.region?.identifier ?? "" {
        case "DE", "AT", "CH", "LI", "LU": return "amazon.de"
        case "GB", "IE": return "amazon.co.uk"
        case "FR", "BE": return "amazon.fr"
        case "IT": return "amazon.it"
        case "ES": return "amazon.es"
        case "NL": return "amazon.nl"
        case "CA": return "amazon.ca"
        case "AU": return "amazon.com.au"
        case "JP": return "amazon.co.jp"
        default: return "amazon.com"
        }
    }

    func reload() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            documents = try await fetchAll(.document, batch: 18)
            books = try await fetchAll(.book, batch: 100)
            phase = .loaded
            loadedAt = Date()
            log.log(.amazon, L("Kindle-Bibliothek geladen: %ld Dokumente, %ld Bücher", documents.count, books.count))
        } catch KindleLibraryError.needsSignIn {
            phase = .needsSignIn
        } catch {
            phase = .failed(error.localizedDescription)
            log.log(.amazon, L("Kindle-Bibliothek: %@", error.localizedDescription), level: .warning)
        }
    }

    private func fetchAll(_ kind: KindleLibraryItem.Kind, batch: Int) async throws -> [KindleLibraryItem] {
        var all: [KindleLibraryItem] = []
        var start = 0
        while true {
            let text = try await page.post(KindleLibrary.listRequest(kind: kind, startIndex: start, batchSize: batch), store: store)
            let p = try KindleLibrary.parseList(text, kind: kind)
            all += p.items
            guard p.hasMore, !p.items.isEmpty, all.count < 5000 else { break }
            start += batch
        }
        return all
    }

    func delete(_ item: KindleLibraryItem) async throws {
        busy.insert(item.asin)
        defer { busy.remove(item.asin) }
        let text = try await page.post(KindleLibrary.deleteRequest(asin: item.asin, category: item.category), store: store)
        try KindleLibrary.parseDelete(text)
        documents.removeAll { $0.asin == item.asin }
        books.removeAll { $0.asin == item.asin }
        log.log(.amazon, L("„%@“ aus der Kindle-Bibliothek gelöscht", item.title))
    }

    /// Amazon cannot rename documents: send the original again under the new title,
    /// then delete the old entry once the new one went out.
    func rename(_ item: KindleLibraryItem, to title: String, author: String, original: URL) {
        guard let sender else { return }
        busy.insert(item.asin)
        sender.enqueue([original], title: title, author: author) { [weak self] ok in
            guard let self else { return }
            Task { @MainActor in
                defer { self.busy.remove(item.asin) }
                guard ok else { return }
                do {
                    try await self.delete(item)
                    self.log.log(.amazon, L("„%@“ umbenannt in „%@“", item.title, title))
                    // Amazon needs a moment to list the new copy
                    try? await Task.sleep(for: .seconds(20))
                    await self.reload()
                } catch {
                    self.log.log(.amazon, L("Neue Fassung gesendet, alte nicht gelöscht: %@", error.localizedDescription),
                                 level: .warning)
                }
            }
        }
    }

    /// The original file if it was sent with Scribe Sync.
    func original(for item: KindleLibraryItem) -> URL? { sender?.archivedOriginal(title: item.title) }

    /// Demo content for the CI screenshots.
    func loadShowcase() {
        let now = Date()
        documents = [
            KindleLibraryItem(asin: "D1", title: "Projektplan Q1", author: "", kind: .document, category: "KindlePDoc",
                              acquired: now.addingTimeInterval(-3600), acquiredText: ""),
            KindleLibraryItem(asin: "D2", title: "Mietvertrag", author: "Hausverwaltung", kind: .document, category: "KindlePDoc",
                              acquired: now.addingTimeInterval(-86_400 * 3), acquiredText: ""),
            KindleLibraryItem(asin: "D3", title: "Der Prozess", author: "Franz Kafka", kind: .document, category: "KindlePDoc",
                              acquired: now.addingTimeInterval(-86_400 * 12), acquiredText: ""),
        ]
        books = [KindleLibraryItem(asin: "B1", title: "Atomic Habits", author: "James Clear", kind: .book, category: "KindleEBook",
                                   acquired: now.addingTimeInterval(-86_400 * 40), acquiredText: "")]
        phase = .loaded
        loadedAt = now
    }

    // MARK: sign-in

    func signedIn() {
        showSignIn = false
        Task { await reload() }
    }
}

// MARK: - Sign-in sheet for the content page

struct KindleLibrarySignInView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Bei %@ anmelden", model.kindleLibrary.store)).font(.headline)
                    Text(L("Amazons Seite „Inhalte und Geräte verwalten“. Scribe Sync liest dort deine Kindle-Bibliothek."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Abbrechen")) { model.kindleLibrary.showSignIn = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ContentPageWebView(start: KindleLibrary.pageURL(store: model.kindleLibrary.store, books: false)) {
                model.kindleLibrary.signedIn()
            }
        }
        .frame(width: 560, height: 740)
    }
}

private struct ContentPageWebView: NSViewRepresentable {
    let start: URL
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: start))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onDone: () -> Void
        private var done = false
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // back on the content list after signing in
            guard !done, let url = webView.url, url.path.contains("/hz/mycd"), !KindleLibrary.isSignInPage(url) else { return }
            done = true
            onDone()
        }
    }
}
