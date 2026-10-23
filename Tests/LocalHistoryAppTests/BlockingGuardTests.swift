#if os(macOS)
import Foundation
import GoalongGuardCore
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// Spec K, app side: which blocks arm the guard, the `guard-until` marker, the injected client, the gate,
/// the uninstall refusal and the copy. No SMAppService, no launchd, no process: the client is a fake.
@MainActor final class BlockingGuardTests: XCTestCase {
    private final class FakeGuardClient: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var needsConsent = true
        var canRemove = true
        var answer: BlockingProtectionState.Component = .running
        private(set) var updates: [Date?] = []
        private(set) var removals = 0
        func update(severeUntil: Date?) -> BlockingProtectionState.Component {
            updates.append(severeUntil)
            return severeUntil == nil ? .notInstalled : answer
        }
        func removeService() { removals += 1 }
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])

    private func store() throws -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("blocking-guard-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }

    private func controller(_ document: BlockingDocument, clock: @escaping () -> Date) throws
        -> (BlockingController, FakeGuardClient, GuardFiles) {
        let store = try store()
        try store.save(document)
        let client = FakeGuardClient()
        let controller = BlockingController(clock: clock, store: store, continuous: { clock().timeIntervalSince1970 },
                                            guardClient: client)
        controller.refresh()
        return (controller, client, GoalongGuardFiles.files(for: store.directory))
    }

    private func session(_ lock: BlockLock, start: TimeInterval = 0, end: TimeInterval = 3600) -> BlockSession {
        BlockSession(listIDs: [list.id], start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), lock: lock)
    }

    /// R2: a free or « Difficile » block and a locked session that has not started arm nothing.
    func testOnlySevereBlocksArmTheGuard() throws {
        for document in [BlockingDocument(lists: [list]),
                         BlockingDocument(lists: [list], sessions: [session(.free)]),
                         BlockingDocument(lists: [list], sessions: [session(.typing)]),
                         BlockingDocument(lists: [list], sessions: [session(.locked, start: 600, end: 3600)])] {
            let (c, client, files) = try controller(document) { [now] in now }
            XCTAssertNil(c.severeUntil)
            XCTAssertEqual(files.readMarker(now: now), .absent)
            XCTAssertTrue(client.updates.allSatisfy { $0 == nil }, "nothing to register, nothing to ping")
            XCTAssertEqual(c.protection.guardian, .notInstalled)
            XCTAssertEqual(c.protection.level, .standard)
        }
    }

    func testLockedPasswordFreezeAndProgramWriteTheirEnd() throws {
        var program = list
        program.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900)],
                                       lockedUntil: now.addingTimeInterval(7200))
        let end = now.addingTimeInterval(3600)
        let cases: [(String, BlockingDocument, Date)] = [
            ("locked", BlockingDocument(lists: [list], sessions: [session(.locked)]), end),
            ("password", BlockingDocument(lists: [list], sessions: [session(.password)]), end),
            ("freeze", BlockingDocument(lists: [list], freeze: BlockFreeze(start: now, end: end, mode: .shield)), end),
            ("program", BlockingDocument(lists: [program]), now.addingTimeInterval(7200)),
        ]
        for (name, document, expected) in cases {
            let (c, client, files) = try controller(document) { [now] in now }
            XCTAssertEqual(c.severeUntil, expected, name)
            XCTAssertEqual(files.readMarker(now: now), .date(expected), name)
            XCTAssertEqual(client.updates.last, .some(expected), name)
            XCTAssertEqual(c.protection.guardian, .running, name)
            XCTAssertEqual(c.protection.level, .strict, name)
            XCTAssertFalse(c.canRemoveGuard, "\(name): the remove button hides during a severe block")
        }
    }

    func testADeletedMarkerIsRewrittenAndTheEndRemovesIt() throws {
        var clockNow = now
        let (c, client, files) = try controller(BlockingDocument(lists: [list], sessions: [session(.locked)])) { clockNow }
        XCTAssertTrue(files.writeMarker(until: nil))
        c.refresh()
        XCTAssertEqual(files.readMarker(now: now), .date(now.addingTimeInterval(3600)), "rewritten although the memo matched")
        client.answer = .awaitingApproval
        c.refresh()
        XCTAssertEqual(c.protection.guardian, .awaitingApproval)
        XCTAssertEqual(c.protection.level, .standard, "only a running guard makes the protection strict")
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(c.protection), "À autoriser dans Réglages › Général › Ouverture")
        XCTAssertNil(c.error, "the guard never raises an error message")
        clockNow = now.addingTimeInterval(3601)
        c.refresh()
        XCTAssertEqual(files.readMarker(now: clockNow), .absent)
        XCTAssertEqual(client.updates.last, .some(nil))
        XCTAssertTrue(c.canRemoveGuard)
        c.removeGuardService()
        XCTAssertEqual(client.removals, 1)
    }

    func testLevelLabels() {
        var state = BlockingProtectionState()
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(state), "Standard")
        state.guardian = .failed("x")
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(state), "Indisponible")
        state.guardian = .running; state.level = .strict
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(state), "Renforcé")
    }

    func testConsentSentenceIsAddedOnlyBeforeTheFirstRegistration() {
        XCTAssertEqual(GuardConsent.message("Base.", needed: false), "Base.")
        XCTAssertEqual(GuardConsent.message("Base.", needed: true), "Base.\n\n" + GuardConsent.text)
        XCTAssertTrue(GuardConsent.text.contains("Aucun mot de passe"))
    }

    func testGateAllowsOnlyInstalledCopiesOfTheFamily() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let release: [String: Any] = ["CFBundleIdentifier": "ai.goalong.localhistory"]
        let dev: [String: Any] = ["CFBundleIdentifier": "ai.goalong.localhistory.dev", "GoalongBuildChannel": "dev"]
        func allowed(_ path: String, _ info: [String: Any]) -> Bool {
            GoalongGuardGate.isAllowed(bundleURL: URL(fileURLWithPath: path, isDirectory: true), info: info, home: home)
        }
        XCTAssertTrue(allowed("/Applications/Goalong History.app", release))
        XCTAssertTrue(allowed("/Users/someone/Applications/Goalong Dev.app", dev))
        XCTAssertFalse(allowed("/Users/someone/Developer/goalong/dist/Goalong History.app", release), "a build folder")
        XCTAssertFalse(allowed("/private/var/folders/x/AppTranslocation/y/d/Goalong History.app", release))
        XCTAssertFalse(allowed("/Applications/Other.app", ["CFBundleIdentifier": "com.example.other"]))
        XCTAssertFalse(allowed("/Applications/Goalong Dev.app", ["CFBundleIdentifier": "ai.goalong.localhistory.dev"]),
                       "the dev id without its channel would use the release data folder")
        XCTAssertFalse(allowed("/Applications/xctest", release))
    }

    func testUnregisterIsRefusedDuringASevereBlockUnlessOverridden() {
        let future = GuardMarker.date(now.addingTimeInterval(60))
        XCTAssertTrue(GuardUnregisterCommand.isRefused(marker: future, now: now, environment: [:]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: future, now: now, environment: ["GOALONG_UNINSTALL_DURING_LOCK": "1"]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: future, now: now, environment: ["GOALONG_INSTALL_DURING_LOCK": "1"]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: .date(now.addingTimeInterval(-1)), now: now, environment: [:]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: .absent, now: now, environment: [:]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: .invalid, now: now, environment: [:]))
        XCTAssertEqual(GuardUnregisterCommand.refusedExitCode, 3)
    }

    func testLeaseIsWrittenOnlyWhileArmed() throws {
        let root = try store().directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = GoalongGuardFiles.files(for: root)
        GoalongGuardFiles.writeLease(GuardLease.update, seconds: 180, files: files)
        XCTAssertNil(files.readLease(), "no severe block: nothing written")
        XCTAssertTrue(files.writeMarker(until: Date().addingTimeInterval(600)))
        GoalongGuardFiles.writeLease(GuardLease.update, seconds: 180, files: files)
        XCTAssertEqual(files.readLease()?.reason, GuardLease.update)
        XCTAssertEqual(files.readLease()?.pid, getpid())
        GoalongGuardFiles.reportHealth(files)
        XCTAssertEqual(files.readHealth()?.pid, getpid())
        files.clearTokens()
        XCTAssertNil(files.readLease())
    }
}
#endif
