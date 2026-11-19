import Foundation

// Amazon "Send to Kindle" – the protocol of Amazon's own Send to Kindle app for Mac
// (sign-in with OAuth2 + PKCE, register as a Send-to-Kindle client, then signed
// requests to kd.amazon.com). Reference: the open-source client "stkclient".
//
// Everything here is platform independent and tested on Linux. Crypto (SHA-256,
// randomness, RSA signing) and the actual network calls are supplied by the app.

/// A request as data, so the protocol can be tested without a network.
public struct STKRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
}

public protocol STKTransport: Sendable {
    func send(_ request: STKRequest) async throws -> HTTPResponse
    /// PUT a (possibly large) file; `progress` gets bytes sent.
    func upload(file: URL, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPResponse
}

public protocol STKCrypto: Sendable {
    func sha256(_ data: Data) -> Data
    func randomBytes(_ count: Int) -> Data
    /// RSA PKCS#1 v1.5 signature over an already computed SHA-256 digest, *without*
    /// the DigestInfo wrapper (Amazon's ADP signature format). `pkcs1DER` is the key.
    func signRawDigest(_ digest: Data, pkcs1DER: Data) throws -> Data
}

/// What Amazon hands out when this app registers as a Send-to-Kindle client.
public struct STKRegistration: Codable, Sendable, Equatable {
    public var privateKeyPEM: String
    public var adpToken: String
    public var deviceType: String
    public var userName: String
    public var userDeviceName: String
    public var homeRegion: String?
    public var registeredAt: Date

    public init(privateKeyPEM: String, adpToken: String, deviceType: String, userName: String,
                userDeviceName: String, homeRegion: String?, registeredAt: Date = Date()) {
        self.privateKeyPEM = privateKeyPEM; self.adpToken = adpToken; self.deviceType = deviceType
        self.userName = userName; self.userDeviceName = userDeviceName; self.homeRegion = homeRegion
        self.registeredAt = registeredAt
    }
}

public struct STKDevice: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var serial: String
    public var capabilities: [String: Bool]
    public var id: String { serial }

    public init(name: String, serial: String, capabilities: [String: Bool] = [:]) {
        self.name = name; self.serial = serial; self.capabilities = capabilities
    }
}

public enum STKError: Error, LocalizedError, Equatable {
    case signInIncomplete
    case notRegistered
    case http(Int, String)
    case badResponse(String)
    case badKey
    case unsupportedFormat(String)
    case tooLarge(Int64)

    public var errorDescription: String? {
        switch self {
        case .signInIncomplete: return L("Die Anmeldung wurde nicht abgeschlossen.")
        case .notRegistered: return L("Scribe Sync ist noch nicht für „Send to Kindle“ angemeldet.")
        case .http(let code, let body):
            if code == 401 || code == 403 { return L("Amazon hat die Anmeldung für „Send to Kindle“ abgelehnt – bitte neu anmelden.") }
            return L("Amazon antwortete mit Fehler %ld. %@", code, body)
        case .badResponse(let what): return L("Unerwartete Antwort von Amazon (%@).", what)
        case .badKey: return L("Der Schlüssel für „Send to Kindle“ ist ungültig – bitte neu anmelden.")
        case .unsupportedFormat(let ext): return L("„.%@“-Dateien kann „Send to Kindle“ nicht übertragen.", ext)
        case .tooLarge(let bytes): return L("Die Datei ist zu groß (%@, höchstens 200 MB).", STK.formatBytes(bytes))
        }
    }
}

public enum STK {
    // Identity of Amazon's "Send to Kindle for Mac" app.
    static let clientID = "658490dfb190e494030082836775981fa23be0c2425441860352ba0f55915b43002d"
    static let deviceType = "A1K6D1WRW0MALS"
    static let returnTo = "https://www.amazon.com/gp/sendtokindle"
    static let clientInfo: [String: String] = [
        "appName": "ShellExtension", "appVersion": "1.1.1.253",
        "os": "MacOSX_10.14.6_x64", "osArchitecture": "x64",
    ]

    /// File types Amazon accepts, by extension.
    public static let formats: Set<String> = ["epub", "pdf", "doc", "docx", "txt", "rtf", "htm", "html",
                                              "png", "gif", "jpg", "jpeg", "bmp"]
    public static let maxBytes: Int64 = 200 * 1024 * 1024

