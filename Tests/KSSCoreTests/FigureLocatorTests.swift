import Testing
@testable import KSSCore

/// A grayscale test page (white = 255) with helpers to draw strokes, words and a
/// ruled template, in pixel coordinates (top-left origin).
private struct Page {
    let w = 1240, h = 1754
    var px: [UInt8]
    init() { px = [UInt8](repeating: 255, count: 1240 * 1754) }

    mutating func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: UInt8 = 0) {
        for y in max(0, y0)..<min(h, y1) { for x in max(0, x0)..<min(w, x1) { px[y * w + x] = v } }
    }
    /// Outline rectangle with a stroke width of 6 px.
    mutating func outline(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        fill(x0, y0, x1, y0 + 6); fill(x0, y1 - 6, x1, y1); fill(x0, y0, x0 + 6, y1); fill(x1 - 6, y0, x1, y1)
    }
    mutating func diagonal(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        let n = max(abs(x1 - x0), abs(y1 - y0))
        for i in 0...n {
            let x = x0 + (x1 - x0) * i / n, y = y0 + (y1 - y0) * i / n
            fill(x - 3, y - 3, x + 3, y + 3)
        }
    }
    /// A handwritten line: words of letters (small blocks) with gaps between words.
    mutating func textLine(_ x: Int, _ baseline: Int, words: Int) {
        var cx = x
        for _ in 0..<words {
            for _ in 0..<5 { fill(cx, baseline - 34, cx + 14, baseline); cx += 18 }
            cx += 36
        }
    }
    func norm(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> NormRect {
        NormRect(x0: Double(x0) / Double(w), y0: Double(y0) / Double(h), x1: Double(x1) / Double(w), y1: Double(y1) / Double(h))
    }
    func locate(_ hint: NormRect) -> FigureLocator.PixelRect? {
        FigureLocator.locate(gray: px, width: w, height: h, hint: hint)
    }
}

/// The result contains the drawing completely (with the margin) and stays close to it.
private func covers(_ r: FigureLocator.PixelRect?, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, slack: Int = 40) -> Bool {
    guard let r else { return false }
    return r.x0 <= x0 && r.y0 <= y0 && r.x1 >= x1 && r.y1 >= y1
        && r.x0 >= x0 - slack && r.y0 >= y0 - slack && r.x1 <= x1 + slack && r.y1 <= y1 + slack
}

@Suite struct FigureLocatorTests {
    /// house sketch at x 600–1000, y 700–1100, text above and below
    private func housePage() -> Page {
        var p = Page()
        p.textLine(110, 200, words: 4)
        p.textLine(110, 300, words: 5)
        p.textLine(110, 600, words: 3)
        p.outline(600, 800, 1000, 1100)
        p.diagonal(600, 800, 800, 700); p.diagonal(800, 700, 1000, 800)
        p.textLine(110, 1250, words: 4)
        return p
    }

    @Test func exactHintGivesTheDrawing() {
        let p = housePage()
        #expect(covers(p.locate(p.norm(600, 700, 1000, 1100)), 597, 697, 1003, 1103))
    }

    @Test func shiftedHintStillFindsTheWholeDrawing() {
        let p = housePage()
        // box shifted 80 px right and 90 px down, as a sloppy model would return it
        let r = p.locate(p.norm(680, 790, 1080, 1190))
        #expect(covers(r, 597, 697, 1003, 1103), "\(String(describing: r))")
    }

    @Test func tooTightHintIsWidenedToTheDrawing() {
        let p = housePage()
        let r = p.locate(p.norm(700, 820, 900, 1000))
        #expect(covers(r, 597, 697, 1003, 1103), "\(String(describing: r))")
    }

    @Test func textLineGrazedByTheHintStaysOut() {
        let p = housePage()
        // hint reaches up into the text line at y 566–600, but only a sliver of it
        let r = p.locate(p.norm(600, 585, 1000, 1100))
        #expect(covers(r, 597, 697, 1003, 1103), "\(String(describing: r))")
    }

    /// What the 4B model really did in the lab: a coarse box shifted down over the text below.
    @Test func coarseBoxCoveringTextBelowKeepsOnlyTheDrawing() {
        let p = housePage()
        // drawing 600–1000 × 700–1100, text line at y 1216–1250; the box swallows that line completely
        let r = p.locate(p.norm(560, 760, 1240, 1300))
        #expect(covers(r, 597, 697, 1003, 1103), "\(String(describing: r))")
    }

    @Test func ruledTemplateLinesAreIgnored() {
        var p = housePage()
        for y in stride(from: 150, to: 1700, by: 90) { p.fill(0, y, 1240, y + 2, 150) }
        let r = p.locate(p.norm(620, 720, 980, 1080))
        #expect(covers(r, 597, 697, 1003, 1103), "\(String(describing: r))")
    }

    @Test func dotGridIsIgnored() {
        var p = housePage()
        for y in stride(from: 40, to: 1740, by: 52) { for x in stride(from: 40, to: 1220, by: 52) { p.fill(x, y, x + 4, y + 4, 120) } }
        let r = p.locate(p.norm(640, 740, 1060, 1160))
        #expect(covers(r, 597, 697, 1003, 1103, slack: 60), "\(String(describing: r))")
    }

    @Test func onlyTheHintedOfTwoDrawings() {
        var p = Page()
        p.outline(100, 300, 400, 600)
        p.outline(800, 1200, 1100, 1500)
        let r = p.locate(p.norm(820, 1180, 1120, 1480))
        #expect(covers(r, 797, 1197, 1103, 1503), "\(String(describing: r))")
    }

    @Test func labelsInsideTheHintBelongToTheDrawing() {
        var p = Page()
        p.outline(500, 800, 800, 1000)
        p.textLine(520, 1060, words: 1)       // label right below, 26 px gap
        let r = p.locate(p.norm(480, 780, 820, 1080))
        #expect(covers(r, 497, 797, 803, 1063), "\(String(describing: r))")
    }

    @Test func emptyPageGivesNil() {
        let p = Page()
        #expect(p.locate(p.norm(100, 100, 500, 500)) == nil)
    }
}
