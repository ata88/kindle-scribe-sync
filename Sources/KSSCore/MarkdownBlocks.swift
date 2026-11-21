import Foundation

/// The one reading of a page's Markdown that the reader, Apple Notes and copy/export
/// all share – so blank lines, lists and sketches look the same everywhere.
///
/// Blank-line rules (handwriting on lined paper: a skipped line is a paragraph break):
/// * one or more blank lines → exactly one `.spacer`
/// * separator lines (`---`, `***`, `___`, `—`) → a `.spacer` as well, never a visible rule
/// * no `.spacer` at the start or end of a page
public enum MarkdownBlocks {
    public enum Block: Hashable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// `line`: index of the source line, to tick a checkbox in the page text.
        case item(indent: Int, marker: Marker, text: String, line: Int)
        case quote(String)
        case table([[String]])
        case figure(Int)
        case spacer
    }

    public enum Marker: Hashable, Sendable { case bullet, number(Int), check(Bool) }

    /// A line that is only a horizontal rule – the model's way of drawing a gap.
    public static func isSeparator(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && compact.allSatisfy { "-*_—–=".contains($0) }
    }

    public static func parse(_ md: String) -> [Block] {
        var out: [Block] = []
        var table: [[String]] = []
        func flushTable() {
            guard !table.isEmpty else { return }
            out.append(.table(table)); table.removeAll()
        }
        func gap() {
            guard let last = out.last, last != .spacer else { return }
            out.append(.spacer)
        }
        for (lineNo, raw) in md.components(separatedBy: "\n").enumerated() {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") && t.hasSuffix("|") && t.count > 1 {
                if !t.replacingOccurrences(of: " ", with: "").allSatisfy({ "|:-".contains($0) }) {
                    table.append(t.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) })
                }
                continue
            }
            flushTable()
            if t.isEmpty || isSeparator(t) { gap(); continue }
            if let m = t.firstMatch(of: /^\[\[Grafik (\d+)\]\]$/), let id = Int(m.1) { out.append(.figure(id)); continue }
            if let m = t.firstMatch(of: /^(#{1,6})\s+(.*)$/) {   // #### and deeper: smallest heading
                out.append(.heading(level: min(3, m.1.count), text: String(m.2))); continue
            }
            if t.hasPrefix(">") {
                out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))); continue
            }
            let indent = line.prefix { $0 == " " }.count / 2
            if let m = t.firstMatch(of: /^[-*•]\s+\[( |x|X)\]\s+(.*)$/) {
                out.append(.item(indent: indent, marker: .check(m.1 != " "), text: String(m.2), line: lineNo)); continue
            }
            if let m = t.firstMatch(of: /^[-*•]\s+(.*)$/) {
                out.append(.item(indent: indent, marker: .bullet, text: String(m.1), line: lineNo)); continue
            }
            if let m = t.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                out.append(.item(indent: indent, marker: .number(Int(m.1) ?? 1), text: String(m.2), line: lineNo)); continue
            }
            // a sketch inside a text line: split it out
            if t.contains("[[Grafik ") {
                var rest = Substring(t)
                while let m = rest.firstMatch(of: /\[\[Grafik (\d+)\]\]/) {
                    let before = rest[..<m.range.lowerBound].trimmingCharacters(in: .whitespaces)
                    if !before.isEmpty { out.append(.paragraph(before)) }
                    out.append(.figure(Int(m.1) ?? 0))
                    rest = rest[m.range.upperBound...]
                }
                let tail = rest.trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { out.append(.paragraph(tail)) }
                continue
            }
            out.append(.paragraph(t))
        }
        flushTable()
        while out.last == .spacer { out.removeLast() }
        while out.first == .spacer { out.removeFirst() }
        return out
    }

    /// The page text with the same blank-line rules applied – for copying and exporting.
    public static func normalizedText(_ md: String) -> String {
        var lines: [String] = []
        var pendingGap = false
        for raw in md.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || isSeparator(t) { pendingGap = !lines.isEmpty; continue }
            if pendingGap { lines.append(""); pendingGap = false }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