    public static func format(of file: URL) -> String? {
        let ext = file.pathExtension.lowercased()
        return formats.contains(ext) ? ext : nil
    }

    public static func formatBytes(_ b: Int64) -> String {
        b >= 1024 * 1024 ? String(format: "%.1f MB", Double(b) / 1_048_576) : String(format: "%.0f KB", Double(b) / 1024)
    }

    // MARK: sign-in (OAuth2 + PKCE)

    public struct PKCE: Sendable, Equatable {
        public var verifier: String
        public var challenge: String
    }

    public static func makePKCE(_ crypto: STKCrypto) -> PKCE {
        let verifier = base64URL(crypto.randomBytes(32))
        return PKCE(verifier: verifier, challenge: base64URL(crypto.sha256(Data(verifier.utf8))))
    }

    /// Amazon's sign-in page; it ends on `returnTo` with the authorization code in the query.
    public static func signInURL(challenge: String) -> URL {
        var c = URLComponents(string: "https://www.amazon.com/ap/signin")!
        let q: [(String, String)] = [
            ("openid.claimed_id", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2"),
            ("openid.ns", "http://specs.openid.net/auth/2.0"),
            ("openid.identity", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("openid.oa2.client_id", "device:" + clientID),
            ("openid.mode", "checkid_setup"),
            ("openid.oa2.scope", "device_auth_access"),
            ("openid.oa2.response_type", "code"),
            ("openid.oa2.code_challenge", challenge),
            ("openid.oa2.code_challenge_method", "S256"),
            ("openid.return_to", returnTo),
            ("openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0"),
            ("openid.pape.max_auth_age", "0"),
            ("accountStatusPolicy", "P1"),
            ("openid.assoc_handle", "amzn_device_na"),
            ("pageId", "amzn_device_common_dark"),
            ("disableLoginPrepopulate", "1"),
        ]
        c.queryItems = q.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }

    /// The authorization code, once the sign-in page redirected back.
    public static func authorizationCode(from url: URL) -> String? {
        guard url.absoluteString.hasPrefix(returnTo) || url.path.hasSuffix("/gp/sendtokindle") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "openid.oa2.authorization_code" }?.value
    }

    public static func tokenRequest(code: String, verifier: String) -> STKRequest {
        let body: [String: String] = [
            "app_name": "Unknown", "client_domain": "DeviceLegacy", "client_id": clientID,
            "code_algorithm": "SHA-256", "code_verifier": verifier, "requested_token_type": "access_token",
            "source_token": code, "source_token_type": "authorization_code",
        ]
        return STKRequest(method: "POST", url: URL(string: "https://api.amazon.com/auth/token")!,
                          headers: ["Accept-Language": "en-US", "x-amzn-identity-auth-domain": "api.amazon.com",
                                    "Content-Type": "application/json", "User-Agent": "Mozilla/5.0"],
                          body: try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }

    public static func accessToken(from response: HTTPResponse) throws -> String {
        try check(response)
        guard let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let token = obj["access_token"] as? String else { throw STKError.badResponse("access_token") }
        return token
    }

    /// `serial`: a random id per installation (Amazon lists it as a "Send to Kindle" client).
    public static func registerRequest(accessToken: String, serial: String, deviceName: String) -> STKRequest {
        func x(_ s: String) -> String { NotesRendererEscape.xml(s) }
        let xml = "<?xml version='1.0' encoding='UTF-8'?>\n<request><parameters>"
            + "<deviceType>\(deviceType)</deviceType><deviceSerialNumber>\(x(serial))</deviceSerialNumber>"
            + "<pid>D21NN3GG</pid><authToken>\(x(accessToken))</authToken><authTokenType>AccessToken</authTokenType>"
            + "<softwareVersion>253</softwareVersion><os_version>MacOSX_10.14.6_x64</os_version>"
            + "<device_model>\(x(deviceName))</device_model></parameters></request>"
        return STKRequest(method: "POST", url: URL(string: "https://firs-ta-g7g.amazon.com/FirsProxy/registerDeviceWithToken")!,
                          headers: ["Content-Type": "text/xml", "Accept-Language": "en-US,*", "User-Agent": "Mozilla/5.0"],
                          body: Data(xml.utf8))
    }

    public static func registration(from response: HTTPResponse, now: Date = Date()) throws -> STKRegistration {
        try check(response)
        let xml = String(decoding: response.body, as: UTF8.self)
        func tag(_ name: String) -> String? {
            guard let open = xml.range(of: "<\(name)>"), let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex)
            else { return nil }
            return NotesRendererEscape.unxml(String(xml[open.upperBound..<close.lowerBound]))
        }
        guard let key = tag("device_private_key"), let adp = tag("adp_token") else {
            throw STKError.badResponse(tag("error") ?? "device_private_key")
        }
        return STKRegistration(privateKeyPEM: key, adpToken: adp, deviceType: tag("device_type") ?? deviceType,
                               userName: tag("name") ?? tag("given_name") ?? "",
                               userDeviceName: tag("user_device_name") ?? "", homeRegion: tag("home_region"),
                               registeredAt: now)
    }

    // MARK: signed API calls

    /// "2021-10-09T05:02:38Z"
    public static func signingDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    /// X-ADP-Request-Digest: RSA signature over SHA-256 of method, path, date, body and token.
    public static func requestDigest(method: String, path: String, body: String, date: String,
                                     registration: STKRegistration, crypto: STKCrypto) throws -> String {
        let data = Data([method, path, date, body, registration.adpToken].joined(separator: "\n").utf8)
        let key = try pkcs1DER(fromPEM: registration.privateKeyPEM)
        let signature = try crypto.signRawDigest(crypto.sha256(data), pkcs1DER: key)
        return signature.base64EncodedString() + ":" + date
    }

    static func apiRequest(_ path: String, _ fields: [String: Any], registration: STKRegistration,
                           crypto: STKCrypto, now: Date) throws -> STKRequest {
        var all = fields
        all["clientInfo"] = clientInfo
        let data = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        let body = String(decoding: data, as: UTF8.self)
        let digest = try requestDigest(method: "POST", path: path, body: body, date: signingDate(now),
                                       registration: registration, crypto: crypto)
        return STKRequest(method: "POST", url: URL(string: "https://kd.amazon.com" + path)!,
                          headers: ["Accept": "application/json", "Content-Type": "application/json",
                                    "X-ADP-Request-Digest": digest, "X-ADP-Authentication-Token": registration.adpToken,
                                    "Accept-Language": "en-US,*", "User-Agent": "Mozilla/5.0"],
                          body: data)
    }

    /// The signed device-list request, for the app's self-test against the reference signature.
    public static func apiRequestForSelfTest(_ path: String, registration: STKRegistration, crypto: STKCrypto,
                                             now: Date) throws -> STKRequest {
        try apiRequest(path, [:], registration: registration, crypto: crypto, now: now)
    }

    static func check(_ r: HTTPResponse) throws {
        guard (200..<300).contains(r.status) else {
            throw STKError.http(r.status, String(String(decoding: r.body, as: UTF8.self).prefix(300)))
        }
    }

    static func json(_ r: HTTPResponse) throws -> [String: Any] {
        try check(r)
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw STKError.badResponse("JSON")
        }
        if let code = obj["statusCode"] as? Int, code != 0 {
            throw STKError.badResponse("statusCode \(code)")
        }
        return obj
    }

