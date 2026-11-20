import Foundation
import Testing
@testable import KSSCore

@Suite struct ParseTests {
    @Test func parsesTextAndFigures() {
        let r = RecognitionPrompt.parse("""
        <think>hmm</think>
        <text>
        # Titel
        [[Grafik 1]]
        - [ ] offen
        </text>
        <grafiken>
        ```json
        [{"id": 1, "box": [100, 50, 500, 400]}, {"id": 2, "box": [0, 0, 1, 1]}]
        ```
        </grafiken>
        """)
        #expect(r.markdown.hasPrefix("# Titel"))
        #expect(r.figures.count == 1)  // the 1x1 box is not usable
        #expect(abs(r.figures[0].box.x0 - 0.1) < 1e-9 && abs(r.figures[0].box.y1 - 0.4) < 1e-9)
    }

    @Test func dropsPlaceholderWithoutBoxAndAppendsBoxWithoutPlaceholder() {
        let r = RecognitionPrompt.parse("<text>A [[Grafik 2]] B</text><grafiken>[{\"id\":1,\"box\":[10,10,300,300]}]</grafiken>")
        #expect(!r.markdown.contains("[[Grafik 2]]"))
        #expect(r.markdown.hasSuffix("[[Grafik 1]]"))
    }

    @Test func pixelCoordinatesAreNormalized() {
        let r = RecognitionPrompt.parse("<text>x [[Grafik 1]]</text><grafiken>[{\"id\":1,\"bbox_2d\":[124,1754,620,1200]}]</grafiken>",
                                        imageWidth: 1240, imageHeight: 1754)
        #expect(r.figures.count == 1)
        #expect(abs(r.figures[0].box.x0 - 0.1) < 1e-9)
    }

    @Test func plainTextWithoutTags() {
        let r = RecognitionPrompt.parse("```markdown\nNur Text\n```")
        #expect(r.markdown == "Nur Text" && r.figures.isEmpty)
    }
}

@Suite struct RendererTests {
    @Test func figuresAreFileURLsAtTheirPlace() {
        let nb = NotebookRecord(id: "a", title: "T", pages: [PageRecord(
            index: 0, imageHash: "h", imageFile: "f", ocrText: "vor\n[[Grafik 1]]\nnach",
            figures: [Figure(id: 1, box: NormRect(x0: 0, y0: 0, x1: 0.5, y1: 0.5), imageFile: "x")], status: .recognized)])
        let url = URL(fileURLWithPath: "/Users/a/Library/Application Support/Scribe Sync/fig 1.png")
        let out = NotesRenderer.render(nb, figureURL: { _, _ in url })
        let html = out.html
        #expect(out.images == [url], "the publisher must hand this file to Notes")
        #expect(html.contains("<div>vor</div>\n<div><img src=\"file:///Users/a/Library/Application%20Support/Scribe%20Sync/fig%201.png\" /></div>\n<div>nach</div>"))
        #expect(!html.contains("base64"))
    }

    @Test func noPageHeadingsUnlessAskedFor() {
        let nb = NotebookRecord(id: "a", title: "T", pages: [
            PageRecord(index: 0, imageHash: "h0", imageFile: "f0", ocrText: "Erste", status: .recognized),
            PageRecord(index: 1, imageHash: "h1", imageFile: "f1", ocrText: "Zweite", status: .recognized)])
        let plain = NotesRenderer.render(nb, figureURL: { _, _ in nil }).html
        #expect(!plain.contains("<h2>") && !plain.contains(L("Seite %ld", 2)))
        #expect(plain.contains("<div>Erste</div>") && plain.contains("<div>Zweite</div>"))
        let labelled = NotesRenderer.render(nb, figureURL: { _, _ in nil }, pageLabels: true).html
        #expect(labelled.contains("<small>\(L("Seite %ld", 2))</small>"))
        #expect(!labelled.contains("<h2>"))
    }

    @Test func hashChangesWhenOnlyTheImageChanges() {
        var nb = NotebookRecord(id: "a", title: "T", pages: [PageRecord(index: 0, imageHash: "h1", imageFile: "f",
                                                                          ocrText: "x", status: .recognized)])
        let a = NotesRenderer.render(nb, figureURL: { _, _ in nil }).contentHash
        nb.pages[0].imageHash = "h2"
        #expect(NotesRenderer.render(nb, figureURL: { _, _ in nil }).contentHash != a)
    }

    @Test func modelGarbageIsCleanedUp() {
        let raw = """
        <text>
        # Ideen Urlaub

        Wann? Juli<br>oder August
        <br>

        <br>

        <br>
        - Meer
        - Meer
        - Meer
        - Berge
        </text>
        <grafiken>[]</grafiken>
        """
        let text = RecognitionPrompt.parse(raw).markdown
        #expect(text == "# Ideen Urlaub\n\nWann? Juli\noder August\n\n- Meer\n- Berge", "\(text)")
    }

    @Test func markdownSubset() {
        let html = NotesRenderer.markdownToHTML("""
        # Kopf
        - [ ] offen
        - [x] erledigt
          - unterpunkt
        1. eins
        **fett** und *kursiv* <tag>
        | a | b |
        |---|---|
        | 1 | 2 |
        """)
        #expect(html.contains("<h1>Kopf</h1>"))
        #expect(html.contains("<li>☐ offen</li>") && html.contains("<li>☑ erledigt</li>"))
        #expect(html.contains("<ul>\n<li>unterpunkt</li>"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("<b>fett</b> und <i>kursiv</i> &lt;tag&gt;"))
        #expect(html.contains("<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>"))
    }

