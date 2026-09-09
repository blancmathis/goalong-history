import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongSitePairingTests: XCTestCase {
    private let code = String(repeating: "a", count: 43)
    private let site = "https://goalong.example"

    func testLinkExchangesOnlyItsCodeWithTheSelectedOrigin() throws {
        let pairing = try GoalongSitePairing(url: XCTUnwrap(URL(string: "goalong-history://connect?site=\(site)#\(code)")))
        let request = try pairing.request()
        XCTAssertEqual(request.url?.absoluteString, site + "/api/goalong/v1/native/pairing/claim")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["code": code])
    }

    func testRejectsUnexpectedHandlersInsecureOriginsAndExtraParameters() throws {
        for link in [
            "other://connect?site=\(site)#\(code)",
            "goalong-history://delete?site=\(site)#\(code)",
            "goalong-history://connect?site=http://remote.example#\(code)",
            "goalong-history://connect?site=https://user:secret@remote.example#\(code)",
            "goalong-history://connect?site=\(site)/extra#\(code)",
            "goalong-history://connect?site=\(site)&site=https://other.example#\(code)",
            "goalong-history://connect?site=\(site)#bad",
        ] {
            XCTAssertThrowsError(try GoalongSitePairing(url: XCTUnwrap(URL(string: link))))
        }
    }

    func testCredentialIsPrivateAndRequiresMatchingOriginAndScope() throws {
        let pairing = try GoalongSitePairing(url: XCTUnwrap(URL(string: "goalong-history://connect?site=\(site)#\(code)")))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "gl_up_" + String(repeating: "b", count: 43)
        let response: [String: String] = ["token": token, "scope": "upload:private", "origin": site]
        let file = try pairing.save(response: JSONSerialization.data(withJSONObject: response), directory: directory)
        XCTAssertEqual(try GoalongSiteSubmission.readToken(file: file), token)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for change in [["origin": "https://other.example"], ["scope": "read:all"]] {
            XCTAssertThrowsError(try pairing.save(response: JSONSerialization.data(withJSONObject: response.merging(change) { _, new in new }), directory: directory))
        }
        let symlink = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: directory)
        XCTAssertThrowsError(try pairing.save(response: JSONSerialization.data(withJSONObject: response), directory: symlink))
    }
}
