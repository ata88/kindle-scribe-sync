import AppKit
import Carbon
import CryptoKit
import KSSCore
import PDFKit
import Security
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Crypto and network for the Send-to-Kindle protocol

struct MacSTKCrypto: STKCrypto {
    func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    func signRawDigest(_ digest: Data, pkcs1DER: Data) throws -> Data {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1DER as CFData, attrs as CFDictionary, &error) else {
            throw STKError.badKey
        }
        // PKCS#1 v1.5 padding over the raw digest, no DigestInfo – Amazon's ADP format
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15Raw, digest as CFData, &error) else {
            throw STKError.badKey
        }
        return sig as Data
    }
}

final class URLSessionSTKTransport: NSObject, STKTransport, URLSessionDataDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var progressHandlers: [Int: @Sendable (Int64) -> Void] = [:]

    func send(_ request: STKRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url, timeoutInterval: 60)
        r.httpMethod = request.method
        r.httpBody = request.body
        request.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: r)
        let http = resp as? HTTPURLResponse
        return HTTPResponse(status: http?.statusCode ?? 0, headers: [:], body: data)
    }

    func upload(file: URL, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPResponse {
        var r = URLRequest(url: url, timeoutInterval: 600)
        r.httpMethod = "PUT"
        r.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let task = session.uploadTask(with: r, fromFile: file)
        lock.withLock { progressHandlers[task.taskIdentifier] = progress }
        defer { _ = lock.withLock { progressHandlers.removeValue(forKey: task.taskIdentifier) } }
        let (data, resp) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                self.lock.withLock { self.completions[task.taskIdentifier] = cont }
                task.resume()
            }
        } onCancel: { task.cancel() }
        return HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, headers: [:], body: data)
    }

    // upload task plumbing (the async upload API has no progress)
    private var completions: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var received: [Int: Data] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let handler = lock.withLock { progressHandlers[task.taskIdentifier] }
        handler?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cont, data) = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), Error>?, Data) in
            (completions.removeValue(forKey: task.taskIdentifier), received.removeValue(forKey: task.taskIdentifier) ?? Data())
        }
        guard let cont else { return }
        if let error { cont.resume(throwing: error) }
        else if let resp = task.response { cont.resume(returning: (data, resp)) }
        else { cont.resume(throwing: URLError(.badServerResponse)) }
    }
}

// MARK: - Model

struct SendJob: Identifiable, Codable, Equatable {
    enum State: Codable, Equatable {
        case waiting, uploading(Double), delivering, sent, failed(String)
    }
    var id = UUID()
    var fileName: String
    var title: String
    var author: String
    var bytes: Int64
    var devices: [String]          // device names, for display
    var via: SendToKindleService.Method
    var state: State = .waiting
    var date = Date()
    /// Where the file is while it waits.
    var localPath: String?
    /// The original after sending, kept so the document can be renamed later
    /// (Amazon cannot rename: the app sends it again under the new title).
    var archivePath: String?
}

/// Everything around sending documents to the Kindle: sign-in, devices, queue, history.
@MainActor
final class SendToKindleService: ObservableObject {
    enum Method: String, Codable, CaseIterable, Identifiable {
        case app, email
        var id: String { rawValue }
        var label: String { self == .app ? L("Direkt (wie die Amazon-App)") : L("Per E-Mail über die App Mail") }
    }

