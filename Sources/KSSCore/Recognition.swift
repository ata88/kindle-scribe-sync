import Foundation

/// What the recognizer returns for one page.
public struct RecognitionResult: Sendable, Equatable {
    /// Markdown with `[[Grafik N]]` placeholders where drawings sit.
    public var markdown: String
    public var figures: [Figure]

    public init(markdown: String, figures: [Figure]) {
        self.markdown = markdown; self.figures = figures
    }
}

public struct RecognitionContext: Sendable {
    public var notebookTitle: String
    public var pageNumber: Int
    public var pageCount: Int
    /// End of the previous page, for continuity (hyphenation etc.).
    public var previousPageTail: String
    /// Text of this page from an earlier pass (the page was extended since).
    public var earlierText: String?

    public init(notebookTitle: String, pageNumber: Int, pageCount: Int, previousPageTail: String = "",
                earlierText: String? = nil) {
        self.notebookTitle = notebookTitle; self.pageNumber = pageNumber; self.pageCount = pageCount
        self.previousPageTail = previousPageTail; self.earlierText = earlierText
    }
}

/// Recognizes one page image. Implementations decide how/when a model is loaded;
/// the engine calls `prepare()` before a batch and `release()` right after it.
public protocol PageRecognizer: Sendable {
    var modelName: String { get }
    func prepare() async throws
    /// `onPartial` receives the text read so far (for a live preview), already
    /// stripped of the answer format.
    func recognize(png: Data, context: RecognitionContext,
                   onPartial: @escaping @Sendable (String) -> Void) async throws -> RecognitionResult
    func release() async
}

