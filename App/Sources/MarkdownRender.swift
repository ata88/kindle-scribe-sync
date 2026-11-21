import AppKit
import KSSCore
import SwiftUI

/// The page's Markdown as blocks – the same reading Apple Notes and copy/export use
/// (`MarkdownBlocks` in KSSCore), cached per text.
typealias MDBlock = MarkdownBlocks.Block

enum MarkdownParser {
    private static let cache = NSCache<NSString, Box>()
    private final class Box { let blocks: [MDBlock]; init(_ b: [MDBlock]) { blocks = b } }

    static func blocks(_ md: String) -> [MDBlock] {
        let key = md as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = MarkdownBlocks.parse(md)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
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
