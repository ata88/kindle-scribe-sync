import Foundation

/// Finds the exact region of a drawing on a page.
///
/// The model's box is only a hint: it is often a little off or too tight. The
/// page's ink is grouped into connected regions (strokes that touch or nearly
/// touch); every region that lies mostly inside the hint belongs to the drawing,
/// even where it extends beyond it. Text lines that the hint only grazes stay out.
public enum FigureLocator {
    public struct PixelRect: Equatable, Sendable {
        public var x0: Int, y0: Int, x1: Int, y1: Int   // x1/y1 exclusive
        public init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
        public var width: Int { x1 - x0 }
        public var height: Int { y1 - y0 }
    }

    /// - Parameters:
    ///   - gray: 8-bit grayscale pixels, row-major, white = 255.
    ///   - hint: the model's box (0…1).
    /// - Returns: the drawing's pixel rectangle including a small margin, or nil if there is no ink.
    public static func locate(gray: [UInt8], width: Int, height: Int, hint: NormRect,
                              inkThreshold: UInt8 = 170) -> PixelRect? {
        guard width > 16, height > 16, gray.count >= width * height else { return nil }

        // 0. ruled or squared paper: rows/columns inked across most of the page are template, not drawing
        var rowInk = [Int](repeating: 0, count: height), colInk = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where gray[row + x] < inkThreshold { rowInk[y] += 1; colInk[x] += 1 }
        }
        let templateRow = rowInk.map { $0 > width * 6 / 10 }
        let templateCol = colInk.map { $0 > height * 6 / 10 }
        func isInk(_ x: Int, _ y: Int) -> Bool {
            gray[y * width + x] < inkThreshold && !templateRow[y] && !templateCol[x]
        }

        // 1. coarse ink grid (cells of ~0.5 % of the page width)
        let cell = max(3, width / 200)
        let gw = (width + cell - 1) / cell, gh = (height + cell - 1) / cell
        var ink = [Bool](repeating: false, count: gw * gh)
        for y in 0..<height where !templateRow[y] {
            let row = y * width, gy = y / cell
            for x in 0..<width where gray[row + x] < inkThreshold && !templateCol[x] {
                ink[gy * gw + x / cell] = true
            }
        }

        // 2. bridge small gaps (within a stroke, between close strokes), not between text lines
        let r = max(1, Int((0.005 * Double(width) / Double(cell)).rounded()))
        var grown = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw where ink[gy * gw + gx] {
                for yy in max(0, gy - r)...min(gh - 1, gy + r) {
                    for xx in max(0, gx - r)...min(gw - 1, gx + r) { grown[yy * gw + xx] = true }
                }
            }
        }

        // 3. connected regions (bounding box of the real ink cells in each)
        struct Region { var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1, cells = 0 }
        var label = [Int32](repeating: -1, count: gw * gh)
        var regions: [Region] = []
        var stack: [Int] = []
        for start in 0..<(gw * gh) where grown[start] && label[start] < 0 {
            let id = Int32(regions.count)
            var reg = Region()
            label[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                let gx = i % gw, gy = i / gw
                if ink[i] {
                    reg.cells += 1
                    reg.x0 = min(reg.x0, gx); reg.x1 = max(reg.x1, gx)
                    reg.y0 = min(reg.y0, gy); reg.y1 = max(reg.y1, gy)
                }
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = gx + dx, ny = gy + dy
                        guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                        let j = ny * gw + nx
                        if grown[j] && label[j] < 0 { label[j] = id; stack.append(j) }
                    }
                }
            }
            regions.append(reg)
        }

        // 4. pick the regions that belong to the hinted drawing
        let hx0 = hint.x0 * Double(gw), hx1 = hint.x1 * Double(gw)
        let hy0 = hint.y0 * Double(gh), hy1 = hint.y1 * Double(gh)
        var sel: Region?
        for reg in regions where reg.cells > 2 {   // single specks (dot grid, dust) are no drawing
            let rx0 = Double(reg.x0), rx1 = Double(reg.x1 + 1), ry0 = Double(reg.y0), ry1 = Double(reg.y1 + 1)
            let ix = max(0, min(rx1, hx1) - max(rx0, hx0)), iy = max(0, min(ry1, hy1) - max(ry0, hy0))
            let inside = (ix * iy) / max(1, (rx1 - rx0) * (ry1 - ry0))
            let cx = (rx0 + rx1) / 2, cy = (ry0 + ry1) / 2
            let centerInside = cx >= hx0 && cx <= hx1 && cy >= hy0 && cy <= hy1
            guard inside >= 0.5 || centerInside else { continue }
            if var s = sel {
                s.x0 = min(s.x0, reg.x0); s.y0 = min(s.y0, reg.y0)
                s.x1 = max(s.x1, reg.x1); s.y1 = max(s.y1, reg.y1); s.cells += reg.cells
                sel = s
            } else {
                sel = reg
            }
        }
        guard let s = sel else { return nil }

        // 5. back to pixels, tightened to the actual ink, plus a small margin
        let px0 = s.x0 * cell, py0 = s.y0 * cell
        let px1 = min(width, (s.x1 + 1) * cell), py1 = min(height, (s.y1 + 1) * cell)
        var minX = px1, minY = py1, maxX = px0, maxY = py0
        for y in py0..<py1 {
            for x in px0..<px1 where isInk(x, y) {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let margin = Int(0.012 * Double(max(width, height)))
        let out = PixelRect(x0: max(0, minX - margin), y0: max(0, minY - margin),
                            x1: min(width, maxX + 1 + margin), y1: min(height, maxY + 1 + margin))
        return out.width > 8 && out.height > 8 ? out : nil
    }
}
