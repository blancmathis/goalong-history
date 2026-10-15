import XCTest
import LocalHistoryCore
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

    private func pairing() throws -> GoalongSitePairing {
        try GoalongSitePairing(url: XCTUnwrap(URL(string: "goalong-history://connect?site=\(site)#\(code)")))
    }
    private func tokenResponse() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "token": "gl_up_" + String(repeating: "c", count: 43), "scope": "upload:private", "origin": site,
        ])
    }

    func testDiscardRemovesOnlyManagedTokenFilesInsideTheConnectionDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        let managed = try pairing().save(response: tokenResponse(), directory: directory)
        XCTAssertTrue(GoalongSitePairing.discardManagedToken(path: managed.path, directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))

        // A file the user picked by hand, outside the directory, is never deleted.
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let picked = outside.appendingPathComponent(UUID().uuidString + ".token")
        try Data("x".utf8).write(to: picked)
        XCTAssertFalse(GoalongSitePairing.discardManagedToken(path: picked.path, directory: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))

        // A wrong name inside the directory is refused.
        let wrongName = directory.appendingPathComponent("notes.token")
        try Data("x".utf8).write(to: wrongName)
        XCTAssertFalse(GoalongSitePairing.discardManagedToken(path: wrongName.path, directory: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrongName.path))

        // A symlink with a managed name is refused and its target survives.
        let link = directory.appendingPathComponent(UUID().uuidString + ".token")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: picked)
        XCTAssertFalse(GoalongSitePairing.discardManagedToken(path: link.path, directory: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
        XCTAssertFalse(GoalongSitePairing.discardManagedToken(path: "", directory: directory))
    }

    func testReconnectingLeavesExactlyOneManagedTokenFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try pairing().save(response: tokenResponse(), directory: directory)
        let new = try pairing().save(response: tokenResponse(), directory: directory)
        XCTAssertTrue(GoalongSitePairing.discardManagedToken(path: old.path, directory: directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [new.lastPathComponent])
    }

    func testNonJSONPairingBodiesThrowCuratedErrorsAndUserMessagesNeverLeakDomains() throws {
        let html = Data("<html>".utf8)
        XCTAssertThrowsError(try GoalongSitePairing.accountID(response: html)) { XCTAssertTrue($0 is GoalongSiteExportError) }
        XCTAssertThrowsError(try pairing().save(response: html, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))) {
            XCTAssertTrue($0 is GoalongSiteExportError)
        }
        XCTAssertEqual(goalongUserMessage(GoalongGlobalPause.PauseError.changed), GoalongGlobalPause.PauseError.changed.errorDescription)
        let json = NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [NSLocalizedDescriptionKey: "Error Domain=NSCocoaErrorDomain Code=3840"])
        XCTAssertFalse(goalongUserMessage(json).contains("Domain="))
        XCTAssertFalse(goalongUserMessage(URLError(.notConnectedToInternet)).contains("Domain="))
        let other = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error Domain=X Code=1"])
        XCTAssertFalse(goalongUserMessage(other).contains("Domain="))
    }
}
