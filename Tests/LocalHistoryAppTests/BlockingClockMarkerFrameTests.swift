#if os(macOS)
import Foundation
import GoalongGuardCore
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r7 (review of PR #122): the lock markers are read against the wall clock (guard, uninstall.sh,
/// --unregister-guard), so they are written in the wall frame, again when the clock skew moves.
@MainActor final class BlockingClockMarkerFrameTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private final class Client: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var needsConsent = false, canRemove = true
        func update(severeUntil: Date?) -> BlockingProtectionState.Component { severeUntil == nil ? .notInstalled : .running }
        func removeService() {}
    }
    private func store() throws -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("r122-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }
    private func lockedUntilFile(_ store: BlockingStore) -> Double? {
        (try? String(contentsOf: store.directory.appendingPathComponent("locked-until"), encoding: .utf8))
            .flatMap { Double($0.filter(\.isNumber)) }
    }

    /// 2 h locked block, clock set forward 3 h, 10 s real later. Wall readers (uninstall.sh `date +%s`,
    /// `--unregister-guard`, a guard reading the marker) must still see ≈ 2 h left. Witness: jump 0.
    func testForwardJumpKeepsWallSideMarkersInTheFuture() throws {
        for jump in [0.0, 3 * 3_600.0] {
            var wall = start, uptime = 1_000.0
            let store = try store(); try store.save(BlockingDocument(lists: [list]))
            let c = BlockingController( clock: { wall }, store: store, continuous: { uptime }, boot: { "b" }, guardClient: Client())
            c.start(listIDs: [list.id], until: start.addingTimeInterval(7_200), lock: .locked); c.refresh()
            wall += 10 + jump; uptime += 10; c.refresh()
            XCTAssertTrue(c.hasLocks, "jump=\(jump)")
            let files = GoalongGuardFiles.files(for: store.directory)
            guard case .date(let marker) = files.readMarker(now: wall) else { return XCTFail("jump=\(jump): no guard-until") }
            XCTAssertGreaterThan(marker.timeIntervalSince(wall), 7_000, "jump=\(jump): guard-until vs wall (unregister-guard, uninstall.sh)")
            XCTAssertGreaterThan((lockedUntilFile(store) ?? 0) - wall.timeIntervalSince1970, 7_000, "jump=\(jump): locked-until vs wall")
            XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: files.readMarker(now: wall), now: wall, environment: [:]) == false,
                           "jump=\(jump): --unregister-guard accepted during a locked block")
            var arming = GuardArming()   // a guard reading this marker now (new block, or guard restarted without state)
            arming.apply(files.readMarker(now: wall), wall: wall, continuous: uptime, appAlive: true)
            XCTAssertGreaterThan((arming.endContinuous ?? 0) - uptime, 7_000, "jump=\(jump): guard armed short")
        }
    }
}
#endif
