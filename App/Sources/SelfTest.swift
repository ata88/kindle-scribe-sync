import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import KSSCore
import MLX
import UniformTypeIdentifiers

/// Headless checks run by CI against the built app:
///
///   Scribe Sync --self-test                 basic: AppleScript compiles, image pipeline works
///   Scribe Sync --self-test-recognition     also loads a model from $SCRIBE_SELFTEST_MODEL_DIR,
///                                           reads a synthetic handwritten page and unloads it
enum SelfTest {
    static var requested: Bool {
        CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--self-test-recognition")
            || CommandLine.arguments.contains("--self-test-notes") || CommandLine.arguments.contains("--self-test-stk")
    }

    static func run() async -> Int32 {
        if CommandLine.arguments.contains("--self-test-notes") { return await notesTest() }
        if let i = CommandLine.arguments.firstIndex(of: "--self-test-stk"), i + 1 < CommandLine.arguments.count {
            return stkSignatureTest(vector: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " – \(detail)")")
            if !ok { failures += 1 }
        }

        // 1. AppleScript for Apple Notes compiles
        do {
            try await MainActor.run { try NotesScripting.compileCheck() }
            check("notes-applescript-compiles", true)
        } catch {
            check("notes-applescript-compiles", false, error.localizedDescription)
        }

        // 2. image pipeline on a synthetic page with a transparent background
        let page = syntheticPage()
        let tools = MacImageTools()
        let h1 = tools.pixelHash(page), h2 = tools.pixelHash(page)
        check("pixel-hash-stable", h1 != nil && h1 == h2, h1 ?? "nil")
        let size = tools.pixelSize(page)
        check("pixel-size", size?.width == 1240 && size?.height == 1754, "\(size.map { "\($0.width)x\($0.height)" } ?? "nil")")
        if let crop = tools.cropFigure(page, box: NormRect(x0: 0.50, y0: 0.55, x1: 0.95, y1: 0.85)) {
            let cs = tools.pixelSize(crop.png)
            check("figure-crop", (cs?.width ?? 0) > 100 && crop.box.x0 > 0.45,
                  "crop \(cs.map { "\($0.width)x\($0.height)" } ?? "?") box \(crop.box)")
        } else {
            check("figure-crop", false, "nil")
        }
        if let flat = tools.flattenedForModel(page) {
            // the transparent background must have become white, not black
            let white = cornerIsWhite(flat)
            check("flatten-white-background", white)
        } else {
            check("flatten-white-background", false, "nil")
        }

        // 3. notes HTML embeds a figure
        var nb = NotebookRecord(id: "t", title: "Selbsttest", pages: [
            PageRecord(index: 0, imageHash: "h", imageFile: "f", ocrText: "Text\n[[Grafik 1]]",
                       figures: [Figure(id: 1, box: NormRect(x0: 0, y0: 0, x1: 0.5, y1: 0.5), imageFile: "x")],
                       status: .recognized)])
        nb.folderPath = ["A"]
        let html = NotesRenderer.render(nb, figureURL: { _, _ in URL(fileURLWithPath: "/tmp/fig 1.png") }).html
        check("notes-html-figure", html.contains("<img src=\"file:///tmp/fig%201.png\" />"))

        // 4. optional: real recognition with a small model of the same family
        if CommandLine.arguments.contains("--self-test-recognition") {
            failures += await recognitionTest(page: page)
        }

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }

    private static func recognitionTest(page: Data) async -> Int {
        guard let dirPath = ProcessInfo.processInfo.environment["SCRIBE_SELFTEST_MODEL_DIR"] else {
            print("FAIL recognition – SCRIBE_SELFTEST_MODEL_DIR not set")
            return 1
        }
        let info = ModelInfo(id: "selftest", title: "Selbsttest-Modell", note: "", approxGB: 0, minRAMGB: 0,
                             stopTokens: ["<|im_end|>"])
        let rec = MLXRecognizer(model: info, directoryOverride: URL(fileURLWithPath: dirPath)) { _ in }
        let before = ProcessMemory.footprint()
        do {
            let t0 = Date()
            try await rec.prepare()
            let loaded = ProcessMemory.footprint()
            print("INFO model loaded in \(Int(Date().timeIntervalSince(t0))) s, footprint \(ProcessMemory.format(before)) → \(ProcessMemory.format(loaded)), MLX active \(ProcessMemory.format(UInt64(Memory.activeMemory)))")
            let t1 = Date()
            let ctx = RecognitionContext(notebookTitle: "Selbsttest", pageNumber: 1, pageCount: 1)
            let result = try await rec.recognize(png: page, context: ctx) { _ in }
            print("INFO recognized in \(Int(Date().timeIntervalSince(t1))) s")
            print("----- markdown -----\n\(result.markdown)\n----- figures: \(result.figures.map { "\($0.id): \($0.box)" }) -----")
            await rec.release()
            let after = ProcessMemory.footprint()
            print("INFO after release: footprint \(ProcessMemory.format(after)), MLX active \(ProcessMemory.format(UInt64(Memory.activeMemory))), cache \(ProcessMemory.format(UInt64(Memory.cacheMemory)))")
            let lower = result.markdown.lowercased()
            var f = 0
            let readSomething = lower.contains("einkauf") || lower.contains("milch") || lower.contains("brot")
            print("\(readSomething ? "PASS" : "FAIL") recognition-reads-text")
            if !readSomething { f += 1 }
            let freed = Memory.activeMemory < 200 * 1024 * 1024
            print("\(freed ? "PASS" : "FAIL") model-memory-released (MLX active \(ProcessMemory.format(UInt64(Memory.activeMemory))))")
            if !freed { f += 1 }
            return f
        } catch {
            print("FAIL recognition – \(error.localizedDescription)")
            await rec.release()
            return 1
        }
    }

