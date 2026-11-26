import Foundation
@testable import GoalongGuardCore
import XCTest

/// `make perso` self-update (Mathis, 2026-11-22): policy (newer perso build of the same app, 1 install per
/// 10 min during a locked block), atomic swap, rollback, health handshake, inbox files, signature refusal.
final class PersoSelfUpdateTests: XCTestCase {
    private let commitA = String(repeating: "a", count: 40), commitB = String(repeating: "b", count: 40)
    private lazy var running = PersoBundleFacts(bundleIdentifier: "ai.goalong.localhistory", buildNumber: "30000000.4362254.181199",
                                                commit: commitA, builtAt: "2026-11-22T10:00:00Z")
    private lazy var candidate = PersoBundleFacts(bundleIdentifier: "ai.goalong.localhistory", buildNumber: "30000000.4362254.181199",
                                                  commit: commitB, builtAt: "2026-11-22T10:05:00Z")
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("perso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func decide(_ change: (inout PersoBundleFacts) -> Void = { _ in }, protected: Bool = false,
                        age: TimeInterval = 5) -> PersoUpdateDecision {
        var value = candidate
        change(&value)
        return PersoUpdatePolicy.decide(candidate: value, running: running, protected: protected, secondsSinceLaunch: age)
    }

    func testAcceptsNewerPersoBuildOfSameApp() {
        XCTAssertEqual(decide(), .accept)
        XCTAssertEqual(decide { $0.buildNumber = "30000000.4362255.181199" }, .accept)
    }

    func testRefusesOtherAppOlderOrNonPersoBuild() {
        XCTAssertNotEqual(decide { $0.bundleIdentifier = "ai.goalong.localhistory.dev" }, .accept)
        XCTAssertNotEqual(decide { $0.commit = nil }, .accept)
        XCTAssertNotEqual(decide { $0.commit = "abc123" }, .accept)
        XCTAssertNotEqual(decide { $0.buildNumber = "30000000.4362254.181101" }, .accept)
        XCTAssertNotEqual(decide { $0.builtAt = "2026-11-22T10:00:00Z" }, .accept, "same build time is not newer")
        XCTAssertNotEqual(decide { $0.builtAt = "2026-11-22T09:59:59Z" }, .accept)
        XCTAssertNotEqual(decide { $0.builtAt = "2026-11-22 10:05" }, .accept)
        var release = running
        release.commit = nil
        XCTAssertNotEqual(PersoUpdatePolicy.decide(candidate: candidate, running: release, protected: false, secondsSinceLaunch: 900),
                          .accept, "a public release does not self-update")
    }

    func testLockedBlockAllowsOneInstallPerTenMinutes() {
        XCTAssertEqual(decide(protected: false, age: 1), .accept, "no block: no rate limit")
        guard case .refuse(let reason) = decide(protected: true, age: 30) else { return XCTFail("must refuse") }
        XCTAssertTrue(reason.contains("570 s"), reason)
        XCTAssertNotEqual(decide(protected: true, age: 599.5), .accept)
        XCTAssertEqual(decide(protected: true, age: 600), .accept)
    }

