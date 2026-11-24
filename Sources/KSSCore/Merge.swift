import Foundation

/// Word-level three-way merge, used to keep manual corrections when a page is
/// re-recognized after the user wrote more on it.
///
///   base   = what the model read last time (the text the user corrected)
///   ours   = the user's corrected text
///   theirs = what the model reads now (the page got longer / changed)
///
/// Changes from both sides are combined; where both changed the same words,
/// the user's correction wins – but text the new reading adds there is kept.
public enum Merge {
    public static func threeWay(base: String, ours: String, theirs: String) -> String {
        if ours == base { return theirs }
        if theirs == base || theirs == ours { return ours }
        let b = tokenize(base), a = tokenize(ours), t = tokenize(theirs)
        let ha = hunks(from: b, to: a), ht = hunks(from: b, to: t)
        return merge(base: b, ours: ha, theirs: ht).joined()
    }

    /// The model sometimes writes new text straight after the text it was shown, without a
    /// space or line break ("…prüfen.Neuer Block"). New writing below old text is a new line on
    /// the paper: put the blank line back where the earlier text ends.
    public static func separateGluedContinuation(_ text: String, earlier: [String?]) -> String {
        for e in earlier.compactMap({ $0 }) {
            guard let last = e.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty }), last.count >= 8,
                  let r = text.range(of: last, options: .backwards) else { continue }
            guard r.upperBound < text.endIndex else { continue }
            let next = text[r.upperBound]
            // glued: a letter or digit directly after the old last line (punctuation/space is fine)
            guard next.isLetter || next.isNumber else { continue }
            if let lastChar = last.last, (lastChar.isLetter || lastChar.isNumber) && next.isLowercase { continue }  // a word was just read longer
            return String(text[..<r.upperBound]) + "\n\n" + String(text[r.upperBound...])
        }
        return text
    }

    /// Repair for pages hit by the old merge: lines at the end of the model's reading that the
    /// corrected text lacks entirely (text written later, dropped by the old conflict rule) are
    /// appended to the correction. Returns nil when nothing is missing.
    public static func restoreDroppedEnding(corrected: String, reading: String) -> String? {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        let have = Set(corrected.components(separatedBy: "\n").map(norm).filter { !$0.isEmpty })
        var missing: [String] = []
        for line in reading.components(separatedBy: "\n").reversed() {
            let n = norm(line)
            if n.isEmpty { if !missing.isEmpty { missing.insert(line, at: 0) }; continue }
            if have.contains(n) { break }
            // a line the user may have edited (shares most words with a corrected line) ends the search
            let words = Set(n.split(separator: " "))
            let edited = have.contains { h in
                let w = Set(h.split(separator: " "))
                return !w.isEmpty && Double(words.intersection(w).count) / Double(max(words.count, w.count)) >= 0.5
            }
            if edited { break }
            missing.insert(line, at: 0)
        }
        while let first = missing.first, norm(first).isEmpty { missing.removeFirst() }
        guard !missing.isEmpty else { return nil }
        return corrected.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + missing.joined(separator: "\n")
    }

    /// Words and the whitespace between them, so joining restores the text exactly.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for ch in s {
            let isSpace = ch.isWhitespace
            if currentIsSpace == isSpace || currentIsSpace == nil {
                current.append(ch)
            } else {
                out.append(current); current = String(ch)
            }
            currentIsSpace = isSpace
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    struct Hunk: Equatable {
        var lo: Int          // base range lo..<hi is replaced by `replacement`
        var hi: Int
        var replacement: [String]
        var isInsertion: Bool { lo == hi }
    }

    static func hunks(from base: [String], to other: [String]) -> [Hunk] {
        let diff = other.difference(from: base)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Hunk] = []
        var i = 0, j = 0
        while i < base.count || j < other.count {
            let baseKept = i < base.count && !removed.contains(i)
            let otherKept = j < other.count && !inserted.contains(j)
            if baseKept && otherKept { i += 1; j += 1; continue }
            let lo = i, jlo = j
            while i < base.count && removed.contains(i) { i += 1 }
            while j < other.count && inserted.contains(j) { j += 1 }
            result.append(Hunk(lo: lo, hi: i, replacement: Array(other[jlo..<j])))
        }
        return result
    }

    static func merge(base: [String], ours: [Hunk], theirs: [Hunk]) -> [String] {
        var out: [String] = []
        var pos = 0
        var ia = 0, it = 0
        while ia < ours.count || it < theirs.count {
            // the next hunk by base position (ours first on ties)
            let takeOurs: Bool
            if ia >= ours.count { takeOurs = false }
            else if it >= theirs.count { takeOurs = true }
            else { takeOurs = ours[ia].lo <= theirs[it].lo }
            let first = takeOurs ? ours[ia] : theirs[it]
            var groupA: [Hunk] = [], groupT: [Hunk] = []
            var lo = first.lo, hi = first.hi
            if takeOurs { groupA.append(first); ia += 1 } else { groupT.append(first); it += 1 }
            // collect everything overlapping the group
            var grew = true
            while grew {
                grew = false
                if ia < ours.count, overlaps(ours[ia], lo: lo, hi: hi) {
                    groupA.append(ours[ia]); hi = max(hi, ours[ia].hi); lo = min(lo, ours[ia].lo); ia += 1; grew = true
                }
                if it < theirs.count, overlaps(theirs[it], lo: lo, hi: hi) {
                    groupT.append(theirs[it]); hi = max(hi, theirs[it].hi); lo = min(lo, theirs[it].lo); it += 1; grew = true
                }
            }
            out.append(contentsOf: base[pos..<lo])
            let versionA = apply(groupA, base: base, lo: lo, hi: hi)
            let versionT = apply(groupT, base: base, lo: lo, hi: hi)
            if groupT.isEmpty { out.append(contentsOf: versionA) }
            else if groupA.isEmpty { out.append(contentsOf: versionT) }
            else { out.append(contentsOf: resolve(ours: versionA, theirs: versionT)) }
            pos = hi
        }
        out.append(contentsOf: base[pos...])
        return out
    }

    /// Both sides changed the same spot. The user's words win – but whatever the new
    /// reading *adds* (text written on the Scribe since) must not get lost with them:
    /// the new reading often repeats the corrected words and continues right after them.
    static func resolve(ours a: [String], theirs t: [String]) -> [String] {
        if a == t { return a }
        if t.starts(with: a) || t.reversed().starts(with: a.reversed()) { return t }  // pure extension
        var out: [String] = []
        var pos = 0
        for h in hunks(from: a, to: t) {
            out.append(contentsOf: a[pos..<h.lo])
            let kept = Array(a[h.lo..<h.hi])          // the user's words in this span stay
            let extra = h.replacement.count - kept.count
            if kept.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                // only spacing differs: line breaks and blank lines come from the paper, i.e. the reading
                out.append(contentsOf: h.replacement)
            } else if kept.isEmpty {
                out.append(contentsOf: h.replacement)   // only new text here: take it
            } else if extra > 0 {
                // the new reading has more here than it replaces: keep the user's words and
                // add the surplus on the side where it is (compare which end matches better)
                let r = h.replacement
                let atEnd = similarity(kept, Array(r.prefix(kept.count))) >= similarity(kept, Array(r.suffix(kept.count)))
                let surplus = atEnd ? Array(r.suffix(extra)) : Array(r.prefix(extra))
                // real new writing starts a new line or is more than one word; a single extra
                // fragment is just the old words read differently ("An na" for "Anna")
                let words = surplus.filter { !$0.allSatisfy(\.isWhitespace) }.count
                if surplus.contains(where: { $0.contains("\n") }) || words >= 2 {
                    out.append(contentsOf: atEnd ? kept + surplus : surplus + kept)
                } else {
                    out.append(contentsOf: kept)
                }
            } else {
                out.append(contentsOf: kept)            // a different reading of the user's words
            }
            pos = h.hi
        }
        out.append(contentsOf: a[pos...])
        return out
    }

    /// How alike two token runs are (shared characters at the same positions, roughly).
    private static func similarity(_ x: [String], _ y: [String]) -> Int {
        zip(x, y).reduce(0) { sum, pair in
            let (p, q) = (Array(pair.0.lowercased()), Array(pair.1.lowercased()))
            return sum + zip(p, q).filter { $0 == $1 }.count + (pair.0 == pair.1 ? 2 : 0)
        }
    }

    private static func overlaps(_ h: Hunk, lo: Int, hi: Int) -> Bool {
        if h.lo < hi && h.hi > lo { return true }                     // real overlap
        if h.isInsertion && lo == hi && h.lo == lo { return true }   // two insertions at one spot
        if h.isInsertion && h.lo > lo && h.lo < hi { return true }   // insertion inside a replaced span
        if lo == hi && h.lo < lo && h.hi > lo { return true }         // span around a pending insertion
        return false
    }

    private static func apply(_ hunks: [Hunk], base: [String], lo: Int, hi: Int) -> [String] {
        var out: [String] = []
        var pos = lo
        for h in hunks.sorted(by: { ($0.lo, $0.hi) < ($1.lo, $1.hi) }) {
            if h.lo > pos { out.append(contentsOf: base[pos..<h.lo]) }
            out.append(contentsOf: h.replacement)
            pos = max(pos, h.hi)
        }
        if pos < hi { out.append(contentsOf: base[pos..<hi]) }
        return out
    }
}
