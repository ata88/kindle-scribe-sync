import Foundation

/// A rectangle in normalized page coordinates (0...1, origin top-left).
public struct NormRect: Codable, Hashable, Sendable {
    public var x0: Double, y0: Double, x1: Double, y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = min(x0, x1).clamped01; self.y0 = min(y0, y1).clamped01
        self.x1 = max(x0, x1).clamped01; self.y1 = max(y0, y1).clamped01
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
    public var isUsable: Bool { width > 0.02 && height > 0.02 }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}

/// A drawing/sketch found on a page, cropped from the page image.
public struct Figure: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var box: NormRect
    /// PNG file of the cropped region, relative to the library directory.
    public var imageFile: String?

    public init(id: Int, box: NormRect, imageFile: String? = nil) {
        self.id = id; self.box = box; self.imageFile = imageFile
    }
}

public enum PageStatus: String, Codable, Sendable {
    case pending      // image downloaded, waiting for recognition
    case recognized
    case failed
}

public struct PageRecord: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var imageHash: String
    /// Page PNG relative to the library directory.
    public var imageFile: String
    /// Text exactly as the model produced it (the merge base for corrections).
    public var ocrText: String?
    /// The user's corrected text; nil = no manual changes.
    public var userText: String?
    public var figures: [Figure]
    public var status: PageStatus
    public var error: String?
    public var model: String?
    public var recognizedAt: Date?
    /// Failed automatic recognition attempts since the page last changed.
    public var attempts: Int?

    public var id: Int { index }

    /// A failed page is retried automatically this often, then only on request –
    /// a page the model cannot read must not load 6 GB into memory every few minutes.
    public static let automaticAttempts = 3
    public var waitsForRecognition: Bool {
        status == .pending || (status == .failed && (attempts ?? 0) < Self.automaticAttempts)
    }

    public init(index: Int, imageHash: String, imageFile: String, ocrText: String? = nil,
                userText: String? = nil, figures: [Figure] = [], status: PageStatus = .pending,
                error: String? = nil, model: String? = nil, recognizedAt: Date? = nil) {
        self.index = index; self.imageHash = imageHash; self.imageFile = imageFile
        self.ocrText = ocrText; self.userText = userText; self.figures = figures
        self.status = status; self.error = error; self.model = model; self.recognizedAt = recognizedAt
    }

    /// What the user sees and what goes to Apple Notes.
    public var text: String { userText ?? ocrText ?? "" }
    public var isCorrected: Bool { userText != nil && userText != ocrText }
}

public enum NotebookStatus: String, Codable, Sendable {
    case new, downloading, recognizing, done, partial, error, deleted
}

public struct NotebookRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var folderPath: [String]
    public var modificationTime: String
    public var status: NotebookStatus
    public var error: String?
    public var pages: [PageRecord]
    public var syncedAt: Date?
    /// Apple Notes note id (x-coredata://…) once published.
    public var noteID: String?
    /// The Notes folder path the note was last written to.
    public var noteFolder: String?
    /// Content hash of what was last written to Apple Notes (skip identical writes).
    public var publishedHash: String?

    public init(id: String, title: String, folderPath: [String] = [], modificationTime: String = "",
                status: NotebookStatus = .new, error: String? = nil, pages: [PageRecord] = [],
                syncedAt: Date? = nil, noteID: String? = nil, noteFolder: String? = nil,
                publishedHash: String? = nil) {
        self.id = id; self.title = title; self.folderPath = folderPath
        self.modificationTime = modificationTime; self.status = status; self.error = error
        self.pages = pages; self.syncedAt = syncedAt; self.noteID = noteID
        self.noteFolder = noteFolder; self.publishedHash = publishedHash
    }

    public var pendingPages: [PageRecord] { pages.filter { $0.status != .recognized } }
    public var hasCorrections: Bool { pages.contains { $0.isCorrected } }
}

/// An entry from the Amazon notebook list.
public struct RemoteItem: Sendable, Hashable {
    public var id: String
    public var title: String
    public var folderPath: [String]
    /// A modification marker if the list endpoint provides one.
    public var modifiedHint: String?

    public init(id: String, title: String, folderPath: [String], modifiedHint: String? = nil) {
        self.id = id; self.title = title; self.folderPath = folderPath; self.modifiedHint = modifiedHint
    }
}

public struct RemoteNotebookMeta: Sendable, Hashable {
    public var title: String
    public var totalPages: Int
    public var modificationTime: String
    public var renderingToken: String

    public init(title: String, totalPages: Int, modificationTime: String, renderingToken: String) {
        self.title = title; self.totalPages = totalPages
        self.modificationTime = modificationTime; self.renderingToken = renderingToken
    }
}
