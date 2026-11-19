import AppKit
import CoreGraphics
import CoreText
import Foundation
import KSSCore

/// `Scribe Sync --figure-lab` (CI only): draws pages with sketches at known places,
/// lets the model from $SCRIBE_SELFTEST_MODEL_DIR read them and prints how well the
/// returned boxes and the final crops match the truth. Pages and crops go to $FIGLAB_OUT.
enum FigureLab {
    static var requested: Bool { CommandLine.arguments.contains("--figure-lab") }

    struct LabPage {
        let name: String
        let png: Data
        let truth: [NormRect]
    }

    static func run() async -> Int32 {
        guard let dir = ProcessInfo.processInfo.environment["SCRIBE_SELFTEST_MODEL_DIR"] else {
            print("FIGLAB no model dir"); return 1
        }
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIGLAB_OUT"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let info = ModelInfo(id: "lab", title: "Lab", note: "", approxGB: 0, minRAMGB: 0, stopTokens: ["<|im_end|>"])
        let rec = MLXRecognizer(model: info, directoryOverride: URL(fileURLWithPath: dir)) { _ in }
        let tools = MacImageTools()
        do { try await rec.prepare() } catch { print("FIGLAB load failed: \(error)"); return 1 }
        for page in pages() {
            try? page.png.write(to: out.appendingPathComponent("\(page.name).png"))
            let t0 = Date()
            do {
                let ctx = RecognitionContext(notebookTitle: "Lab", pageNumber: 1, pageCount: 1)
                let result = try await rec.recognize(png: page.png, context: ctx) { _ in }
                print("FIGLAB \(page.name) (\(Int(Date().timeIntervalSince(t0))) s)")
                print("  truth: \(page.truth.map(fmt))")
                print("  model: \(result.figures.map { fmt($0.box) })")
                for f in result.figures {
                    let best = page.truth.map { iou($0, f.box) }.max() ?? 0
                    var line = "  fig \(f.id): model IoU \(String(format: "%.2f", best))"
                    if let crop = tools.cropFigure(page.png, box: f.box) {
                        let cbest = page.truth.map { iou($0, crop.box) }.max() ?? 0
                        line += " → crop \(fmt(crop.box)) IoU \(String(format: "%.2f", cbest))"
                        try? crop.png.write(to: out.appendingPathComponent("\(page.name)-fig\(f.id).png"))
                    }
                    print(line)
                }
                print("  text: \(result.markdown.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(300))")
            } catch {
                print("FIGLAB \(page.name) failed: \(error)")
            }
        }
        await rec.release()
        print("FIGLAB done")
        return 0
    }

    static func fmt(_ r: NormRect) -> String {
        String(format: "[%.3f %.3f %.3f %.3f]", r.x0, r.y0, r.x1, r.y1)
    }

    static func iou(_ a: NormRect, _ b: NormRect) -> Double {
        let ix = max(0, min(a.x1, b.x1) - max(a.x0, b.x0)), iy = max(0, min(a.y1, b.y1) - max(a.y0, b.y0))
        let inter = ix * iy
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    // MARK: pages

    /// Drawing helper in top-left page coordinates (like the model's boxes).
    final class Canvas {
        let w = 1240, h = 1754
        let ctx: CGContext
        let font: String
        init() {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(6)
            ctx.setLineCap(.round)
            font = NSFont(name: "Noteworthy-Bold", size: 60) != nil ? "Noteworthy-Bold" : "Helvetica"
        }
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: Double(h) - y) }
        func text(_ s: String, _ x: Double, _ baseline: Double, size: Double = 56) {
            let f = CTFontCreateWithName(font as CFString, size, nil)
            let attr = NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = p(x, baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        func line(_ pts: [(Double, Double)]) {
            ctx.move(to: p(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { ctx.addLine(to: p(q.0, q.1)) }
            ctx.strokePath()
        }
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            line([(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)])
        }
        func ellipse(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            ctx.strokeEllipse(in: CGRect(x: x0, y: Double(h) - y1, width: x1 - x0, height: y1 - y0))
        }
        func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> NormRect {
            NormRect(x0: x0 / Double(w), y0: y0 / Double(h), x1: x1 / Double(w), y1: y1 / Double(h))
        }
        func png() -> Data {
            let img = ctx.makeImage()!
            let rep = NSBitmapImageRep(cgImage: img)
            return rep.representation(using: .png, properties: [:])!
        }
    }

    static func pages() -> [LabPage] {
        var out: [LabPage] = []

        // 1: sketch on the left between text paragraphs
        do {
            let c = Canvas()
            c.text("Gartenplanung", 110, 170, size: 76)
            c.text("Beet an der Südseite anlegen,", 110, 290)
            c.text("Tomaten und Kräuter.", 110, 380)
            c.rect(140, 480, 560, 820); c.line([(140, 650), (560, 650)]); c.line([(350, 480), (350, 820)])
            c.text("Kompost hinten links", 110, 960)
            c.text("- Erde bestellen", 110, 1060)
            out.append(LabPage(name: "p1-left", png: c.png(), truth: [c.box(137, 477, 563, 823)]))
        }
        // 2: sketch to the right of text
        do {
            let c = Canvas()
            c.text("Wohnzimmer", 110, 170, size: 76)
            c.text("Sofa 2,20 m", 110, 300)
            c.text("Regal an die Wand", 110, 390)
            c.text("Lampe neu", 110, 480)
            c.rect(720, 240, 1130, 620); c.rect(760, 520, 960, 600); c.ellipse(1020, 280, 1100, 360)
            c.text("Danach: Farbe aussuchen", 110, 800)
            out.append(LabPage(name: "p2-right", png: c.png(), truth: [c.box(717, 237, 1133, 623)]))
        }
        // 3: two drawings, flow chart in the middle and a circle low on the page
        do {
            let c = Canvas()
            c.text("Ablauf Bestellung", 110, 170, size: 76)
            c.rect(120, 380, 380, 520); c.rect(520, 380, 780, 520); c.rect(900, 380, 1140, 520)
            c.line([(380, 450), (520, 450)]); c.line([(500, 435), (520, 450), (500, 465)])
            c.line([(780, 450), (900, 450)]); c.line([(880, 435), (900, 450), (880, 465)])
            c.text("Danach wird geliefert.", 110, 760)
            c.ellipse(450, 1100, 800, 1450); c.line([(625, 1100), (625, 1450)])
            c.text("Ende", 110, 1600)
            out.append(LabPage(name: "p3-two", png: c.png(),
                               truth: [c.box(117, 377, 1143, 523), c.box(447, 1097, 803, 1453)]))
        }
        // 4: mind map with labels, lower half
        do {
            let c = Canvas()
            c.text("Ideen Urlaub", 110, 170, size: 76)
            c.text("Wann? Juli oder August", 110, 300)
            c.ellipse(470, 900, 770, 1060); c.text("Urlaub", 520, 1000, size: 48)
            c.line([(470, 980), (260, 860)]); c.text("Meer", 130, 850, size: 44)
            c.line([(770, 980), (980, 860)]); c.text("Berge", 990, 850, size: 44)
            c.line([(620, 1060), (620, 1220)]); c.text("Budget", 550, 1280, size: 44)
            out.append(LabPage(name: "p4-mindmap", png: c.png(), truth: [c.box(125, 805, 1135, 1295)]))
        }
        return out
    }
}