    @Test func hashIgnoresTimestamp() {
        let nb = NotebookRecord(id: "a", title: "T", pages: [PageRecord(index: 0, imageHash: "h", imageFile: "f",
                                                                          ocrText: "x", status: .recognized)])
        let a = NotesRenderer.render(nb, figureURL: { _, _ in nil }, stamp: Date(timeIntervalSince1970: 0))
        let b = NotesRenderer.render(nb, figureURL: { _, _ in nil }, stamp: Date())
        #expect(a.contentHash == b.contentHash && a.html != b.html)
    }
}

@Suite struct TarTests {
    func tar(_ files: [(String, Data)]) -> Data {
        var out = Data()
        for (name, data) in files {
            var h = [UInt8](repeating: 0, count: 512)
            for (i, b) in name.utf8.prefix(100).enumerated() { h[i] = b }
            let size = String(data.count, radix: 8)
            let sizeField = String(repeating: "0", count: 11 - size.count) + size
            for (i, b) in sizeField.utf8.enumerated() { h[124 + i] = b }
            h[156] = UInt8(ascii: "0")
            for (i, b) in "ustar".utf8.enumerated() { h[257 + i] = b }
            out.append(contentsOf: h)
            out.append(data)
            out.append(Data(count: (512 - data.count % 512) % 512))
        }
        out.append(Data(count: 1024))
        return out
    }

    @Test func extractsPNGsInNaturalOrderWithPrefixBytes() throws {
        let png = Data(Tar.pngMagic) + Data("IMG".utf8)
        let blob = tar([("p/10.png", Data([0, 1]) + png + Data("10".utf8)),
                        ("p/2.png", png + Data("2".utf8)),
                        ("p/readme.txt", Data("x".utf8))])
        let out = try Tar.pngs(blob)
        #expect(out.count == 2)
        #expect(String(decoding: out[0].suffix(1), as: UTF8.self) == "2")
        #expect(out[1].starts(with: Tar.pngMagic))
    }
}

@Suite struct CookieTests {
    @Test func domainAndPathMatching() {
        let jar = CookieJar([StoredCookie(name: "a", value: "1", domain: ".amazon.com"),
                             StoredCookie(name: "b", value: "2", domain: "www.amazon.de"),
                             StoredCookie(name: "c", value: "3", domain: ".amazon.com", expires: .distantPast)])
        #expect(jar.header(for: URL(string: "https://read.amazon.com/x")!) == "a=1")
    }

    @Test func mergeUpdates() {
        var jar = CookieJar([StoredCookie(name: "s", value: "old", domain: ".amazon.com")])
        let first = jar.merge([StoredCookie(name: "s", value: "new", domain: ".amazon.com")])
        let second = jar.merge([StoredCookie(name: "s", value: "new", domain: ".amazon.com")])
        #expect(first && !second)
        #expect(jar.cookies.count == 1 && jar.cookies[0].value == "new")
    }
}

/// Amazon client against a scripted transport.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    var handler: (URL, [String: String]) -> HTTPResponse
    var requests: [URL] = []
    init(_ handler: @escaping (URL, [String: String]) -> HTTPResponse) { self.handler = handler }
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        requests.append(url)
        return handler(url, headers)
    }
}

@Suite struct AmazonClientTests {
    func json(_ s: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(s.utf8))
    }

    @Test func listFlattensFolders() async throws {
        let t = ScriptedTransport { _, headers in
            #expect(headers["Cookie"] == "session-token=x")
            return self.json(#"{"itemsList":[{"id":"f","title":"Arbeit","type":"folder","items":[{"id":"n1","title":"Plan","type":"notebook","items":[]}]},{"id":"n2","title":" Ideen ","type":"notebook"}]}"#)
        }
        let c = AmazonClient(jar: CookieJar([StoredCookie(name: "session-token", value: "x", domain: ".amazon.com")]),
                             userAgent: "t", transport: t, requestDelay: .zero)
        let items = try await c.listItems()
        #expect(items == [RemoteItem(id: "n1", title: "Plan", folderPath: ["Arbeit"]),
                          RemoteItem(id: "n2", title: "Ideen", folderPath: [])])
    }

    @Test func signInRedirectIsAuthExpired() async {
        let t = ScriptedTransport { _, _ in
            HTTPResponse(status: 302, headers: ["location": "https://www.amazon.com/ap/signin?x"], body: Data())
        }
        let c = AmazonClient(jar: CookieJar(), userAgent: "t", transport: t, requestDelay: .zero)
        await #expect(throws: AmazonError.authExpired("Weiterleitung zur Anmeldung")) { try await c.listItems() }
    }

    @Test func marketplaceFallbackIsRememberedAndReported() async throws {
        let reported = Box<String?>(nil)
        let t = ScriptedTransport { url, _ in
            if url.query?.contains("marketplaceId=A1PA6795UKMFR9") == true {
                return self.json(#"{"metadata":{"title":"T","totalPages":2,"modificationTime":123},"renderingToken":"tok"}"#)
            }
            return HTTPResponse(status: 500, headers: ["content-type": "text/html"], body: Data("We're sorry".utf8))
        }
        let c = AmazonClient(jar: CookieJar(), userAgent: "t", transport: t, requestDelay: .zero,
                             onSessionChange: { _, mp in reported.value = mp })
        let meta = try await c.openNotebook("abc")
        #expect(meta.totalPages == 2 && meta.modificationTime == "123" && meta.renderingToken == "tok")
        #expect(await c.marketplaceID == "A1PA6795UKMFR9")
        #expect(reported.value == "A1PA6795UKMFR9")
        #expect(t.requests.count == 2, "no retries while probing")
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
