import Foundation
import Testing
@testable import KSSCore

/// Records what is hashed and signed; returns fixed bytes (real crypto runs in the macOS self-test).
private final class RecordingCrypto: STKCrypto, @unchecked Sendable {
    private let lock = NSLock()
    var hashed: [Data] = []
    var signedWithKey: [Data] = []
    func sha256(_ data: Data) -> Data { lock.withLock { hashed.append(data) }; return Data(repeating: 7, count: 32) }
    func randomBytes(_ count: Int) -> Data { Data(repeating: 1, count: count) }
    func signRawDigest(_ digest: Data, pkcs1DER: Data) throws -> Data {
        lock.withLock { signedWithKey.append(pkcs1DER) }
        return Data("SIG".utf8)
    }
}

private final class FakeSTKTransport: STKTransport, @unchecked Sendable {
    private let lock = NSLock()
    var requests: [STKRequest] = []
    var uploads: [(URL, URL)] = []
    var responses: [String: (Int, String)] = [:]   // path -> (status, body)

    func send(_ request: STKRequest) async throws -> HTTPResponse {
        let r: (Int, String) = lock.withLock {
            requests.append(request)
            return responses[request.url.path] ?? (404, "")
        }
        return HTTPResponse(status: r.0, headers: [:], body: Data(r.1.utf8))
    }

    func upload(file: URL, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPResponse {
        lock.withLock { uploads.append((file, url)) }
        progress(10)
        return HTTPResponse(status: 200, headers: [:], body: Data())
    }
}

private func registration() -> STKRegistration {
    STKRegistration(privateKeyPEM: STKVector.pkcs8PEM, adpToken: STKVector.adpToken, deviceType: "A1K6D1WRW0MALS",
                    userName: "Test", userDeviceName: "Scribe Sync", homeRegion: "NA")
}

@Suite struct SendToKindleTests {
    @Test func pkcs8KeyIsUnwrappedToPKCS1() throws {
        let der = try STK.pkcs1DER(fromPEM: STKVector.pkcs8PEM)
        #expect(der == Data(base64Encoded: STKVector.pkcs1DERBase64))
    }

    @Test func requestDigestSignsExactlyWhatAmazonExpects() throws {
        let crypto = RecordingCrypto()
        let header = try STK.requestDigest(method: "POST", path: STKVector.path, body: STKVector.body,
                                           date: STKVector.date, registration: registration(), crypto: crypto)
        let expected = ["POST", STKVector.path, STKVector.date, STKVector.body, STKVector.adpToken].joined(separator: "\n")
        #expect(crypto.hashed == [Data(expected.utf8)])
        #expect(crypto.signedWithKey == [Data(base64Encoded: STKVector.pkcs1DERBase64)!])
        #expect(header == Data("SIG".utf8).base64EncodedString() + ":" + STKVector.date)
    }

    @Test func apiBodyMatchesTheReferenceClient() throws {
        let date = ISO8601DateFormatter().date(from: STKVector.date)!
        let req = try STK.apiRequest(STKVector.path, [:], registration: registration(), crypto: RecordingCrypto(), now: date)
        #expect(String(decoding: req.body!, as: UTF8.self) == STKVector.body)
        #expect(req.url.absoluteString == "https://kd.amazon.com/import/kindle-doc/get-device-list")
        #expect(req.headers["X-ADP-Authentication-Token"] == STKVector.adpToken)
        #expect(req.headers["X-ADP-Request-Digest"]?.hasSuffix(":" + STKVector.date) == true)
        #expect(STK.signingDate(date) == STKVector.date)
    }