    // MARK: keys

    /// Accepts PKCS#1 ("RSA PRIVATE KEY") and PKCS#8 ("PRIVATE KEY") PEM; returns PKCS#1 DER.
    public static func pkcs1DER(fromPEM pem: String) throws -> Data {
        let b64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let der = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { throw STKError.badKey }
        if pem.contains("BEGIN RSA PRIVATE KEY") { return der }
        // PKCS#8: SEQUENCE { INTEGER 0, SEQUENCE { OID rsaEncryption, NULL }, OCTET STRING { PKCS#1 } }
        var r = DERReader(der)
        guard var outer = try? r.sequence() else { throw STKError.badKey }
        _ = try? outer.element(tag: 0x02)          // version
        _ = try? outer.element(tag: 0x30)          // algorithm
        guard let key = try? outer.element(tag: 0x04) else { throw STKError.badKey }
        return key
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal DER reader – just enough to unwrap a PKCS#8 key.
struct DERReader {
    private let bytes: [UInt8]
    private var pos = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    private mutating func header(expect tag: UInt8) throws -> Int {
        guard pos < bytes.count, bytes[pos] == tag else { throw STKError.badKey }
        pos += 1
        guard pos < bytes.count else { throw STKError.badKey }
        var len = Int(bytes[pos]); pos += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n > 0, n <= 4, pos + n <= bytes.count else { throw STKError.badKey }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(bytes[pos]); pos += 1 }
        }
        guard pos + len <= bytes.count else { throw STKError.badKey }
        return len
    }

