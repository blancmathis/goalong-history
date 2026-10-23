#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import LocalHistoryApp

final class InstallationLocationManagerTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeBundle(in root: URL, name: String = "Goalong History.app", identifier: String = "ai.goalong.localhistory",
                            version: String) throws -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleVersion": version, "CFBundleName": "Test"]
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    private func version(of bundle: URL) -> String? {
        // Read the plist directly: Bundle caches one instance per URL.
        (NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))?["CFBundleVersion"] as? String
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    func testFailedCopyLeavesTheInstalledBundleAndNoResidue() throws {
        let root = try makeRoot()
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = try makeBundle(in: applications, version: "1")
        XCTAssertThrowsError(try InstallationLocationManager.replaceApplication(
            at: installed, with: root.appendingPathComponent("Missing.app")))
        XCTAssertEqual(version(of: installed), "1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Goalong History.app"])
    }

    func testForeignBundleIsNeverReplaced() throws {
        let root = try makeRoot()
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let foreign = try makeBundle(in: applications, identifier: "com.example.other", version: "9")
        let source = try makeBundle(in: root, name: "Source.app", version: "2")
        XCTAssertThrowsError(try InstallationLocationManager.replaceApplication(at: foreign, with: source)) {
            XCTAssertEqual(($0 as? InstallationError)?.errorDescription,
                           InstallationError.destinationOccupied.errorDescription)
        }
        XCTAssertEqual(version(of: foreign), "9")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Goalong History.app"])
    }

    func testSuccessfulReplaceInstallsTheNewVersionWithoutQuarantineOrTemporaryCopy() throws {
        let root = try makeRoot()
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = try makeBundle(in: applications, version: "1")
        let source = try makeBundle(in: root, name: "Source.app", version: "2")
        let nested = source.appendingPathComponent("Contents/Info.plist")
        for url in [source, nested] {
            XCTAssertEqual(setxattr(url.path, "com.apple.quarantine", "0081;00000000;Test;", 19, 0, 0), 0)
        }
        try InstallationLocationManager.replaceApplication(at: installed, with: source)
        XCTAssertEqual(version(of: installed), "2")
        XCTAssertFalse(hasQuarantine(installed))
        XCTAssertFalse(hasQuarantine(installed.appendingPathComponent("Contents/Info.plist")))
        XCTAssertTrue(hasQuarantine(source), "The source is never touched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Goalong History.app"])
    }

    func testFreshInstallMovesTheCopyIntoPlace() throws {
        let root = try makeRoot()
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let source = try makeBundle(in: root, name: "Source.app", version: "3")
        let destination = applications.appendingPathComponent("Goalong History.app")
        try InstallationLocationManager.replaceApplication(at: destination, with: source)
        XCTAssertEqual(version(of: destination), "3")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Goalong History.app"])
    }

    func testTranslocatedCopyOfTheInstalledVersionIsNotReplaced() throws {
        let root = try makeRoot()
        let installed = try makeBundle(in: root.appendingPathComponent("Applications", isDirectory: true), version: "5")
        let translocatedRoot = root.appendingPathComponent("AppTranslocation/ABC/d", isDirectory: true)
        let sameVersion = try makeBundle(in: translocatedRoot, version: "5")
        let newer = try makeBundle(in: translocatedRoot.appendingPathComponent("n", isDirectory: true), version: "6")
        XCTAssertEqual(InstallationLocationManager.replacementDecision(source: sameVersion, destination: installed), .alreadyInstalled)
        XCTAssertEqual(InstallationLocationManager.replacementDecision(source: newer, destination: installed), .replace)
        let downloaded = try makeBundle(in: root.appendingPathComponent("Downloads"), version: "5")
        XCTAssertEqual(InstallationLocationManager.replacementDecision(source: downloaded, destination: installed), .replace)
    }

    func testOlderCopyNeverReplacesANewerInstall() throws {
        let root = try makeRoot()
        let installed = try makeBundle(in: root.appendingPathComponent("Applications", isDirectory: true), version: "10")
        let translocatedRoot = root.appendingPathComponent("AppTranslocation/ABC/d", isDirectory: true)
        let older = try makeBundle(in: translocatedRoot, version: "9")
        XCTAssertEqual(InstallationLocationManager.replacementDecision(source: older, destination: installed), .installedIsNewer)
        let volume = try makeBundle(in: root.appendingPathComponent("Volumes"), version: "9")
        XCTAssertEqual(InstallationLocationManager.replacementDecision(source: volume, destination: installed), .installedIsNewer)
    }

    func testAggregateDecisionChecksEveryExistingCopy() throws {
        let root = try makeRoot()
        let newerCopy = try makeBundle(in: root.appendingPathComponent("A", isDirectory: true), version: "10")
        let olderCopy = try makeBundle(in: root.appendingPathComponent("B", isDirectory: true), version: "3")
        let missing = root.appendingPathComponent("C/Goalong History.app", isDirectory: true)
        let older = try makeBundle(in: root.appendingPathComponent("AppTranslocation/x/d", isDirectory: true), version: "9")
        let result = InstallationLocationManager.aggregateDecision(source: older, candidates: [missing, newerCopy])
        XCTAssertEqual(result.0, .installedIsNewer)
        XCTAssertEqual(result.1, newerCopy)
        XCTAssertEqual(InstallationLocationManager.aggregateDecision(source: older, candidates: [olderCopy, missing]).0, .replace)
        let same = try makeBundle(in: root.appendingPathComponent("AppTranslocation/y/d", isDirectory: true), version: "3")
        let sameResult = InstallationLocationManager.aggregateDecision(source: same, candidates: [missing, olderCopy])
        XCTAssertEqual(sameResult.0, .alreadyInstalled)
        XCTAssertEqual(sameResult.1, olderCopy)
    }

    func testRevealFolderFallsBackToApplications() {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let user = URL(fileURLWithPath: "/Users/x/Applications", isDirectory: true)
        XCTAssertEqual(InstallationLocationManager.revealFolder(attempted: system, exists: { _ in true }), system)
        XCTAssertEqual(InstallationLocationManager.revealFolder(attempted: user, exists: { _ in true }), user)
        XCTAssertEqual(InstallationLocationManager.revealFolder(attempted: user, exists: { _ in false }), system)
        XCTAssertEqual(InstallationLocationManager.revealFolder(attempted: nil, exists: { _ in true }), system)
    }

    private final class FakeInstance: RunningInstance {
        var isTerminated = false
        var terminateCalls = 0
        let quits: Bool
        init(quits: Bool) { self.quits = quits }
        func terminate() -> Bool { terminateCalls += 1; if quits { isTerminated = true }; return true }
    }

    func testRunningInstanceMustQuitBeforeAnyDiskChange() throws {
        let none = try InstallationLocationManager.quitOtherInstances([], confirm: { XCTFail("no prompt"); return false })
        XCTAssertTrue(none)
        let willQuit = FakeInstance(quits: true)
        XCTAssertTrue(try InstallationLocationManager.quitOtherInstances([willQuit], confirm: { true }, sleep: { _ in }))
        XCTAssertEqual(willQuit.terminateCalls, 1)
        let declined = FakeInstance(quits: true)
        XCTAssertFalse(try InstallationLocationManager.quitOtherInstances([declined], confirm: { false }, sleep: { _ in }))
        XCTAssertEqual(declined.terminateCalls, 0)
        let stuck = FakeInstance(quits: false)
        XCTAssertThrowsError(try InstallationLocationManager.quitOtherInstances([stuck], timeout: 0.3, confirm: { true }, sleep: { _ in }))
    }
}
#endif
