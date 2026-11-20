import Foundation
import Testing
@testable import KSSCore

@Suite struct KindleLibraryTests {
    @Test func listRequestsMatchTheReferenceClient() throws {
        let docs = try JSONSerialization.jsonObject(with: Data(KindleLibrary.listRequest(kind: .document, startIndex: 18, batchSize: 18).utf8)) as! [String: Any]
        let o = (docs["param"] as! [String: Any])["OwnershipData"] as! [String: Any]
        #expect(o["contentType"] as? String == "KindlePDoc")
        #expect(o["startIndex"] as? Int == 18 && o["batchSize"] as? Int == 18)
        #expect(o["itemStatus"] as? [String] == ["Active"])
        #expect(o["isExtendedMYK"] as? Bool == false)
        #expect(o["sortIndex"] as? String == "DATE" && o["sortOrder"] as? String == "DESCENDING")

        let books = try JSONSerialization.jsonObject(with: Data(KindleLibrary.listRequest(kind: .book, startIndex: 0, batchSize: 100).utf8)) as! [String: Any]
        let b = (books["param"] as! [String: Any])["OwnershipData"] as! [String: Any]
        #expect(b["contentType"] as? String == "Ebook")
        #expect(b["originType"] as? [String] == ["Purchase"])
    }

    @Test func deleteRequestNamesTheItemAndItsCategory() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(KindleLibrary.deleteRequest(asin: "ABC123", category: "KindlePDoc").utf8)) as! [String: Any]
        let details = ((obj["param"] as! [String: Any])["DeleteContent"] as! [String: Any])["asinDetails"] as! [String: Any]
        #expect((details["ABC123"] as? [String: String])?["category"] == "KindlePDoc")
    }

    @Test func formBodyEscapesJSONAndToken() {
        let body = KindleLibrary.formBody(data: #"{"a":"b c&d"}"#, csrfToken: "g+h/i=")
        #expect(body == "data=%7B%22a%22%3A%22b%20c%26d%22%7D&csrfToken=g%2Bh%2Fi%3D")
    }

    @Test func csrfTokenFromThePage() {
        #expect(KindleLibrary.csrfToken(inPage: #"<script>var csrfToken = "gFz+abc/123=";</script>"#) == "gFz+abc/123=")
        #expect(KindleLibrary.csrfToken(inPage: "<html>nothing</html>") == nil)
        #expect(KindleLibrary.isSignInPage(URL(string: "https://www.amazon.de/ap/signin?openid=x")))
        #expect(!KindleLibrary.isSignInPage(KindleLibrary.pageURL(store: "amazon.de", books: false)))
    }

    @Test func parsesDocumentsAndBooks() throws {
        let docs = """
        {"OwnershipData":{"hasMoreItems":true,"numberOfItems":40,"items":[
          {"asin":"P1","title":"Projektplan &amp; Budget","author":"Anna","category":"KindlePDoc","acquiredTime":1763500000000},
          {"asin":"P2","title":"Notizen","authors":"","category":"KindlePDoc","acquiredDate":"18. November 2026"}]}}
        """
        let page = try KindleLibrary.parseList(docs, kind: .document)
        #expect(page.hasMore && page.total == 40)
        #expect(page.items.map(\.title) == ["Projektplan & Budget", "Notizen"])
        #expect(page.items[0].author == "Anna" && page.items[0].acquired != nil)
        #expect(page.items[1].acquiredText == "18. November 2026")

        let books = #"{"OwnershipData":{"hasMoreItems":false,"items":[{"asin":"B0X","title":"Der Prozess","authors":"Kafka, Franz","category":"KindleEBook"}]}}"#
        let b = try KindleLibrary.parseList(books, kind: .book)
        #expect(b.items.first?.kind == .book && b.items.first?.category == "KindleEBook" && !b.hasMore)
    }

    @Test func deleteResultIsChecked() throws {
        try KindleLibrary.parseDelete(#"{"DeleteContent":{"success":true}}"#)
        #expect(throws: KindleLibraryError.amazon("CONTENT_NOT_OWNED")) {
            try KindleLibrary.parseDelete(#"{"DeleteContent":{"success":false,"error":"CONTENT_NOT_OWNED"}}"#)
        }
        #expect(throws: KindleLibraryError.badResponse("DeleteContent")) { try KindleLibrary.parseDelete(#"{"other":1}"#) }
        #expect(throws: KindleLibraryError.needsSignIn) { try KindleLibrary.parseDelete("<html>sign in</html>") }
    }

    @Test func parsesDevices() throws {
        let d = try KindleLibrary.parseDevices(#"{"GetDevices":{"devices":[{"deviceAccountName":"Annas Kindle Scribe","deviceSerialNumber":"G1","deviceType":"A2"},{"deviceAccountName":"no serial"}]}}"#)
        #expect(d == [KindleDeviceInfo(name: "Annas Kindle Scribe", serial: "G1", type: "A2")])
    }
}
