import Foundation
import Testing
@testable import KSSCore

@Suite struct TranslationTests {
    /// Repository root, derived from this test file's location.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func sourceKeys() throws -> [(file: String, key: String)] {
        let dirs = ["Sources/KSSCore", "App/Sources"]
        let regex = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var out: [(String, String)] = []
        for dir in dirs {
            let url = root.appendingPathComponent(dir)
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            for f in files {
                let text = try String(contentsOf: f, encoding: .utf8)
                let ns = text as NSString
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let raw = ns.substring(with: m.range(at: 1))
                    out.append((f.lastPathComponent, raw.replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")))
                }
            }
        }
        return out
    }

    @Test func everyStringHasAnEnglishTranslation() throws {
        let keys = try Self.sourceKeys()
        #expect(keys.count > 200)
        let missing = keys.filter { Translations.en[$0.key] == nil }.map { "\($0.file): \($0.key)" }
        #expect(missing.isEmpty, "untranslated: \(missing)")
    }

    @Test func formatSpecifiersMatch() {
        let spec = try! NSRegularExpression(pattern: "%(?:%|@|ld|d|lf)")
        func specs(_ s: String) -> [String] {
            let ns = s as NSString
            return spec.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        for (de, en) in Translations.en {
            #expect(specs(de) == specs(en), "\(de) → \(en)")
        }
    }

    @Test func noUnusedTranslations() throws {
        let used = Set(try Self.sourceKeys().map(\.key))
        let unused = Translations.en.keys.filter { !used.contains($0) }
        #expect(unused.isEmpty, "unused: \(unused)")
    }

    @Test func switchingLanguage() {
        let d = UserDefaults.standard
        let old = d.string(forKey: Loc.defaultsKey)
        defer { d.set(old, forKey: Loc.defaultsKey) }
        d.set("en", forKey: Loc.defaultsKey)
        #expect(L("Seite %ld", 3) == "Page 3")
        d.set("de", forKey: Loc.defaultsKey)
        #expect(L("Seite %ld", 3) == "Seite 3")
    }
}

@Suite struct TaskTests {
    @Test func extractsAndToggles() {
        let nb = NotebookRecord(id: "n", title: "T", pages: [
            PageRecord(index: 0, imageHash: "h", imageFile: "f",
                       ocrText: "# Liste\n- [ ] Milch\n  - [x] Brot\n* [ ] Käse\nText", status: .recognized)])
        let items = Tasks.items(in: [nb])
        #expect(items.map(\.text) == ["Milch", "Brot", "Käse"])
        #expect(items.map(\.done) == [false, true, false])
        let text = nb.pages[0].text
        #expect(Tasks.toggled(text, line: 1, done: true) == "# Liste\n- [x] Milch\n  - [x] Brot\n* [ ] Käse\nText")
        #expect(Tasks.toggled(text, line: 2, done: false) == "# Liste\n- [ ] Milch\n  - [ ] Brot\n* [ ] Käse\nText")
        #expect(Tasks.toggled(text, line: 4, done: true) == text)
    }

    @Test func previewTextStripsFormat() {
        #expect(RecognitionPrompt.previewText("<text>\n# Hallo\nWelt") == "# Hallo\nWelt")
        #expect(RecognitionPrompt.previewText("<text>A</text>\n<grafiken>[]") == "A")
        #expect(RecognitionPrompt.previewText("<think>x") == "")
    }
}
