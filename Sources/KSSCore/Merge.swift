import Foundation

/// Word-level three-way merge, used to keep manual corrections when a page is
/// re-recognized after the user wrote more on it.
///
///   base   = what the model read last time (the text the user corrected)
///   ours   = the user's corrected text
///   theirs = what the model reads now (the page got longer / changed)
///
/// Changes from both sides are combined; where both changed the same words,
/// the user's correction wins.
public enum Merge {
    public static func threeWay(base: String, ours: String, theirs: String) -> String {
        if ours == base { return theirs }
        if theirs == base || theirs == ours { return ours }
        let b = tokenize(base), a = tokenize(ours), t = tokenize(theirs)
        let ha = hunks(from: b, to: a), ht = hunks(from: b, to: t)
        return merge(base: b, ours: ha, theirs: ht).joined()
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
            else { out.append(contentsOf: versionA) }  // conflict: the user's correction wins
            pos = hi
        }
        out.append(contentsOf: base[pos...])
        return out
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
