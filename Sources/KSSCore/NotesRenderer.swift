import Foundation

/// Renders a notebook as HTML for Apple Notes (first line = note title).
public enum NotesRenderer {
    public struct Output: Sendable {
        public var html: String
        /// Stable hash of the content (without timestamp) to skip identical writes.
        public var contentHash: String
    }

    public static func render(_ nb: NotebookRecord,
                              figurePNG: (PageRecord, Figure) -> Data?,
                              pagePNG: ((PageRecord) -> Data?)? = nil,
                              stamp: Date = Date()) -> Output {
        var parts: [String] = ["<div><h1>\(escape(nb.title))</h1></div>"]
        if !nb.folderPath.isEmpty {
            parts.append("<div><i>\(escape(nb.folderPath.joined(separator: " / ")))</i></div>")
        }
        for page in nb.pages {
            parts.append("<div><br></div>")
            if nb.pages.count > 1 { parts.append("<div><h2>Seite \(page.index + 1)</h2></div>") }
            switch page.status {
            case .recognized:
                parts.append(markdownToHTML(page.text) { id in
                    guard let fig = page.figures.first(where: { $0.id == id }), let png = figurePNG(page, fig) else {
                        return nil
                    }
                    return "<div><img src=\"data:image/png;base64,\(png.base64EncodedString())\"></div>"
                })
            case .pending:
                parts.append("<div><i>(wird erkannt …)</i></div>")
            case .failed:
                parts.append("<div><i>(Texterkennung fehlgeschlagen – wird erneut versucht)</i></div>")
            }
            if let pagePNG, let png = pagePNG(page) {
                parts.append("<div><img src=\"data:image/png;base64,\(png.base64EncodedString())\"></div>")
            }
        }
        let body = parts.joined(separator: "\n")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        let footer = "<div><br></div><div><font color=\"#8a8a8a\"><small>Kindle Scribe · zuletzt synchronisiert \(formatter.string(from: stamp)). Korrekturen bitte in der App Scribe Sync vornehmen.</small></font></div>"
        return Output(html: "<html><body>\n\(body)\n\(footer)\n</body></html>", contentHash: fnv1a(body))
    }

    // MARK: Markdown → HTML (the subset the recognizer produces)

    public static func markdownToHTML(_ md: String, figure: (Int) -> String? = { _ in nil }) -> String {
        var out: [String] = []
        var listStack: [String] = []   // "ul" / "ol"
        var table: [String] = []

        func closeLists(to depth: Int = 0) {
            while listStack.count > depth { out.append("</\(listStack.removeLast())>") }
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            let rows = table.filter { !$0.replacingOccurrences(of: " ", with: "").allSatisfy { "|:-".contains($0) } }
            var html = "<table>"
            for (i, row) in rows.enumerated() {
                let cells = row.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .split(separator: "|", omittingEmptySubsequences: false)
                let tag = i == 0 ? "th" : "td"
                html += "<tr>" + cells.map { "<\(tag)>\(inline(String($0).trimmingCharacters(in: .whitespaces)))</\(tag)>" }.joined() + "</tr>"
            }
            out.append(html + "</table>")
            table.removeAll()
        }

        for rawLine in md.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
                closeLists(); table.append(trimmed); continue
            }
            flushTable()
            if trimmed.isEmpty { closeLists(); continue }

            if let m = trimmed.firstMatch(of: /^\[\[Grafik (\d+)\]\]$/), let id = Int(m.1) {
                closeLists()
                out.append(figure(id) ?? "<div><i>[Grafik \(id)]</i></div>")
                continue
            }
            if let m = trimmed.firstMatch(of: /^(#{1,3})\s+(.*)$/) {
                closeLists()
                let level = m.1.count
                out.append("<div><h\(level)>\(inline(String(m.2)))</h\(level)></div>")
                continue
            }
            if trimmed.hasPrefix(">") {
                closeLists()
                out.append("<blockquote>\(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
                continue
            }
            let indent = line.prefix { $0 == " " }.count / 2
            var item: String?
            var kind = "ul"
            if let m = trimmed.firstMatch(of: /^[-*•]\s+\[( |x|X)\]\s+(.*)$/) {
                item = (m.1 == " " ? "☐ " : "☑ ") + inline(String(m.2))
            } else if let m = trimmed.firstMatch(of: /^[-*•]\s+(.*)$/) {
                item = inline(String(m.1))
            } else if let m = trimmed.firstMatch(of: /^\d+[.)]\s+(.*)$/) {
                item = inline(String(m.1)); kind = "ol"
            }
            if let item {
                let depth = indent + 1
                if listStack.count > depth { closeLists(to: depth) }
                if listStack.count == depth, listStack.last != kind { closeLists(to: depth - 1) }
                while listStack.count < depth { out.append("<\(kind)>"); listStack.append(kind) }
                out.append("<li>\(item)</li>")
                continue
            }
            closeLists()
            out.append("<div>\(inlineWithFigures(trimmed, figure: figure))</div>")
        }
        flushTable(); closeLists()
        return out.joined(separator: "\n")
    }

    static func inlineWithFigures(_ s: String, figure: (Int) -> String?) -> String {
        var result = ""
        var rest = Substring(s)
        while let m = rest.firstMatch(of: /\[\[Grafik (\d+)\]\]/) {
            result += inline(String(rest[..<m.range.lowerBound]))
            result += figure(Int(m.1) ?? 0) ?? "<i>[Grafik \(m.1)]</i>"
            rest = rest[m.range.upperBound...]
        }
        return result + inline(String(rest))
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
