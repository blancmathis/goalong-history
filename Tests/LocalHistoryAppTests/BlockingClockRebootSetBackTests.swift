#if os(macOS)
import Foundation
import GoalongGuardCore
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 C6-05: a clock set back during a locked block, then a reboot, must not hide the block.
@MainActor final class BlockingClockRebootSetBackTests: XCTestCase {
    private let real = Date(timeIntervalSince1970: 1_790_000_000)
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private final class Client: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var needsConsent = false, canRemove = true
        func update(severeUntil: Date?) -> BlockingProtectionState.Component { severeUntil == nil ? .notInstalled : .running }
        func removeService() {}
    }
    private func store() throws -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("reboot-setback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }

    /// Same, but the clock was set back 8 h during boot a (T stayed real), then a reboot kept it back:
    /// the reboot moves no end (wall unchanged), the floor step then adds 8 h to the ends.
    func testClockSetBackBeforeRebootThenStepKeepsBlockRealLength() throws {
        for behind in [0.0, 8 * 3_600.0] {
            let store = try store(); try store.save(BlockingDocument(lists: [list]))
            var wall = real, uptime = 1_000.0, boot = "a"
            let a = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            a.start(listIDs: [list.id], until: real.addingTimeInterval(7_200), lock: .locked); a.refresh()
            wall = real.addingTimeInterval(600 - behind); uptime += 600; a.refresh()
            boot = "b"; uptime = 30; wall = real.addingTimeInterval(630 - behind)
            let b = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            b.refresh()
            wall = real.addingTimeInterval(690); uptime += 60; b.refresh()
            let left = b.activeBlocks.first.map { $0.end.timeIntervalSince(b.now) } ?? -1
            XCTAssertEqual(left, 6_510, accuracy: 40, "behind=\(behind): T-side time left")
        }
    }
}
#endif