extension RecognitionPrompt {
    /// The readable part of a partial model answer (inside <text>, without figure JSON).
    public static func previewText(_ partial: String) -> String {
        var s = partial.replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
        if let r = s.range(of: "<text>") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "</text>") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: "<grafiken>") { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RecognitionPrompt {
    public static let system = """
    Du bist ein Experte für das Transkribieren handschriftlicher Notizen. Du bekommst eine Seite \
    aus einem Kindle-Scribe-Notizbuch (Stifteingabe, schwarz auf weiß) und gibst den Inhalt als \
    sauberes Markdown in Druckschrift zurück.

    Regeln für den Text:
    - Wörtlich und vollständig transkribieren, in der Originalsprache (meist Deutsch oder Englisch). \
    Nichts übersetzen, nichts zusammenfassen, nichts hinzufügen.
    - Struktur erhalten: Überschriften (#, ##), Aufzählungen, nummerierte Listen, Einrückungen, \
    Absätze. Checkboxen als "- [ ]" bzw. "- [x]". Pfeile als →, ←, ↔. \
    Unterstrichene oder umrahmte Wörter als **fett**. Tabellen als Markdown-Tabelle.
    - Durchgestrichenen Text weglassen. Unsichere Wörter: bester Versuch mit [?] dahinter.
    - Leere Seite: nur "(leere Seite)".

    Zeichnungen, Skizzen, Diagramme, Pfeil-Grafiken oder Mindmaps NICHT beschreiben. Setze an ihre \
    Stelle im Text einen Platzhalter [[Grafik 1]], [[Grafik 2]], … und gib für jede Grafik den \
    umschließenden Rahmen an. Beschriftungen innerhalb einer Grafik gehören zur Grafik und werden \
    nicht zusätzlich als Text ausgegeben. Normale handschriftliche Textzeilen sind keine Grafik.

    Antworte exakt in diesem Format, ohne Einleitung und ohne Kommentar:
    <text>
    (Markdown der Seite)
    </text>
    <grafiken>
    [{"id": 1, "box": [x1, y1, x2, y2]}]
    </grafiken>

    Koordinaten sind relativ zur Bildgröße im Bereich 0 bis 1000 (x1,y1 = oben links, \
    x2,y2 = unten rechts). Ohne Grafiken: <grafiken>[]</grafiken>
    """

    public static func user(_ ctx: RecognitionContext) -> String {
        var s = "Notizbuch „\(ctx.notebookTitle)“, Seite \(ctx.pageNumber) von \(ctx.pageCount)."
        if let earlier = ctx.earlierText, !earlier.isEmpty {
            s += """

            Diese Seite wurde früher schon gelesen und seitdem ergänzt. Bisheriger Text \
            (unveränderte Stellen bitte wörtlich gleich schreiben):
            <bisher>
            \(earlier)
            </bisher>
            Wichtig: Transkribiere die GANZE Seite, wie sie jetzt ist – auch alles, was seitdem \
            neu dazugeschrieben wurde (oft am Ende der Seite). Neuer Text darf nicht fehlen.
            """
        }
        if !ctx.previousPageTail.isEmpty {
            s += """

            Zur Orientierung das Ende der vorherigen Seite (NICHT erneut ausgeben):
            <vorherige_seite>
            \(ctx.previousPageTail)
            </vorherige_seite>
            """
        }
        return s + "\n\nTranskribiere diese Seite."
    }

    /// Parse the model output. Tolerates missing tags, code fences, <think> blocks
    /// and coordinates given in pixels instead of 0–1000.
    public static func parse(_ raw: String, imageWidth: Int = 0, imageHeight: Int = 0) -> RecognitionResult {
        var s = raw.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        var text = between(s, "<text>", "</text>") ?? s
        if let figStart = text.range(of: "<grafiken>") { text = String(text[..<figStart.lowerBound]) }
        text = cleanUp(stripFences(text))

        var figures: [Figure] = []
        if let figJSON = between(s, "<grafiken>", "</grafiken>").map(stripFences),
           let data = figJSON.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for (n, item) in list.enumerated() {
                let id = (item["id"] as? Int) ?? Int("\(item["id"] ?? "")") ?? (n + 1)
                let raw = (item["box"] ?? item["bbox_2d"] ?? item["bbox"]) as? [Any] ?? []
                let v = raw.compactMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") }
                guard v.count == 4 else { continue }
                let pixel = v.contains { $0 > 1000 } && imageWidth > 0 && imageHeight > 0
                let sx = pixel ? Double(imageWidth) : 1000, sy = pixel ? Double(imageHeight) : 1000
                let box = NormRect(x0: v[0] / sx, y0: v[1] / sy, x1: v[2] / sx, y1: v[3] / sy)
                guard box.isUsable else { continue }
                figures.append(Figure(id: id, box: box))
            }
        }
        // placeholders without a box are useless; boxes without a placeholder go to the end
        let ids = Set(figures.map(\.id))
        for match in placeholders(in: text) where !ids.contains(match) {
            text = text.replacingOccurrences(of: "[[Grafik \(match)]]", with: "")
        }
        for f in figures where !text.contains("[[Grafik \(f.id)]]") {
            text += "\n\n[[Grafik \(f.id)]]"
        }
        if text.isEmpty { text = "(leere Seite)" }
        return RecognitionResult(markdown: text, figures: figures)
    }

    public static func placeholders(in text: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: #"\[\[Grafik (\d+)\]\]"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Int(ns.substring(with: $0.range(at: 1)))
        }
    }

    private static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open) else { return nil }
        let rest = s[a.upperBound...]
        let end = rest.range(of: close)?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Models sometimes emit HTML line breaks, runs of empty lines, or the same line over and
    /// over (seen in the lab on mind maps). None of that belongs in the transcript.
    static func cleanUp(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</?(p|div|span)[^>]*>"#, with: "", options: .regularExpression)
        // the same line again right after itself (ignoring blank lines) is a generation loop: keep it once
        var lines: [String] = []
        var lastText = ""
        for line in t.components(separatedBy: "\n") {
            let key = line.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && key == lastText { continue }
            if !key.isEmpty { lastText = key }
            lines.append(line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
        }
        t = lines.joined(separator: "\n")
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = String(t.drop { $0 != "\n" }.dropFirst())
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t
    }
}