    func testBuildNumbersCompareNumerically() {
        XCTAssertEqual(PersoUpdatePolicy.compareBuildNumbers("30000000.10.1", "30000000.9.99"), .orderedDescending)
        XCTAssertEqual(PersoUpdatePolicy.compareBuildNumbers("1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(PersoUpdatePolicy.compareBuildNumbers("1.x", "1.0"), .orderedAscending)
    }

    func testRequestIDsAndStagePaths() {
        XCTAssertTrue(PersoUpdate.isValidRequestID("20261122-100500-12345"))
        for bad in ["", "../x", "a/b", "a b", ".x", String(repeating: "a", count: 65)] {
            XCTAssertFalse(PersoUpdate.isValidRequestID(bad), bad)
        }
        let target = URL(fileURLWithPath: "/Applications/Goalong History.app")
        let staged = PersoStage.stagedApp(for: target, request: "r1")
        XCTAssertEqual(staged.path, "/Applications/.goalong-perso-stage-r1/Goalong History.app")
        XCTAssertEqual(PersoStage.target(forStaged: staged, request: "r1")?.path, target.path)
        XCTAssertNil(PersoStage.target(forStaged: staged, request: "r2"))
        XCTAssertNil(PersoStage.target(forStaged: URL(fileURLWithPath: "/tmp/x/Goalong History.app"), request: "r1"))
    }

    private func makeApp(_ url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/marker"))
    }
    private func marker(_ url: URL) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent("Contents/marker"))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testSwapThenHealthyKeepsNewAndRemovesStage() throws {
        let target = temp.appendingPathComponent("Goalong History.app")
        let staged = PersoStage.stagedApp(for: target, request: "r1")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        try PersoStage.swap(target, staged)
        XCTAssertEqual(marker(target), "new"); XCTAssertEqual(marker(staged), "old")
        try PersoSwapFinish.finish(target: target, staged: staged, healthy: true)
        XCTAssertEqual(marker(target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    func testUnhealthyRollsBackToOldApp() throws {
        let target = temp.appendingPathComponent("Goalong History.app")
        let staged = PersoStage.stagedApp(for: target, request: "r1")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        try PersoStage.swap(target, staged)
        try PersoSwapFinish.finish(target: target, staged: staged, healthy: false)
        XCTAssertEqual(marker(target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    func testSwapFailsWithoutTouchingTargetWhenStageMissing() throws {
        let target = temp.appendingPathComponent("Goalong History.app")
        try makeApp(target, marker: "old")
        XCTAssertThrowsError(try PersoStage.swap(target, PersoStage.stagedApp(for: target, request: "r1")))
        XCTAssertEqual(marker(target), "old")
    }

    func testHealthMatchesOnlyThePidAndBuild() {
        let files = PersoUpdateFiles(root: temp)
        XCTAssertFalse(files.healthMatches(pid: 42, builtAt: "2026-11-22T10:05:00Z"))
        files.writeHealth(.init(pid: 42, builtAt: "2026-11-22T10:05:00Z"))
        XCTAssertTrue(files.healthMatches(pid: 42, builtAt: "2026-11-22T10:05:00Z"))
        XCTAssertFalse(files.healthMatches(pid: 43, builtAt: "2026-11-22T10:05:00Z"), "the old instance's health never counts")
        XCTAssertFalse(files.healthMatches(pid: 42, builtAt: "2026-11-22T10:00:00Z"))
        XCTAssertFalse(files.healthMatches(pid: 42, builtAt: nil))
    }

    func testInboxListsReadyRequestsAndResultsNeverCreateFolders() throws {
        let files = PersoUpdateFiles(root: temp)
        for id in ["b2", "a1", ".tmp-c3"] {
            try FileManager.default.createDirectory(at: files.request(id), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: files.request(id).appendingPathComponent("request.json"))
        }
        try FileManager.default.createDirectory(at: files.request("d4"), withIntermediateDirectories: true)
        XCTAssertEqual(files.pendingRequests(), ["a1", "b2"])
        files.writeResult("a1", .init(state: PersoUpdateFiles.Result.refused, reason: "x"))
        XCTAssertEqual(files.readResult("a1"), .init(state: "refused", reason: "x"))
        XCTAssertEqual(files.pendingRequests(), ["b2"])
        files.writeResult("zz", .init(state: PersoUpdateFiles.Result.installed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.request("zz").path))
    }

    #if os(macOS)
    func testUnsignedCandidateIsRefused() throws {
        let app = temp.appendingPathComponent("Fake.app")
        try makeApp(app, marker: "x")
        let reference = try XCTUnwrap(PersoSignature.selfStaticCode())
        XCTAssertNotNil(PersoSignature.check(candidate: app, reference: reference))
        XCTAssertNotNil(PersoSignature.check(candidate: temp.appendingPathComponent("Missing.app"), reference: reference))
    }
    #endif

    // installation-03: health only after a complete launch, never after a fatal one.
    func testFatalStartupNeverDeclaresHealth() {
        var health = PersoStartupHealth()
        health.startupFailed()
        XCTAssertFalse(health.startupSucceeded())
        var ok = PersoStartupHealth()
        XCTAssertTrue(ok.startupSucceeded())
        XCTAssertFalse(ok.startupSucceeded(), "declared once")
    }

    // installation-02: the request is claimed before the slow checks; removing it cancels before the swap.
    func testClaimedRequestIsOwnedUntilCancelled() throws {
        let files = PersoUpdateFiles(root: temp)
        XCTAssertFalse(files.writeResult("r1", .init(state: PersoUpdateFiles.Result.claimed)), "no folder, nothing written")
        try FileManager.default.createDirectory(at: files.request("r1"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: files.request("r1").appendingPathComponent("request.json"))
        XCTAssertTrue(files.writeResult("r1", .init(state: PersoUpdateFiles.Result.claimed)))
        XCTAssertEqual(files.pendingRequests(), [], "a claimed request is not scanned again")
        XCTAssertTrue(files.stillOwned("r1"))
        XCTAssertTrue(files.writeResult("r1", .init(state: PersoUpdateFiles.Result.accepted)))
        XCTAssertTrue(files.stillOwned("r1"))
        try FileManager.default.removeItem(at: files.request("r1"))
        XCTAssertFalse(files.stillOwned("r1"), "the script cancelled: no swap")
    }
}