    @Test func signInURLAndCode() {
        let pkce = STK.makePKCE(RecordingCrypto())
        #expect(!pkce.verifier.contains("=") && !pkce.verifier.contains("+") && !pkce.verifier.contains("/"))
        let url = STK.signInURL(challenge: pkce.challenge)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "openid.oa2.code_challenge" }?.value == pkce.challenge)
        #expect(items.first { $0.name == "openid.oa2.client_id" }?.value?.hasPrefix("device:") == true)
        let back = URL(string: "https://www.amazon.com/gp/sendtokindle?openid.assoc_handle=amzn_device_na&openid.oa2.authorization_code=ANTMNkAB&")!
        #expect(STK.authorizationCode(from: back) == "ANTMNkAB")
        #expect(STK.authorizationCode(from: URL(string: "https://www.amazon.com/ap/signin?x=1")!) == nil)
    }

    @Test func registrationAndSendFlow() async throws {
        let t = FakeSTKTransport()
        t.responses["/auth/token"] = (200, #"{"access_token":"Atna|tok","token_type":"bearer"}"#)
        t.responses["/FirsProxy/registerDeviceWithToken"] = (200, """
        <?xml version="1.0" encoding="UTF-8"?><response><adp_token>ADP&amp;1</adp_token>\
        <device_private_key>\(STKVector.pkcs8PEM)</device_private_key><device_type>A1K6D1WRW0MALS</device_type>\
        <given_name>Anna</given_name><name>Anna M</name><account_pool>Amazon</account_pool>\
        <user_device_name>Annas 2. Send-to-Kindle</user_device_name><home_region>EU</home_region></response>
        """)
        let reg = try await SendToKindleClient.register(code: "C", verifier: "V", serial: "SERIAL1", deviceName: "Scribe Sync",
                                                        transport: t)
        #expect(reg.adpToken == "ADP&1")
        #expect(reg.homeRegion == "EU")
        #expect(reg.userName == "Anna M")
        let token = try JSONSerialization.jsonObject(with: t.requests[0].body!) as! [String: String]
        #expect(token["source_token"] == "C" && token["code_verifier"] == "V")
        #expect(String(decoding: t.requests[1].body!, as: UTF8.self).contains("<deviceSerialNumber>SERIAL1</deviceSerialNumber>"))

        t.responses["/import/kindle-doc/get-device-list"] = (200, #"""
        {"ownedDevices":[{"deviceName":"Annas Kindle Scribe","deviceSerialNumber":"G0001","deviceCapabilities":{"PDF":true}}],"statusCode":0}
        """#)
        t.responses["/import/upload-url"] = (200, #"{"expiryTime":1,"statusCode":0,"stkToken":"STK1","uploadUrl":"https://s3.example/up?x=1"}"#)
        t.responses["/import/kindle-doc/send-to-kindle"] = (200, #"{"sku":"SKU9","statusCode":0}"#)
        let client = SendToKindleClient(registration: reg, transport: t, crypto: RecordingCrypto())
        #expect(try await client.devices() == [STKDevice(name: "Annas Kindle Scribe", serial: "G0001", capabilities: ["PDF": true])])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Buch \(UUID().uuidString).pdf")
        try Data(repeating: 1, count: 1234).write(to: file)
        let sku = try await client.send(file: file, to: ["G0001"], title: "Ein Buch", author: "Autorin")
        #expect(sku == "SKU9")
        #expect(t.uploads.first?.1.absoluteString == "https://s3.example/up?x=1")
        let send = try JSONSerialization.jsonObject(with: t.requests.last!.body!) as! [String: Any]
        #expect(send["stkToken"] as? String == "STK1")
        #expect(send["targetDevices"] as? [String] == ["G0001"])
        #expect(send["fileSize"] as? Int == 1234)
        #expect(send["forceConvert"] as? Bool == false, "PDF layout is kept by default (Scribe can write on it)")
        let meta = send["documentMetadata"] as! [String: Any]
        #expect(meta["inputFormat"] as? String == "pdf" && meta["title"] as? String == "Ein Buch")
    }

    @Test func rejectsWhatAmazonWouldReject() async throws {
        let client = SendToKindleClient(registration: registration(), transport: FakeSTKTransport(), crypto: RecordingCrypto())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("x.mobi")
        try Data([1]).write(to: file)
        await #expect(throws: STKError.unsupportedFormat("mobi")) {
            _ = try await client.send(file: file, to: ["G"], title: "t", author: "a")
        }
        #expect(STK.format(of: URL(fileURLWithPath: "/a/B.EPUB")) == "epub")
    }

    @Test func authFailureIsExplained() {
        let e = STKError.http(401, "")
        #expect(e.errorDescription?.contains("neu anmelden") == true || e.errorDescription?.contains("sign in") == true)
    }
}
