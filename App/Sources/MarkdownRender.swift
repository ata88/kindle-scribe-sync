import AppKit
import KSSCore
import SwiftUI

/// The markdown subset the recognizer writes, parsed into blocks once and cached.
enum MDBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case item(indent: Int, marker: Marker, text: String, line: Int)
    case quote(String)
    case table([[String]])
    case figure(Int)
    case spacer

    enum Marker: Hashable { case bullet, number(Int), check(Bool) }
}

enum MarkdownParser {
    private static let cache = NSCache<NSString, Box>()
    private final class Box { let blocks: [MDBlock]; init(_ b: [MDBlock]) { blocks = b } }

    static func blocks(_ md: String) -> [MDBlock] {
        let key = md as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = parse(md)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    private static func parse(_ md: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var table: [[String]] = []
        func flushTable() {
            guard !table.isEmpty else { return }
            out.append(.table(table)); table.removeAll()
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
            if t.isEmpty {
                if out.last != .spacer && !out.isEmpty { out.append(.spacer) }
                continue
            }
            if let m = t.firstMatch(of: #/^\[\[Grafik (\d+)\]\]$/#), let id = Int(m.1) { out.append(.figure(id)); continue }
            if let m = t.firstMatch(of: #/^(#{1,3})\s+(.*)$/#) { out.append(.heading(level: m.1.count, text: String(m.2))); continue }
            if t.hasPrefix(">") {
                out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))); continue
            }
            let indent = line.prefix { $0 == " " }.count / 2
            if let m = t.firstMatch(of: #/^[-*•]\s+\[( |x|X)\]\s+(.*)$/#) {
                out.append(.item(indent: indent, marker: .check(m.1 != " "), text: String(m.2), line: lineNo)); continue
            }
            if let m = t.firstMatch(of: #/^[-*•]\s+(.*)$/#) {
                out.append(.item(indent: indent, marker: .bullet, text: String(m.1), line: lineNo)); continue
            }
            if let m = t.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                out.append(.item(indent: indent, marker: .number(Int(m.1) ?? 1), text: String(m.2), line: lineNo)); continue
            }
            // inline figure inside a text line: split it out
            if t.contains("[[Grafik ") {
                var rest = Substring(t)
                while let m = rest.firstMatch(of: #/\[\[Grafik (\d+)\]\]/#) {
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
        return out
    }
}

/// Inline formatting (**bold**, *italic*, `code`, uncertain words) plus the
/// red dotted underline for words the spell checker does not know.
enum InlineStyler {
    static func attributed(_ text: String, misspelled: Set<String>, base: Font = Theme.bodyFont) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(text)
        // tokens: **bold**, *italic*, `code`
        let pattern = #/(\*\*[^*]+\*\*)|(\*[^*\s][^*]*\*)|(`[^`]+`)/#
        while let m = rest.firstMatch(of: pattern) {
            result += styledWords(String(rest[..<m.range.lowerBound]), misspelled: misspelled)
            let token = String(rest[m.range])
            if token.hasPrefix("**") {
                var a = styledWords(String(token.dropFirst(2).dropLast(2)), misspelled: misspelled)
                a.inlinePresentationIntent = .stronglyEmphasized
                result += a
            } else if token.hasPrefix("`") {
                var a = AttributedString(String(token.dropFirst().dropLast()))
                a.font = .system(size: 14, design: .monospaced)
                result += a
            } else {
                var a = styledWords(String(token.dropFirst().dropLast()), misspelled: misspelled)
                a.inlinePresentationIntent = .emphasized
                result += a
            }
            rest = rest[m.range.upperBound...]
        }
        result += styledWords(String(rest), misspelled: misspelled)
        return result
    }

    /// Marks misspelled words and "[?]" uncertainty markers.
    private static func styledWords(_ s: String, misspelled: Set<String>) -> AttributedString {
        var a = AttributedString(s)
        guard !s.isEmpty else { return a }
        if !misspelled.isEmpty {
            for m in s.matches(of: #/[\p{L}\p{M}'’-]+/#) {
                let word = String(s[m.range])
                guard misspelled.contains(word.lowercased()),
                      let r = Range(m.range, in: a) else { continue }
                a[r].underlineStyle = Text.LineStyle(pattern: .dot, color: .red)
            }
        }
        for m in s.matches(of: #/\S*\[\?\]|\[unleserlich\]|\[illegible\]/#) {
            if let r = Range(m.range, in: a) {
                a[r].backgroundColor = Color.yellow.opacity(0.28)
            }
        }
        return a
    }
}
