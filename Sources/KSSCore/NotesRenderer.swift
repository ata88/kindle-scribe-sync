import Foundation

/// Renders a notebook as HTML for Apple Notes (first line = note title).
public enum NotesRenderer {
    public struct Output: Sendable {
        public var html: String
        /// Stable hash of the content (without timestamp) to skip identical writes.
        public var contentHash: String
        /// Every image file referenced by `html`, in order. Notes is sandboxed: the
        /// publisher has to hand these files over before the HTML can show them.
        public var images: [URL] = []
    }

    /// Images are referenced by file URL (`figureURL`/`pageURL`) at their place in the
    /// text. Base64 data URIs never load in Notes (empty "file" blocks), and file URLs
    /// only load once Notes has been given access to the file – see `images`.
    public static func render(_ nb: NotebookRecord,
                              figureURL: (PageRecord, Figure) -> URL?,
                              pageURL: ((PageRecord) -> URL?)? = nil,
                              pageLabels: Bool = false,
                              stamp: Date = Date()) -> Output {
        var images: [URL] = []
        var parts: [String] = ["<div><h1>\(escape(nb.title))</h1></div>"]
        if !nb.folderPath.isEmpty {
            parts.append("<div><i>\(escape(nb.folderPath.joined(separator: " / ")))</i></div>")
        }
        for page in nb.pages {
            parts.append("<div><br></div>")
            // no page headings in the text; optionally a small grey marker where a page starts
            if pageLabels && nb.pages.count > 1 {
                parts.append("<div><font color=\"#9a9a9a\"><small>\(escape(L("Seite %ld", page.index + 1)))</small></font></div>")
            }
            switch page.status {
            case .recognized:
                parts.append(markdownToHTML(page.text) { id in
                    guard let fig = page.figures.first(where: { $0.id == id }), let url = figureURL(page, fig) else {
                        return nil
                    }
                    images.append(url)
                    return "<div><img src=\"\(escape(url.absoluteString))\" /></div>"
                })
            case .pending:
                parts.append("<div><i>\(escape(L("(wird erkannt …)")))</i></div>")
            case .failed:
                let note = page.waitsForRecognition
                    ? L("(Texterkennung fehlgeschlagen – wird erneut versucht)")
                    : L("(Texterkennung fehlgeschlagen – in Scribe Sync erneut versuchen)")
                parts.append("<div><i>\(escape(note))</i></div>")
            }
            if let pageURL, let url = pageURL(page) {
                images.append(url)
                parts.append("<div><img src=\"\(escape(url.absoluteString))\" /></div>")
            }
        }
        let body = parts.joined(separator: "\n")
        let formatter = DateFormatter()
        formatter.locale = Loc.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let footer = "<div><br></div><div><font color=\"#8a8a8a\"><small>\(escape(L("Kindle Scribe · zuletzt synchronisiert %@ · Korrekturen bitte in der App Scribe Sync vornehmen.", formatter.string(from: stamp))))</small></font></div>"
        // image files keep their paths when their content changes: hash the pixels' identity too
        let imageKey = nb.pages.map { p in
            p.imageHash + p.figures.map { "\($0.id):\($0.box.x0),\($0.box.y0),\($0.box.x1),\($0.box.y1)" }.joined(separator: ";")
        }.joined(separator: "|")
        // "v2": notes written by 1.1.0 showed empty image placeholders and must be rewritten once
        return Output(html: "<html><body>\n\(body)\n\(footer)\n</body></html>",
                      contentHash: fnv1a("v2" + body + imageKey), images: images)
    }

    // MARK: Markdown → HTML (the subset the recognizer produces)

    /// Built from the same blocks the reader shows (`MarkdownBlocks`), so blank lines,
    /// lists and sketches come out the same in Notes as in the app.
    public static func markdownToHTML(_ md: String, figure: (Int) -> String? = { _ in nil }) -> String {
        var out: [String] = []
        var listStack: [String] = []   // "ul" / "ol"
        func closeLists(to depth: Int = 0) {
            while listStack.count > depth { out.append("</\(listStack.removeLast())>") }
        }
        for block in MarkdownBlocks.parse(md) {
            if case .item = block {} else { closeLists() }
            switch block {
            case .heading(let level, let text):
                out.append("<div><h\(level)>\(inline(text))</h\(level)></div>")
            case .paragraph(let text):
                out.append("<div>\(inline(text))</div>")
            case .spacer:
                out.append("<div><br></div>")        // one blank line, exactly like in the app
            case .quote(let text):
                out.append("<blockquote>\(inline(text))</blockquote>")
            case .figure(let id):
                out.append(figure(id) ?? "<div><i>[\(escape(L("Grafik %ld", id)))]</i></div>")
            case .table(let rows):
                var html = "<table>"
                for (i, row) in rows.enumerated() {
                    let tag = i == 0 ? "th" : "td"
                    html += "<tr>" + row.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
                }
                out.append(html + "</table>")
            case .item(let indent, let marker, let text, _):
                let kind: String
                let body: String
                var start = 1
                switch marker {
                case .bullet: kind = "ul"; body = inline(text)
                case .number(let n): kind = "ol"; body = inline(text); start = n
                case .check(let done): kind = "ul"; body = (done ? "☑ " : "☐ ") + inline(text)
                }
                let depth = indent + 1
                if listStack.count > depth { closeLists(to: depth) }
                if listStack.count == depth, listStack.last != kind { closeLists(to: depth - 1) }
                while listStack.count < depth {
                    // a list continued from the previous page keeps its numbers, as in the app
                    out.append(kind == "ol" && start != 1 && listStack.count == depth - 1 ? "<ol start=\"\(start)\">" : "<\(kind)>")
                    listStack.append(kind)
                }
                out.append("<li>\(body)</li>")
            }
        }
        closeLists()
        return out.joined(separator: "\n")
    }

    static func inline(_ s: String) -> String {
        var t = escape(s)
        t = t.replacing(/`([^`]+)`/) { "<tt>\($0.1)</tt>" }
        t = t.replacing(/\*\*([^*]+)\*\*/) { "<b>\($0.1)</b>" }
        t = t.replacing(/(^|[^*])\*([^*\s][^*]*)\*/) { "\($0.1)<i>\($0.2)</i>" }
        return t
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
