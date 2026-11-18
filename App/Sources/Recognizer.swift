import CoreImage
import Foundation
import KSSCore
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

// MARK: - Model catalog

struct ModelInfo: Identifiable, Hashable {
    let id: String               // Hugging Face repo id
    let title: String
    let note: String
    let approxGB: Double
    let minRAMGB: Int
    let stopTokens: Set<String>
}

enum ModelCatalog {
    static let qwen35_9B = ModelInfo(
        id: "mlx-community/Qwen3.5-9B-4bit", title: "Qwen 3.5 · 9B",
        note: "Empfohlen für 16 GB RAM – sehr gute Handschrifterkennung, auch Deutsch.",
        approxGB: 6.0, minRAMGB: 16, stopTokens: ["<|im_end|>"])
    static let qwen3VL_8B = ModelInfo(
        id: "mlx-community/Qwen3-VL-8B-Instruct-4bit", title: "Qwen3-VL · 8B",
        note: "Alternative für 16 GB RAM, etwas schneller.",
        approxGB: 5.8, minRAMGB: 16, stopTokens: ["<|im_end|>"])
    static let gemma4_31B = ModelInfo(
        id: "mlx-community/gemma-4-31b-it-4bit", title: "Gemma 4 · 31B",
        note: "Beste lokale Qualität, braucht ab 36 GB RAM.",
        approxGB: 18.4, minRAMGB: 36, stopTokens: ["<turn|>"])
    static let qwen3VL_4B = ModelInfo(
        id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit", title: "Qwen3-VL · 4B",
        note: "Für Macs mit 8 GB RAM – schneller, aber spürbar ungenauer.",
        approxGB: 3.0, minRAMGB: 8, stopTokens: ["<|im_end|>"])

    static let all = [qwen35_9B, qwen3VL_8B, gemma4_31B, qwen3VL_4B]
    static let defaultModel = qwen35_9B

    static func info(_ id: String) -> ModelInfo { all.first { $0.id == id } ?? defaultModel }

    static var physicalRAMGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    static var recommended: ModelInfo {
        let ram = physicalRAMGB
        if ram >= 36 { return gemma4_31B }
        if ram >= 16 { return qwen35_9B }
        return qwen3VL_4B
    }
}

// MARK: - Download (our own, with progress and resume-by-file)

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var downloading: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText = ""
    @Published var lastError: String?
    private var task: Task<Void, Never>?
    private let log: EventLog

    init(log: EventLog) { self.log = log }

    nonisolated static func directory(for id: String) -> URL {
        AppPaths.models.appendingPathComponent(id.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    }

    nonisolated static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent(".complete").path)
    }

    nonisolated static func installedSize(_ id: String) -> UInt64 {
        let dir = directory(for: id)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e { total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Self.directory(for: id))
        objectWillChange.send()
        log.log(.model, "Modell \(id) gelöscht")
    }

    func cancel() { task?.cancel() }

    func download(_ model: ModelInfo) {
        guard downloading == nil else { return }
        downloading = model.id
        progress = 0
        lastError = nil
        progressText = "Dateiliste wird geladen …"
        log.log(.model, "Download von \(model.title) gestartet")
        task = Task {
            do {
                try await performDownload(model)
                log.log(.model, "\(model.title) ist installiert")
            } catch is CancellationError {
                log.log(.model, "Download abgebrochen")
            } catch {
                lastError = error.localizedDescription
                log.log(.model, "Download fehlgeschlagen: \(error.localizedDescription)", level: .error)
            }
            downloading = nil
            objectWillChange.send()
        }
    }

    private struct HFFile: Decodable { let rfilename: String; let size: Int64? }
    private struct HFModel: Decodable { let siblings: [HFFile] }

    private func performDownload(_ model: ModelInfo) async throws {
        let dir = Self.directory(for: model.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let api = URL(string: "https://huggingface.co/api/models/\(model.id)?blobs=true")!
        let (data, _) = try await URLSession.shared.data(from: api)
        let files = try JSONDecoder().decode(HFModel.self, from: data).siblings
            .filter { !$0.rfilename.hasPrefix(".") && !$0.rfilename.lowercased().hasSuffix(".md") }
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = dir.appendingPathComponent(file.rfilename)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = file.size, let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
               (attrs[.size] as? NSNumber)?.int64Value == size {
                done += size; continue  // already there (resume)
            }
            let src = URL(string: "https://huggingface.co/\(model.id)/resolve/main/\(file.rfilename)")!
            let base = done
            let tmp = try await FileDownload.fetch(src) { [weak self] written in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = Double(base + written) / Double(total)
                    self.progressText = "\(ProcessMemory.format(UInt64(base + written))) von \(ProcessMemory.format(UInt64(total)))"
                }
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            done += file.size ?? 0
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".complete").path, contents: Data())
        progress = 1
    }
}