    mutating func element(tag: UInt8) throws -> Data {
        let len = try header(expect: tag)
        defer { pos += len }
        return Data(bytes[pos..<pos + len])
    }

    mutating func sequence() throws -> DERReader {
        DERReader(try element(tag: 0x30))
    }
}

enum NotesRendererEscape {
    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    static func unxml(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The Send-to-Kindle client: device list and sending files.
public actor SendToKindleClient {
    private let transport: STKTransport
    private let crypto: STKCrypto
    private let registration: STKRegistration
    private let now: @Sendable () -> Date

    public init(registration: STKRegistration, transport: STKTransport, crypto: STKCrypto,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.registration = registration; self.transport = transport; self.crypto = crypto; self.now = now
    }

    /// Sign-in step 2 + 3: exchange the code and register this installation.
    public static func register(code: String, verifier: String, serial: String, deviceName: String,
                                transport: STKTransport) async throws -> STKRegistration {
        let token = try STK.accessToken(from: try await transport.send(STK.tokenRequest(code: code, verifier: verifier)))
        return try STK.registration(from: try await transport.send(
            STK.registerRequest(accessToken: token, serial: serial, deviceName: deviceName)))
    }

    public func devices() async throws -> [STKDevice] {
        let req = try STK.apiRequest("/import/kindle-doc/get-device-list", [:], registration: registration,
                                     crypto: crypto, now: now())
        let obj = try STK.json(try await transport.send(req))
        guard let list = obj["ownedDevices"] as? [[String: Any]] else { throw STKError.badResponse("ownedDevices") }
        return list.compactMap { d in
            guard let serial = d["deviceSerialNumber"] as? String else { return nil }
            return STKDevice(name: d["deviceName"] as? String ?? serial, serial: serial,
                             capabilities: d["deviceCapabilities"] as? [String: Bool] ?? [:])
        }
    }

    /// Upload a file and deliver it to the devices. Returns Amazon's id for the document.
    public func send(file: URL, to serials: [String], title: String, author: String, keepPDFLayout: Bool = true,
                     progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> String {
        guard let format = STK.format(of: file) else { throw STKError.unsupportedFormat(file.pathExtension) }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)??.int64Value ?? 0)
        guard size <= STK.maxBytes else { throw STKError.tooLarge(size) }

        let up = try STK.json(try await transport.send(try STK.apiRequest(
            "/import/upload-url", ["fileSize": size], registration: registration, crypto: crypto, now: now())))
        guard let uploadURL = (up["uploadUrl"] as? String).flatMap(URL.init(string:)),
              let token = up["stkToken"] as? String else { throw STKError.badResponse("uploadUrl") }

        try STK.check(try await transport.upload(file: file, to: uploadURL, progress: progress))

        let fields: [String: Any] = [
            "documentMetadata": ["author": author, "crc32": 0, "inputFormat": format, "title": title] as [String: Any],
            "archive": true,
            "fileSize": size,
            "forceConvert": format == "pdf" ? !keepPDFLayout : false,
            "sendTimeMillis": Int64(now().timeIntervalSince1970 * 1000),
            "shouldExtractWebContent": false,
            "stkToken": token,
            "targetDevices": serials,
        ]
        let sent = try STK.json(try await transport.send(try STK.apiRequest(
            "/import/kindle-doc/send-to-kindle", fields, registration: registration, crypto: crypto, now: now())))
        return sent["sku"] as? String ?? ""
    }
}
