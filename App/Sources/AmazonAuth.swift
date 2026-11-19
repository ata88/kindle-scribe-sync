import KSSCore
import SwiftUI
import WebKit

/// Amazon sign-in with WebKit inside the app. Scribe notebooks of every account
/// (also amazon.de) are served by read.amazon.com – sign in there with the
/// normal Amazon credentials.
@MainActor
final class AmazonAuth: NSObject, ObservableObject {
    static let apiURL = URL(string: "https://read.amazon.com/kindle-notebook/api/notes")!

    enum State: Equatable {
        case unknown
        case signedIn
        case needsLogin(String)
    }

    @Published var state: State = AmazonSession.load() == nil ? .needsLogin(L("Noch nicht angemeldet")) : .unknown
    @Published var showLogin = false
    private let log: EventLog
    private var refreshView: WKWebView?
    private var refreshContinuation: CheckedContinuation<Bool, Never>?

    init(log: EventLog) { self.log = log }

    var session: AmazonSession? { AmazonSession.load() }

    /// Store cookies from WebKit after the API answered with JSON.
    fileprivate func captureSession(from webView: WKWebView) async -> Bool {
        guard let text = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["itemsList"] != nil else { return false }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { $0.domain.contains("amazon") }
            .map { StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate) }
        let ua = (try? await webView.evaluateJavaScript("navigator.userAgent") as? String) ?? ""
        let previous = AmazonSession.load()
        AmazonSession(jar: CookieJar(cookies), userAgent: ua, marketplaceID: previous?.marketplaceID, savedAt: Date()).save()
        state = .signedIn
        return true
    }

    func didLogIn() {
        showLogin = false
        log.log(.amazon, L("Bei Amazon angemeldet"))
        AppModel.shared.syncNow(reason: L("nach Anmeldung"))
    }

    func signOut() {
        AmazonSession.clear()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) {}
        state = .needsLogin(L("Abgemeldet"))
        log.log(.amazon, L("Abgemeldet, Amazon-Daten der App gelöscht"))
    }

    /// Renew the session in an invisible web view using WebKit's persistent
    /// "keep me signed in" cookies. Returns false if a manual login is needed.
    func silentRefresh() async -> Bool {
        log.log(.amazon, L("Sitzung abgelaufen – stille Erneuerung"))
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        view.navigationDelegate = self
        refreshView = view
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            refreshContinuation = cont
            view.load(URLRequest(url: Self.apiURL))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(45))
                self?.finishRefresh(false)
            }
        }
        refreshView = nil
        if ok {
            log.log(.amazon, L("Sitzung erneuert"))
        } else {
            state = .needsLogin(L("Anmeldung abgelaufen"))
            log.log(.amazon, L("Erneuerung nicht möglich – bitte neu anmelden"), level: .warning)
        }
        return ok
    }

    private func finishRefresh(_ ok: Bool) {
        refreshContinuation?.resume(returning: ok)
        refreshContinuation = nil
    }
}

extension AmazonAuth: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === refreshView else { return }
        Task { @MainActor in
            let ok = webView.url?.host == Self.apiURL.host && webView.url?.path == Self.apiURL.path
                ? await self.captureSession(from: webView) : false
            self.finishRefresh(ok)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === refreshView { finishRefresh(false) }
    }

    /// No network or DNS failure before the first byte: give up at once instead of after 45 s.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === refreshView { finishRefresh(false) }
    }
}

// MARK: - Login sheet

struct AmazonLoginView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Bei Amazon anmelden")).font(.headline)
                    Text(L("Normale Amazon-Zugangsdaten – auch für amazon.de-Konten. Bitte „Angemeldet bleiben“ ankreuzen."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Abbrechen")) { model.auth.showLogin = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            LoginWebView { model.auth.didLogIn() }
        }
        .frame(width: 520, height: 720)
    }
}

private struct LoginWebView: NSViewRepresentable {
    let onSuccess: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSuccess: onSuccess) }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: AmazonAuth.apiURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSuccess: () -> Void
        private var done = false
        init(onSuccess: @escaping () -> Void) { self.onSuccess = onSuccess }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, webView.url?.host == AmazonAuth.apiURL.host, webView.url?.path == AmazonAuth.apiURL.path else { return }
            Task { @MainActor in
                if await AppModel.shared.auth.captureSession(from: webView) {
                    self.done = true
                    self.onSuccess()
                }
            }
        }
    }
}
