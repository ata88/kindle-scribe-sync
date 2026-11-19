import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Kindle-for-Web notebook API (unofficial). Scribe notebooks of every account
// (incl. amazon.de) are served by read.amazon.com:
//
//   GET /kindle-notebook/api/notes                    -> folder/notebook tree
//   GET /openNotebook?notebookId=..&marketplaceId=..  -> metadata + renderingToken
//   GET /renderPage?startPage=..&endPage=..&width=..&height=..&dpi=..
//       header x-amzn-karamel-notebook-rendering-token -> tar of PNG pages

public enum AmazonError: Error, LocalizedError, Equatable {
    case authExpired(String)
    case http(Int, String)
    case network(String)
    case format(String)

    public var errorDescription: String? {
        switch self {
        case .authExpired(let m): return L("Amazon-Anmeldung abgelaufen (%@)", m)
        case .http(let code, let m): return L("Amazon HTTP %ld: %@", code, m)
        case .network(let m): return L("Netzwerkfehler: %@", m)
        case .format(let m): return L("Unerwartete Antwort von Amazon: %@", m)
        }
    }
}

public struct StoredCookie: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?

    public init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires
    }

    func matches(host: String, path requestPath: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let hostOK = host == d || host.hasSuffix("." + d)
        return hostOK && requestPath.hasPrefix(path.isEmpty ? "/" : path)
    }
}

public struct CookieJar: Codable, Hashable, Sendable {
    public var cookies: [StoredCookie]

    public init(_ cookies: [StoredCookie] = []) { self.cookies = cookies }

    public func header(for url: URL, now: Date = Date()) -> String? {
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let valid = cookies.filter { ($0.expires ?? .distantFuture) > now && $0.matches(host: host, path: path) }
        return valid.isEmpty ? nil : valid.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Merge cookies set by a response. Returns true if anything changed.
    @discardableResult
    public mutating func merge(_ new: [StoredCookie]) -> Bool {
        var changed = false
        for c in new {
            if let i = cookies.firstIndex(where: { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }) {
                if cookies[i] != c { cookies[i] = c; changed = true }
            } else {
                cookies.append(c); changed = true
            }
        }
        return changed
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]  // lower-cased keys
    public var body: Data
    public var setCookies: [StoredCookie]

    public init(status: Int, headers: [String: String], body: Data, setCookies: [StoredCookie] = []) {
        self.status = status; self.headers = headers; self.body = body; self.setCookies = setCookies
    }
}

public protocol HTTPTransport: Sendable {
    /// GET without following redirects.
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// URLSession transport that never follows redirects (a redirect to the
/// sign-in page means the session expired).
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public init(timeout: TimeInterval = 30) {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AmazonError.network("keine HTTP-Antwort") }
        var lower: [String: String] = [:]
        var raw: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { lower[k.lowercased()] = v; raw[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: raw, for: url).map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate)
        }
        return HTTPResponse(status: http.statusCode, headers: lower, body: data, setCookies: cookies)
    }
}

public protocol NotebookSource: Sendable {
    func listItems() async throws -> [RemoteItem]
    func openNotebook(_ id: String) async throws -> RemoteNotebookMeta
    func renderNotebook(_ id: String, meta: RemoteNotebookMeta, size: RenderSize) async throws -> [Data]
}

public struct RenderSize: Sendable, Hashable {
    public var width: Int, height: Int, dpi: Int
    public init(width: Int = 1240, height: Int = 1754, dpi: Int = 150) {
        self.width = width; self.height = height; self.dpi = dpi
    }
}