    /// `--self-test-notes`: writes a note with two sketches through the app's real Notes
    /// code, updates it, and checks that Notes stored the image data at the right places.
    private static func notesTest() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " – \(detail)")")
            if !ok { failures += 1 }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Scribe Sync Notes Test/nb 1")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tools = MacImageTools()
        let page = syntheticPage()
        guard let crop = tools.cropFigure(page, box: NormRect(x0: 0.6, y0: 0.55, x1: 0.85, y1: 0.76)) else {
            print("FAIL notes – no crop"); return 1
        }
        let f1 = dir.appendingPathComponent("fig-0001-1.png"), f2 = dir.appendingPathComponent("fig-0001-2.png")
        try? crop.png.write(to: f1); try? crop.png.write(to: f2)
        var nb = NotebookRecord(id: "selftest", title: "Scribe Sync Selbsttest", pages: [
            PageRecord(index: 0, imageHash: "h", imageFile: "f", ocrText: "ERSTER TEXT\n[[Grafik 1]]\nZWEITER TEXT\n[[Grafik 2]]\nDRITTER TEXT",
                       figures: [Figure(id: 1, box: crop.box, imageFile: "1"), Figure(id: 2, box: crop.box, imageFile: "2")],
                       status: .recognized)])
        let notes = NotesScripting(accountName: { "" })
        func verify(_ id: String, _ label: String) async {
            try? await Task.sleep(for: .seconds(3))
            let body = (try? await MainActor.run { try NotesScripting.body(noteID: id) }) ?? ""
            let empty = body.components(separatedBy: "base64,(null)").count - 1
            let images = body.components(separatedBy: "src=\"data:image").count - 1
            let order = [body.range(of: "ERSTER")?.lowerBound, body.range(of: "data:image")?.lowerBound,
                         body.range(of: "ZWEITER")?.lowerBound, body.range(of: "DRITTER")?.lowerBound]
            let ordered = order.allSatisfy { $0 != nil } && zip(order, order.dropFirst()).allSatisfy { $0! < $1! }
            check("notes-images-\(label)", images == 2 && empty == 0 && ordered,
                  "images \(images), empty \(empty), in order \(ordered)")
        }
        do {
            var out = NotesRenderer.render(nb, figureURL: { _, f in f.imageFile == "1" ? f1 : f2 })
            let id = try await notes.publish(html: out.html, images: out.images, existingNoteID: nil,
                                             folderPath: ["Scribe Sync Selbsttest"])
            check("notes-created", id.hasPrefix("x-coredata"), id)
            await verify(id, "new")
            print("INFO before update: " + (await MainActor.run { NotesScripting.debug(noteID: id, folderPath: ["Scribe Sync Selbsttest"]) }))
            nb.pages[0].ocrText = "ERSTER TEXT geändert\n[[Grafik 1]]\nZWEITER TEXT\n[[Grafik 2]]\nDRITTER TEXT"
            out = NotesRenderer.render(nb, figureURL: { _, f in f.imageFile == "1" ? f1 : f2 })
            let id2 = try await notes.publish(html: out.html, images: out.images, existingNoteID: id,
                                              folderPath: ["Scribe Sync Selbsttest"])
            check("notes-updated-in-place", id2 == id, id2)
            await verify(id2, "updated")
            try? await MainActor.run { try NotesScripting.delete(noteID: id2) }
        } catch {
            check("notes-publish", false, error.localizedDescription)
        }
        print(failures == 0 ? "NOTES SELFTEST OK" : "NOTES SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }

    /// `--self-test-stk VECTOR`: the Send-to-Kindle request signature made with the Mac's
    /// crypto must equal the reference made by Python (scripts/stk-vector.py).
    private static func stkSignatureTest(vector: URL) -> Int32 {
        guard let data = try? Data(contentsOf: vector),
              let v = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let pem = v["pem"], let adp = v["adp"], let date = v["date"], let path = v["path"],
              let body = v["body"], let expected = v["header"] else {
            print("FAIL stk-vector – unreadable"); return 1
        }
        let reg = STKRegistration(privateKeyPEM: pem, adpToken: adp, deviceType: "A1K6D1WRW0MALS", userName: "",
                                  userDeviceName: "", homeRegion: nil)
        do {
            let header = try STK.requestDigest(method: "POST", path: path, body: body, date: date,
                                               registration: reg, crypto: MacSTKCrypto())
            let ok = header == expected
            print("\(ok ? "PASS" : "FAIL") stk-request-signature\(ok ? "" : " – got \(header.prefix(24))…, want \(expected.prefix(24))…")")
            // and the body the app builds for that call is byte-identical to the reference client's
            let fmt = ISO8601DateFormatter()
            let req = try STK.apiRequestForSelfTest(path, registration: reg, crypto: MacSTKCrypto(), now: fmt.date(from: date)!)
            let sameBody = String(decoding: req.body ?? Data(), as: UTF8.self) == body
                && req.headers["X-ADP-Request-Digest"] == expected
            print("\(sameBody ? "PASS" : "FAIL") stk-request-complete")
            return ok && sameBody ? 0 : 1
        } catch {
            print("FAIL stk-request-signature – \(error.localizedDescription)")
            return 1
        }
    }

    /// A 1240x1754 page, transparent background, handwriting-style text and a small sketch.
    static func syntheticPage() -> Data {
        syntheticPage(lines: ["Einkaufsliste", "- Milch", "- Brot", "- Äpfel", "Termin mit Anna am Montag"], sketch: true)
    }

    static func syntheticPage(lines: [String], sketch: Bool) -> Data {
        let w = 1240, h = 1754
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let fontName = NSFont(name: "Noteworthy-Bold", size: 64) != nil ? "Noteworthy-Bold" : "Helvetica"
        for (i, line) in lines.enumerated() {
            let font = CTFontCreateWithName(fontName as CFString, i == 0 ? 80 : 60, nil)
            let attr = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 110, y: h - 200 - i * 120)
            CTLineDraw(ctLine, ctx)
        }
        // sketch: a house in the lower right
        if sketch {
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(8)
        ctx.stroke(CGRect(x: 760, y: 420, width: 280, height: 220))
        ctx.move(to: CGPoint(x: 740, y: 640)); ctx.addLine(to: CGPoint(x: 900, y: 790)); ctx.addLine(to: CGPoint(x: 1060, y: 640))
        ctx.strokePath()
        }
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private static func cornerIsWhite(_ img: CGImage) -> Bool {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(img.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return px[0] > 240 && px[1] > 240 && px[2] > 240
    }
}