/// URLSession download with byte progress, as async/await.
private final class FileDownload: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Int64) -> Void

    private init(onProgress: @escaping (Int64) -> Void) { self.onProgress = onProgress }

    static func fetch(_ url: URL, onProgress: @escaping (Int64) -> Void) async throws -> URL {
        let d = FileDownload(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                d.continuation = cont
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the file at `location` disappears after this call: move it somewhere stable first
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: keep)
            continuation?.resume(returning: keep)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}

// MARK: - Tokenizer bridge (swift-transformers -> MLXLMCommon)

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// The weights are already on disk; never download anything at load time.
private struct LocalOnlyDownloader: MLXLMCommon.Downloader {
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        throw NSError(domain: "ScribeSync", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Modell ist nicht installiert"])
    }
}

// MARK: - Recognizer

enum RecognizerError: LocalizedError {
    case notInstalled(String), notLoaded, badImage
    var errorDescription: String? {
        switch self {
        case .notInstalled(let t): return "Das KI-Modell \(t) ist noch nicht heruntergeladen (Einstellungen › Texterkennung)."
        case .notLoaded: return "KI-Modell nicht geladen"
        case .badImage: return "Seitenbild konnte nicht gelesen werden"
        }
    }
}

/// Runs the vision model inside the app process. The weights are only in
/// memory between prepare() and release() – i.e. while pages are being read.
actor MLXRecognizer: PageRecognizer {
    nonisolated let modelName: String
    private let info: ModelInfo
    private let imageTools = MacImageTools()
    private var container: ModelContainer?
    private let onStateChange: @Sendable (Bool) -> Void

    init(model: ModelInfo, onStateChange: @escaping @Sendable (Bool) -> Void) {
        self.info = model
        self.modelName = model.title
        self.onStateChange = onStateChange
    }

    func prepare() async throws {
        guard container == nil else { return }
        guard ModelManager.isInstalled(info.id) else { throw RecognizerError.notInstalled(info.title) }
        Memory.cacheLimit = 256 * 1024 * 1024
        let config = ModelConfiguration(directory: ModelManager.directory(for: info.id), extraEOSTokens: info.stopTokens)
        container = try await VLMModelFactory.shared.loadContainer(
            from: LocalOnlyDownloader(), using: TransformersTokenizerLoader(), configuration: config)
        onStateChange(true)
    }

    func recognize(png: Data, context: RecognitionContext) async throws -> RecognitionResult {
        guard let container else { throw RecognizerError.notLoaded }
        guard let flat = imageTools.flattenedForModel(png) else { throw RecognizerError.badImage }
        let session = ChatSession(
            container,
            instructions: RecognitionPrompt.system,
            generateParameters: GenerateParameters(maxTokens: 3000, temperature: 0, repetitionPenalty: 1.05),
            processing: UserInput.Processing(resize: nil),
            additionalContext: ["enable_thinking": false])
        let raw = try await session.respond(to: RecognitionPrompt.user(context), image: .ciImage(CIImage(cgImage: flat)))
        return RecognitionPrompt.parse(raw, imageWidth: flat.width, imageHeight: flat.height)
    }

    func release() async {
        guard container != nil else { return }
        container = nil
        Stream.gpu.synchronize()
        Memory.clearCache()
        onStateChange(false)
    }
}
