#if os(macOS)
import Foundation
import Darwin
import XCTest
import LocalHistoryCore
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

final class GoalongIntegrationSmokeTests: XCTestCase {
    private func root(_ prefix: String) throws -> URL {
        let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testGranularSelectionRoundTripsWithoutBroadeningAndRejectsLinks() throws {
        let directory = try root("goalong-selection-v2-")
        var policy = GoalongPrivacyPolicy(); policy.revision = "fixture-revision"
        var selection = GoalongAnalysisSelection()
        selection.reviewed = true; selection.computer = true; selection.screenTime = true
        selection.privacyRevision = policy.revision
        var scope = GoalongAnalysisScope()
        scope.applicationIDs = ["test.editor", "test.browser"]
        scope.detailApplicationIDs = ["test.editor"]
        scope.applicationNames = ["test.editor":"Éditeur", "test.browser":"Navigateur"]
        scope.deviceIDs = ["device-one"]
        scope.visibleText = true
        scope.perApplicationFields = ["test.editor":["windowTitles"]]
        scope.excludedDomains = ["private.example.org"]
        selection.scope = scope
        selection.replacements = [GoalongTextReplacement(search:"Hi Charlie",replacement:"Projet A")]
        selection.outputGuidance = "Privilégie les progrès."
        try selection.save(root: directory)
        let restored = GoalongAnalysisSelection.load(root: directory)
        XCTAssertEqual(restored, selection)
        XCTAssertTrue(restored.isValid(for: policy))
        XCTAssertFalse(restored.scope!.allows(id: "test.new", name: "New application"))
        XCTAssertFalse(restored.scope!.allows(.visibleText,id:"test.editor",name:"Éditeur"))
        XCTAssertFalse(restored.scope!.allowsDetails(id:"test.browser",name:"Navigateur"))
        let file = directory.appendingPathComponent("chatgpt-analysis-selection.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let outside = directory.appendingPathComponent("unrelated.json")
        try Data("untouched".utf8).write(to:outside)
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
        XCTAssertThrowsError(try selection.save(root:directory))
        XCTAssertEqual(try String(contentsOf:outside),"untouched")
        XCTAssertFalse(GoalongAnalysisSelection.load(root:directory).reviewed)
    }

    func testLoopbackRequestsReceiptsAndFailureBoundaries() throws {
        guard let raw = ProcessInfo.processInfo.environment["GOALONG_TEST_LOOPBACK_PORT"],
              let port = UInt16(raw), port > 0 else { throw XCTSkip("Opt-in local-only transport fixture") }
        let root = try root("goalong-transport-")
        let token = root.appendingPathComponent("synthetic.token")
        try Data("synthetic-local-transport-test-token".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let origin = "http://127.0.0.1:\(port)"
        for mode in ["success", "refused", "redirect", "invalid-receipt", "oversized", "server-error"] {
            let payload = try JSONSerialization.data(withJSONObject: ["fixture":mode,"data":"synthetic only"],options:[.sortedKeys])
            if mode == "success" {
                let receipt = try GoalongSiteSubmission.send(payload: payload, origin: origin, tokenFile: token, privacyRoot: root)
                let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: receipt) as? [String: Any])
                XCTAssertEqual(result["verification"] as? String,"unverified")
                XCTAssertEqual(result["imported"] as? Int,1)
            } else {
                XCTAssertThrowsError(try GoalongSiteSubmission.send(payload: payload, origin: origin, tokenFile: token, privacyRoot: root),mode)
            }
        }
    }
    func testBundledCodexStartsWithAnEmptyIsolatedAccount() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_TEST_CODEX_RUNTIME"] else {
            throw XCTSkip("Opt-in bundled runtime integration")
        }
        let home = try root("goalong-runtime-empty-").appendingPathComponent("account",isDirectory:true)
        let session = try CodexAppServerSession(executableURL: URL(fileURLWithPath:path),codexHomeURL:home)
        defer { session.close() }
        XCTAssertNil(try session.readAccount(refreshToken:false),"The isolated runtime must not inherit the user's real account")
        XCTAssertFalse(FileManager.default.fileExists(atPath:home.appendingPathComponent("auth.json").path))
    }
}
#endif
