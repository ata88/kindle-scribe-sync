import Foundation

/// A checkbox line ("- [ ] …" / "- [x] …") found in a page.
public struct TaskItem: Identifiable, Hashable, Sendable {
    public var notebookID: String
    public var notebookTitle: String
    public var pageIndex: Int
    public var line: Int
    public var text: String
    public var done: Bool
    public var id: String { "\(notebookID)#\(pageIndex)#\(line)" }

    public init(notebookID: String, notebookTitle: String, pageIndex: Int, line: Int, text: String, done: Bool) {
        self.notebookID = notebookID; self.notebookTitle = notebookTitle; self.pageIndex = pageIndex
        self.line = line; self.text = text; self.done = done
    }
}

public enum Tasks {
    static var pattern: Regex<(Substring, Substring, Substring, Substring, Substring)> {
        /^(\s*[-*•]\s+\[)( |x|X)(\]\s+)(.*)$/
    }

    public static func items(in notebooks: [NotebookRecord]) -> [TaskItem] {
        notebooks.flatMap { nb in
            nb.pages.flatMap { page in
                page.text.components(separatedBy: "\n").enumerated().compactMap { (i, line) -> TaskItem? in
                    guard let m = line.firstMatch(of: pattern) else { return nil }
                    return TaskItem(notebookID: nb.id, notebookTitle: nb.title, pageIndex: page.index, line: i,
                                    text: String(m.4), done: m.2 != " ")
                }
            }
        }
    }

    /// The page text with the checkbox on `line` set to `done`.
    public static func toggled(_ text: String, line: Int, done: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        guard line < lines.count, let m = lines[line].firstMatch(of: pattern) else { return text }
        lines[line] = "\(m.1)\(done ? "x" : " ")\(m.3)\(m.4)"
        return lines.joined(separator: "\n")
    }
}
