import Foundation

// The Kindle library as Amazon's "Manage Your Content and Devices" page (MYCD) shows
// it: POST /hz/mycd/ajax with the form fields `data` (JSON) and `csrfToken`.
// The listing and device calls follow the open-source project Kindle_download_helper;
// deleting uses the page's own "DeleteContent" call. The app runs the requests inside
// the logged-in MYCD page (same cookies and token as a click in the browser); this
// file only builds and reads them, so it is tested on Linux.

public struct KindleLibraryItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case document, book }
    public var asin: String
    public var title: String
    public var author: String
    public var kind: Kind
    /// Amazon's category, needed to delete ("KindlePDoc", "KindleEBook" …).
    public var category: String
    public var acquired: Date?
    public var acquiredText: String
    public var id: String { asin }

    public init(asin: String, title: String, author: String, kind: Kind, category: String,
                acquired: Date?, acquiredText: String) {
        self.asin = asin; self.title = title; self.author = author; self.kind = kind
        self.category = category; self.acquired = acquired; self.acquiredText = acquiredText
    }
}

public struct KindleDeviceInfo: Hashable, Sendable {
    public var name: String
    public var serial: String
    public var type: String
}

public enum KindleLibraryError: Error, LocalizedError, Equatable {
    case needsSignIn
    case amazon(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .needsSignIn: return L("Bitte bei Amazon anmelden, um die Kindle-Bibliothek zu sehen.")
        case .amazon(let msg): return L("Amazon meldet: %@", msg)
        case .badResponse(let what): return L("Unerwartete Antwort von Amazon (%@).", what)
        }
    }
}

public enum KindleLibrary {
    /// Amazon store the Kindle is registered with, e.g. "amazon.de".
    public static let stores = ["amazon.de", "amazon.com", "amazon.co.uk", "amazon.fr", "amazon.it", "amazon.es",
                                "amazon.nl", "amazon.ca", "amazon.com.au", "amazon.co.jp"]

    public static func pageURL(store: String, books: Bool) -> URL {
        URL(string: "https://www.\(store)/hz/mycd/digital-console/contentlist/\(books ? "booksAll" : "pdocs")/dateDsc/")!
    }

    public static func ajaxURL(store: String) -> URL { URL(string: "https://www.\(store)/hz/mycd/ajax")! }

    /// The token the page embeds as `var csrfToken = "…";`.
    public static func csrfToken(inPage html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"csrfToken\s*=\s*["']([^"']+)["']"#),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    /// True when Amazon sent us to its sign-in page instead of the content list.
    public static func isSignInPage(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.path.contains("/ap/signin") || url.path.contains("/ap/mfa") || url.path.contains("/ap/cvf")
    }

    // MARK: requests (the JSON for the form field `data`)

    public static func listRequest(kind: KindleLibraryItem.Kind, startIndex: Int, batchSize: Int) -> String {
        var ownership: [String: Any] = [
            "sortOrder": "DESCENDING", "sortIndex": "DATE", "startIndex": startIndex, "batchSize": batchSize,
            "contentType": kind == .document ? "KindlePDoc" : "Ebook", "itemStatus": ["Active"],
        ]
        if kind == .book { ownership["originType"] = ["Purchase"] } else { ownership["isExtendedMYK"] = false }
        return json(["param": ["OwnershipData": ownership]])
    }

    public static func deleteRequest(asin: String, category: String) -> String {
        json(["param": ["DeleteContent": ["asinDetails": [asin: ["category": category]]]]])
    }

    public static func devicesRequest() -> String { json(["param": ["GetDevices": [String: Any]()]]) }

    /// Body for application/x-www-form-urlencoded.
    public static func formBody(data: String, csrfToken: String) -> String {
        "data=" + formEscape(data) + "&csrfToken=" + formEscape(csrfToken)
    }

    // MARK: responses

    public struct Page: Sendable {
        public var items: [KindleLibraryItem]
        public var hasMore: Bool
        public var total: Int?
    }

    public static func parseList(_ text: String, kind: KindleLibraryItem.Kind) throws -> Page {
        let obj = try object(text)
        guard let data = obj["OwnershipData"] as? [String: Any] else { throw KindleLibraryError.badResponse("OwnershipData") }
        if let e = data["error"] as? String { throw KindleLibraryError.amazon(e) }
        let raw = data["items"] as? [[String: Any]] ?? []
        let items = raw.compactMap { d -> KindleLibraryItem? in
            guard let asin = d["asin"] as? String else { return nil }
            let authors = (d["authors"] as? String) ?? (d["author"] as? String)
                ?? (d["authors"] as? [String])?.joined(separator: ", ") ?? ""
            let (date, text) = acquiredDate(d)
            return KindleLibraryItem(asin: asin, title: unescape(d["title"] as? String ?? asin),
                                     author: unescape(authors), kind: kind,
                                     category: d["category"] as? String ?? (kind == .document ? "KindlePDoc" : "KindleEBook"),
                                     acquired: date, acquiredText: text)
        }
        return Page(items: items, hasMore: data["hasMoreItems"] as? Bool ?? false, total: data["numberOfItems"] as? Int)
    }

    public static func parseDelete(_ text: String) throws {
        let obj = try object(text)
        guard let result = obj["DeleteContent"] as? [String: Any] else { throw KindleLibraryError.badResponse("DeleteContent") }
        if let e = result["error"] as? String { throw KindleLibraryError.amazon(e) }
        guard result["success"] as? Bool == true else { throw KindleLibraryError.amazon(String(text.prefix(200))) }
    }

    public static func parseDevices(_ text: String) throws -> [KindleDeviceInfo] {
        let obj = try object(text)
        guard let result = obj["GetDevices"] as? [String: Any] else { throw KindleLibraryError.badResponse("GetDevices") }
        return (result["devices"] as? [[String: Any]] ?? []).compactMap { d in
            guard let serial = d["deviceSerialNumber"] as? String else { return nil }
            return KindleDeviceInfo(name: d["deviceAccountName"] as? String ?? d["deviceName"] as? String ?? serial,
                                    serial: serial, type: d["deviceType"] as? String ?? "")
        }
    }

    // MARK: helpers

    static func object(_ text: String) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            // an HTML page instead of JSON: usually the sign-in page
            if text.contains("<html") || text.contains("ap/signin") { throw KindleLibraryError.needsSignIn }
            throw KindleLibraryError.badResponse("JSON")
        }
        if obj["success"] as? Bool == false, let e = obj["error"] as? String { throw KindleLibraryError.amazon(e) }
        return obj
    }

    static func acquiredDate(_ d: [String: Any]) -> (Date?, String) {
        if let ms = (d["acquiredTime"] as? NSNumber)?.doubleValue ?? (d["acquiredDate"] as? NSNumber)?.doubleValue {
            return (Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms), "")
        }
        let text = d["acquiredDate"] as? String ?? ""
        return (nil, text)
    }

    static func json(_ obj: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s)
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