    @Published private(set) var registration: STKRegistration?
    @Published private(set) var devices: [STKDevice] = []
    @Published var selectedDevices: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedDevices), forKey: "stkSelectedDevices"); resume() }
    }
    @Published var method: Method {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: "stkMethod"); resume() }
    }
    @Published var kindleEmail: String {
        didSet { UserDefaults.standard.set(kindleEmail, forKey: "stkKindleEmail") }
    }
    @Published var keepPDFLayout: Bool {
        didSet { UserDefaults.standard.set(keepPDFLayout, forKey: "stkKeepPDFLayout") }
    }
    @Published private(set) var jobs: [SendJob] = []
    @Published private(set) var lastError: String?
    @Published private(set) var loadingDevices = false
    @Published var showSignIn = false

    private let log: EventLog
    private var worker: Task<Void, Never>?
    private let transport = URLSessionSTKTransport()
    private let crypto = MacSTKCrypto()
    private static let keychainAccount = "send-to-kindle"
    private static var historyFile: URL { AppPaths.support.appendingPathComponent("send-to-kindle.json") }
    private static var archive: URL {
        let u = AppPaths.support.appendingPathComponent("Send to Kindle/Originale", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Called once a job finished (true = sent); used by "rename" to delete the old entry.
    private var finishHandlers: [UUID: (Bool) -> Void] = [:]

    private static var inbox: URL {
        let u = AppPaths.support.appendingPathComponent("Send to Kindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init(log: EventLog) {
        self.log = log
        let d = UserDefaults.standard
        selectedDevices = Set(d.stringArray(forKey: "stkSelectedDevices") ?? [])
        method = Method(rawValue: d.string(forKey: "stkMethod") ?? "") ?? .app
        kindleEmail = d.string(forKey: "stkKindleEmail") ?? ""
        keepPDFLayout = d.object(forKey: "stkKeepPDFLayout") as? Bool ?? true
        if let data = Keychain.load(account: Self.keychainAccount) {
            registration = try? JSONDecoder().decode(STKRegistration.self, from: data)
        }
        if let data = try? Data(contentsOf: Self.historyFile),
           let saved = try? JSONDecoder().decode([SendJob].self, from: data) {
            // anything that was still running when the app quit starts over
            jobs = saved.map { job in
                var j = job
                if case .uploading = j.state { j.state = .waiting }
                if j.state == .delivering { j.state = .waiting }
                return j
            }
        }
        if registration != nil { Task { await refreshDevices() } }
        if jobs.contains(where: { $0.state == .waiting }) { startWorker() }
    }

    var isReady: Bool {
        switch method {
        case .app: return registration != nil && !selectedDevices.isEmpty
        case .email: return kindleEmail.contains("@")
        }
    }

    var readinessHint: String? {
        switch method {
        case .app:
            if registration == nil { return L("Einmal bei Amazon für „Send to Kindle“ anmelden.") }
            if selectedDevices.isEmpty { return L("Mindestens ein Gerät auswählen.") }
        case .email:
            if !kindleEmail.contains("@") { return L("Deine „Send to Kindle“-E-Mail-Adresse eintragen.") }
        }
        return nil
    }

    /// Demo state for the CI screenshots (never saved, nothing is sent).
    func loadShowcase() {
        registration = STKRegistration(privateKeyPEM: "", adpToken: "", deviceType: "", userName: "Anna Muster",
                                       userDeviceName: "", homeRegion: "EU")
        devices = [STKDevice(name: "Annas Kindle Scribe", serial: "G1"), STKDevice(name: "Kindle Paperwhite", serial: "G2"),
                   STKDevice(name: "Kindle für iPhone", serial: "G3")]
        selectedDevices = ["G1"]
        worker?.cancel()
        jobs = [
            SendJob(fileName: "Atomic Habits.epub", title: "Atomic Habits", author: "James Clear", bytes: 2_430_000,
                    devices: ["Annas Kindle Scribe"], via: .app, state: .uploading(0.62)),
            SendJob(fileName: "Projektplan Q1.pdf", title: "Projektplan Q1", author: "", bytes: 840_000,
                    devices: ["Annas Kindle Scribe"], via: .app, state: .waiting),
            SendJob(fileName: "Der Prozess.epub", title: "Der Prozess", author: "Franz Kafka", bytes: 512_000,
                    devices: ["Annas Kindle Scribe"], via: .app, state: .sent, date: Date().addingTimeInterval(-3600)),
            SendJob(fileName: "Vertrag.docx", title: "Mietvertrag", author: "", bytes: 96_000,
                    devices: ["Annas Kindle Scribe"], via: .app, state: .failed(L("Amazon antwortete mit Fehler %ld. %@", 500, ""))),
        ]
        worker?.cancel()
    }

    // MARK: sign-in

    private var pendingPKCE: STK.PKCE?

    func beginSignIn() -> URL {
        let pkce = STK.makePKCE(crypto)
        pendingPKCE = pkce
        return STK.signInURL(challenge: pkce.challenge)
    }

    func finishSignIn(code: String) async {
        guard let pkce = pendingPKCE else { return }
        pendingPKCE = nil
        do {
            let reg = try await SendToKindleClient.register(code: code, verifier: pkce.verifier, serial: Self.installationSerial(),
                                                            deviceName: L("Scribe Sync auf %@", Host.current().localizedName ?? "Mac"),
                                                            transport: transport)
            Keychain.save(try JSONEncoder().encode(reg), account: Self.keychainAccount)
            registration = reg
            lastError = nil
            log.log(.amazon, L("Für „Send to Kindle“ angemeldet (%@)", reg.userName))
            await refreshDevices()
            resume()
        } catch {
            lastError = error.localizedDescription
            log.log(.amazon, L("„Send to Kindle“-Anmeldung fehlgeschlagen: %@", error.localizedDescription), level: .error)
        }
    }

    func signOut() {
        Keychain.delete(account: Self.keychainAccount)
        registration = nil
        devices = []
        log.log(.amazon, L("Von „Send to Kindle“ abgemeldet"))
    }

    /// A stable random id for this Mac, shown by Amazon as one "Send to Kindle" client.
    private static func installationSerial() -> String {
        let key = "stkSerial"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let s = String((0..<32).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(s, forKey: key)
        return s
    }

    func refreshDevices() async {
        guard let reg = registration else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        do {
            let list = try await SendToKindleClient(registration: reg, transport: transport, crypto: crypto).devices()
            devices = list
            // first time: preselect a Scribe (or the only device)
            if selectedDevices.isEmpty {
                let scribe = list.filter { $0.name.localizedCaseInsensitiveContains("scribe") }
                selectedDevices = Set((scribe.isEmpty ? (list.count == 1 ? list : []) : scribe).map(\.serial))
            }
            selectedDevices = selectedDevices.intersection(list.map(\.serial))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.log(.amazon, L("Kindle-Geräte konnten nicht geladen werden: %@", error.localizedDescription), level: .warning)
        }
    }

    // MARK: queue

    /// Files dropped or opened: copied into the app's inbox, then sent one after another.
    /// `title`/`author` replace what the file says (used when renaming).
    @discardableResult
    func enqueue(_ urls: [URL], title: String? = nil, author: String? = nil,
                 onFinish: ((Bool) -> Void)? = nil) -> [String] {
        var rejected: [String] = []
        for url in urls {
            guard let format = STK.format(of: url) else {
                rejected.append(L("„%@“: Dateityp wird nicht unterstützt", url.lastPathComponent)); continue
            }
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let limit = method == .email ? 50 * 1024 * 1024 : STK.maxBytes
            guard bytes <= limit else {
                rejected.append(L("„%@“ ist zu groß (%@)", url.lastPathComponent, STK.formatBytes(bytes))); continue
            }
            let id = UUID()
            let copy = Self.inbox.appendingPathComponent(id.uuidString + "." + format)
            do {
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                rejected.append(L("„%@“: %@", url.lastPathComponent, error.localizedDescription)); continue
            }
            var meta = DocumentMetadata.read(copy, fallbackName: url.deletingPathExtension().lastPathComponent)
            if let title { meta.title = title }
            if let author { meta.author = author }
            // by e-mail Amazon takes the title from the file name
            let fileName = title.map { AppModel.safeFileName($0) + "." + format } ?? url.lastPathComponent
            let names = devices.filter { selectedDevices.contains($0.serial) }.map(\.name)
            jobs.insert(SendJob(id: id, fileName: fileName, title: meta.title, author: meta.author, bytes: bytes,
                                devices: method == .email ? [kindleEmail] : names, via: method, localPath: copy.path), at: 0)
            if let onFinish { finishHandlers[id] = onFinish }
            log.log(.app, L("„%@“ wartet auf den Versand an den Kindle", meta.title))
        }
        rejected.forEach { log.log(.app, $0, level: .warning) }
        save()
        startWorker()
        return rejected
    }

    func retry(_ job: SendJob) { update(job.id) { $0.state = .waiting }; startWorker() }

    func remove(_ job: SendJob) {
        [job.localPath, job.archivePath].compactMap { $0 }.forEach { try? FileManager.default.removeItem(atPath: $0) }
        jobs.removeAll { $0.id == job.id }
        save()
    }

    /// Removes sent entries and their kept originals.
    func clearFinished() {
        jobs.filter { $0.state == .sent }.compactMap(\.archivePath).forEach { try? FileManager.default.removeItem(atPath: $0) }
        jobs.removeAll { $0.state == .sent }
        save()
    }

    /// The kept original of the last document sent under this title.
    func archivedOriginal(title: String) -> URL? {
        jobs.first { $0.state == .sent && $0.title == title && $0.archivePath.map(FileManager.default.fileExists) == true }
            .flatMap { $0.archivePath.map(URL.init(fileURLWithPath:)) }
    }

    var archiveBytes: Int64 {
        jobs.compactMap(\.archivePath).reduce(Int64(0)) { sum, p in
            sum + Int64((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)??.int64Value ?? 0)
        }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled, let self, let job = self.jobs.last(where: { $0.state == .waiting }) {
                guard self.isReady else { break }   // waits until set up; the view shows why
                await self.process(job)
            }
            self?.worker = nil
        }
    }

    /// Called when setup changed (signed in, device chosen) so waiting jobs go out.
    func resume() { startWorker() }

    private func process(_ job: SendJob) async {
        guard let path = job.localPath, FileManager.default.fileExists(atPath: path) else {
            update(job.id) { $0.state = .failed(L("Datei nicht mehr vorhanden")) }; return
        }
        let file = URL(fileURLWithPath: path)
        do {
            switch job.via {
            case .app:
                guard let reg = registration else { throw STKError.notRegistered }
                update(job.id) { $0.state = .uploading(0) }
                let client = SendToKindleClient(registration: reg, transport: transport, crypto: crypto)
                let total = Double(max(job.bytes, 1))
                let id = job.id
                let throttle = ProgressThrottle(start: 0)
                _ = try await client.send(file: file, to: Array(selectedDevices), title: job.title, author: job.author,
                                          keepPDFLayout: keepPDFLayout) { sent in
                    let p = min(1, Double(sent) / total)
                    guard throttle.shouldReport(p) else { return }
                    Task { @MainActor [weak self] in self?.update(id) { $0.state = .uploading(p) } }
                }
                update(job.id) { $0.state = .delivering }
            case .email:
                update(job.id) { $0.state = .delivering }
                try await MailSender.send(file: file, named: job.fileName, to: kindleEmail)
            }
            // keep the original (for renaming later); the inbox copy goes away
            let kept = Self.archive.appendingPathComponent(job.id.uuidString + "." + file.pathExtension)
            let archived = (try? FileManager.default.moveItem(at: file, to: kept)) != nil
            if !archived { try? FileManager.default.removeItem(at: file) }
            update(job.id) {
                $0.state = .sent
                $0.date = Date()
                $0.localPath = nil
                $0.archivePath = archived ? kept.path : nil
            }
            log.log(.app, L("„%@“ an den Kindle gesendet", job.title))
            finishHandlers.removeValue(forKey: job.id)?(true)
        } catch {
            finishHandlers.removeValue(forKey: job.id)?(false)
            update(job.id) { $0.state = .failed(error.localizedDescription) }
            log.log(.app, L("„%@“ nicht gesendet: %@", job.title, error.localizedDescription), level: .error)
            if case .http(let code, _)? = error as? STKError, code == 401 || code == 403 { signOut() }
        }
    }

    private func update(_ id: UUID, _ change: (inout SendJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let before = jobs[i]
        change(&jobs[i])
        // progress ticks are not worth a disk write
        if case .uploading = jobs[i].state, case .uploading = before.state { return }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(jobs.prefix(200))) {
            try? data.write(to: Self.historyFile, options: .atomic)
        }
    }
}

// MARK: - Title and author from the file

enum DocumentMetadata {
    static func read(_ file: URL, fallbackName: String) -> (title: String, author: String) {
        var title: String?, author: String?
        switch file.pathExtension.lowercased() {
        case "pdf":
            let attrs = PDFDocument(url: file)?.documentAttributes
            title = attrs?[PDFDocumentAttribute.titleAttribute] as? String
            author = attrs?[PDFDocumentAttribute.authorAttribute] as? String
        case "epub":
            if let container = unzip(file, "META-INF/container.xml"),
               let opfPath = firstMatch(container, #"full-path="([^"]+)""#),
               let opf = unzip(file, opfPath) {
                title = firstMatch(opf, #"<dc:title[^>]*>([^<]+)</dc:title>"#)
                author = firstMatch(opf, #"<dc:creator[^>]*>([^<]+)</dc:creator>"#)
            }
        case "docx":
            if let core = unzip(file, "docProps/core.xml") {
                title = firstMatch(core, #"<dc:title>([^<]+)</dc:title>"#)
                author = firstMatch(core, #"<dc:creator>([^<]+)</dc:creator>"#)
            }
        default: break
        }
        func clean(_ s: String?) -> String? {
            let t = s.map(unescapeXML)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        return (clean(title) ?? fallbackName, clean(author) ?? "")
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// One file out of a zip container (EPUB/DOCX) – macOS ships `unzip`.
    private static func unzip(_ archive: URL, _ member: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", archive.path, member]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}

// MARK: - E-mail fallback (Amazon's documented route: attachment to …@kindle.com)

enum MailSender {
    @MainActor
    static func send(file: URL, named: String, to address: String) async throws {
        let source = """
        on sendFile(filePath, toAddress)
            tell application "Mail"
                set msg to make new outgoing message with properties {subject:"", content:" ", visible:false}
                tell msg to make new to recipient at end of to recipients with properties {address:toAddress}
                tell content of msg to make new attachment with properties {file name:(POSIX file filePath)} at after last paragraph
                delay 2
                send msg
            end tell
        end sendFile
        """
        // Amazon reads the title from the file name: send a copy with the original name
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let named = dir.appendingPathComponent(named)
        try FileManager.default.copyItem(at: file, to: named)
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 120) { try? FileManager.default.removeItem(at: dir) } }

        guard let script = NSAppleScript(source: source) else { throw STKError.badResponse("AppleScript") }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: "sendfile"), forKeyword: AEKeyword(keyASSubroutineName))
        let args = NSAppleEventDescriptor.list()
        args.insert(NSAppleEventDescriptor(string: named.path), at: 1)
        args.insert(NSAppleEventDescriptor(string: address), at: 2)
        event.setDescriptor(args, forKeyword: AEKeyword(keyDirectObject))
        var err: NSDictionary?
        script.executeAppleEvent(event, error: &err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw NSError(domain: "Mail", code: code, userInfo: [NSLocalizedDescriptionKey:
                    L("Keine Berechtigung für die App Mail. Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Automation „Scribe Sync → Mail“ erlauben.")])
            }
            throw NSError(domain: "Mail", code: code, userInfo: [NSLocalizedDescriptionKey:
                (err[NSAppleScript.errorMessage] as? String) ?? L("Mail konnte die Nachricht nicht senden.")])
        }
    }
}

// MARK: - Sign-in window for Send to Kindle

struct STKSignInView: View {
    @EnvironmentObject var model: AppModel
    @State private var url: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Für „Send to Kindle“ anmelden")).font(.headline)
                    Text(L("Amazons eigene Anmeldeseite. Scribe Sync meldet sich dort wie Amazons „Send to Kindle“-App für Mac an."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Abbrechen")) { model.sendToKindle.showSignIn = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if let url {
                STKWebView(start: url) { code in
                    model.sendToKindle.showSignIn = false
                    Task { await model.sendToKindle.finishSignIn(code: code) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 720)
        .onAppear { url = model.sendToKindle.beginSignIn() }
    }
}

private struct STKWebView: NSViewRepresentable {
    let start: URL
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        context.coordinator.watch(view)
        view.load(URLRequest(url: start))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var done = false
        private var observation: NSKeyValueObservation?
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        /// Amazon redirects to …/gp/sendtokindle?…authorization_code=… when sign-in is done.
        func watch(_ webView: WKWebView) {
            observation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.check(view) }
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            check(webView)
        }

        private func check(_ webView: WKWebView) {
            guard !done, let url = webView.url, let code = STK.authorizationCode(from: url) else { return }
            done = true
            webView.stopLoading()
            onCode(code)
        }
    }
}