public actor AmazonClient: NotebookSource {
    public static let defaultBaseURL = URL(string: "https://read.amazon.com")!
    /// US first, then Germany, then the rest – an amazon.de account on
    /// read.amazon.com may need the German marketplace id for openNotebook.
    public static let marketplaceIDs = [
        "ATVPDKIKX0DER", "A1PA6795UKMFR9", "A1F83G8C2ARO7P", "A13V1IB3VIYZZH", "A1RKKUPIHCS9HS",
        "APJ6JRA9NG5V4", "A2EUQ1WTGCTBG2", "A39IBJ37TRP1C6", "A1VC38T7YXB528",
    ]
    static let tokenHeader = "x-amzn-karamel-notebook-rendering-token"
    static let chunk = 3

    public private(set) var jar: CookieJar
    public private(set) var marketplaceID: String?
    private let base: URL
    private let transport: HTTPTransport
    private let userAgent: String
    private let requestDelay: Duration
    private let onSessionChange: @Sendable (CookieJar, String?) -> Void
    private var lastRequest: ContinuousClock.Instant?

    public init(jar: CookieJar, marketplaceID: String? = nil, userAgent: String,
                base: URL = AmazonClient.defaultBaseURL, transport: HTTPTransport = URLSessionTransport(),
                requestDelay: Duration = .milliseconds(400),
                onSessionChange: @escaping @Sendable (CookieJar, String?) -> Void = { _, _ in }) {
        self.jar = jar; self.marketplaceID = marketplaceID; self.userAgent = userAgent
        self.base = base; self.transport = transport; self.requestDelay = requestDelay
        self.onSessionChange = onSessionChange
    }

    // MARK: plumbing

    private func throttle() async throws {
        if let last = lastRequest {
            let wait = requestDelay - (ContinuousClock.now - last)
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastRequest = .now
    }

    func get(_ pathAndQuery: String, extraHeaders: [String: String] = [:], expectJSON: Bool = true,
             retries: Int = 2) async throws -> HTTPResponse {
        guard let url = URL(string: pathAndQuery, relativeTo: base)?.absoluteURL else {
            throw AmazonError.format("ungültige URL \(pathAndQuery)")
        }
        var headers = ["User-Agent": userAgent, "Accept-Language": "de-DE,de;q=0.9,en;q=0.8"]
        if expectJSON { headers["Accept"] = "application/json" }
        headers.merge(extraHeaders) { $1 }
        var attempt = 0
        while true {
            try await throttle()
            if let cookie = jar.header(for: url) { headers["Cookie"] = cookie } else { headers["Cookie"] = nil }
            let r: HTTPResponse
            do {
                r = try await transport.get(url, headers: headers)
            } catch let e as AmazonError {
                throw e
            } catch {
                if attempt < retries { attempt += 1; try await Task.sleep(for: .seconds(1 << attempt)); continue }
                throw AmazonError.network(error.localizedDescription)
            }
            if jar.merge(r.setCookies) { onSessionChange(jar, marketplaceID) }
            if [429, 500, 502, 503, 504].contains(r.status), attempt < retries {
                attempt += 1; try await Task.sleep(for: .seconds(1 << attempt)); continue
            }
            if (300..<400).contains(r.status) {
                let loc = r.headers["location"] ?? ""
                if loc.contains("/ap/") || loc.contains("signin") || loc.contains("landing") {
                    throw AmazonError.authExpired("Weiterleitung zur Anmeldung")
                }
                throw AmazonError.http(r.status, "Weiterleitung nach \(loc)")
            }
            if r.status == 401 || r.status == 403 { throw AmazonError.authExpired("HTTP \(r.status)") }
            if r.status >= 400 {
                throw AmazonError.http(r.status, String(decoding: r.body.prefix(160), as: UTF8.self))
            }
            if expectJSON, (r.headers["content-type"] ?? "").contains("html") {
                throw AmazonError.authExpired("Anmeldeseite statt Daten erhalten")
            }
            return r
        }
    }

    // MARK: API

    public func listItems() async throws -> [RemoteItem] {
        let r = try await get("/kindle-notebook/api/notes")
        guard let json = try? JSONSerialization.jsonObject(with: r.body) else {
            throw AmazonError.format("Notizbuchliste ist kein JSON")
        }
        let nodes: [[String: Any]]
        if let dict = json as? [String: Any], let list = dict["itemsList"] as? [[String: Any]] {
            nodes = list
        } else if let list = json as? [[String: Any]] {
            nodes = list
        } else {
            throw AmazonError.format("itemsList fehlt")
        }
        var out: [RemoteItem] = []
        func walk(_ nodes: [[String: Any]], _ path: [String]) {
            for n in nodes {
                let title = ((n["title"] as? String) ?? "Unbenannt").trimmingCharacters(in: .whitespacesAndNewlines)
                let children = n["items"] as? [[String: Any]] ?? []
                if (n["type"] as? String) == "folder" {
                    walk(children, path + [title])
                } else if let id = n["id"] as? String {
                    var hint: String?
                    for key in ["modificationTime", "lastModified", "lastModifiedTime", "updatedTime", "modifiedTime"] {
                        if let v = n[key], !(v is NSNull) { hint = "\(v)"; break }
                    }
                    out.append(RemoteItem(id: id, title: title.isEmpty ? "Unbenannt" : title, folderPath: path, modifiedHint: hint))
                    if !children.isEmpty { walk(children, path) }
                }
            }
        }
        walk(nodes, [])
        return out
    }

    public func openNotebook(_ id: String) async throws -> RemoteNotebookMeta {
        var candidates = [marketplaceID].compactMap { $0 } + Self.marketplaceIDs
        candidates = candidates.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        var lastError: Error = AmazonError.format("openNotebook fehlgeschlagen")
        for mp in candidates {
            let known = (mp == marketplaceID)
            do {
                let r = try await get("/openNotebook?notebookId=\(encoded)&marketplaceId=\(mp)",
                                      retries: known ? 2 : 0)
                guard let obj = try JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                      let token = obj["renderingToken"] as? String, !token.isEmpty else {
                    lastError = AmazonError.format("openNotebook ohne renderingToken")
                    continue
                }
                let meta = obj["metadata"] as? [String: Any] ?? [:]
                if !known {
                    marketplaceID = mp
                    onSessionChange(jar, mp)
                }
                return RemoteNotebookMeta(
                    title: meta["title"] as? String ?? "",
                    totalPages: (meta["totalPages"] as? Int) ?? Int("\(meta["totalPages"] ?? 0)") ?? 0,
                    modificationTime: meta["modificationTime"].map { "\($0)" } ?? "",
                    renderingToken: token)
            } catch let e as AmazonError {
                // a 403 for a known-good marketplace really means the session is gone
                if case .authExpired = e, known { throw e }
                lastError = e
            }
        }
        throw lastError
    }

    public func renderRange(token: String, start: Int, end: Int, size: RenderSize) async throws -> [Data] {
        let r = try await get(
            "/renderPage?startPage=\(start)&endPage=\(end)&width=\(size.width)&height=\(size.height)&dpi=\(size.dpi)",
            extraHeaders: [Self.tokenHeader: token], expectJSON: false)
        do { return try Tar.pngs(r.body) } catch { throw AmazonError.format("Seiten-Archiv defekt") }
    }

    public func renderNotebook(_ id: String, meta: RemoteNotebookMeta, size: RenderSize) async throws -> [Data] {
        var token = meta.renderingToken
        var pages: [Int: Data] = [:]
        var start = 0
        while start < meta.totalPages {
            let end = min(start + Self.chunk - 1, meta.totalPages - 1)
            let pngs: [Data]
            do {
                pngs = try await renderRange(token: token, start: start, end: end, size: size)
            } catch AmazonError.authExpired {
                token = try await openNotebook(id).renderingToken  // tokens are short-lived
                pngs = try await renderRange(token: token, start: start, end: end, size: size)
            }
            for (k, png) in pngs.prefix(end - start + 1).enumerated() { pages[start + k] = png }
            start = end + 1
        }
        for i in 0..<meta.totalPages where pages[i] == nil {
            if let png = try await renderRange(token: token, start: i, end: i, size: size).first { pages[i] = png }
        }
        guard pages.count == meta.totalPages else {
            throw AmazonError.format("\(pages.count) von \(meta.totalPages) Seiten erhalten")
        }
        return (0..<meta.totalPages).map { pages[$0]! }
    }
}
