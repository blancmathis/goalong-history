#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-057 F2 (bugs-temps-02): the usage day kept across a zone change survives a relaunch until its old midnight.
final class UsageDayCarryRelaunchTests: XCTestCase {
    private func zone(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }

    @MainActor func testUsedQuotaStaysUsedAfterRelaunchInTheNewZone() throws {
        let root = URL(fileURLWithPath: "/private/tmp/usage-carry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = BlockingStore(directory: root.appendingPathComponent("Blocking"))
        let paris = zone("Europe/Paris")
        var now = paris.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 23, minute: 30))!
        let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 5)
        _ = try store.save(BlockingDocument(lists: [list], usage: BlockDayUsage(day: "2026-11-27", quotaSecondsUsed: [list.id: 300])), now: now)
        var current = paris
        let first = BlockingController(clock: { now }, store: store, calendarProvider: { current }, continuous: { now.timeIntervalSince1970 })
        XCTAssertEqual(first.frictionUsage?.quotaSecondsUsed[list.id], 300)
        current = zone("Europe/Athens"); first.refresh()                 // 00:30 on the 28th in Athens
        XCTAssertEqual(first.frictionUsage?.day, "2026-11-27")
        // Relaunch at 00:35 Athens, same store: the quota of the 27th stays used until 00:00 Paris (01:00 Athens).
        now += 300
        let second = BlockingController(clock: { now }, store: store, calendarProvider: { current }, continuous: { now.timeIntervalSince1970 })
        second.refresh()
        XCTAssertEqual(second.frictionUsage?.day, "2026-11-27")
        XCTAssertEqual(second.frictionUsage?.quotaSecondsUsed[list.id], 300, "a used quota is not handed back early")
        now = paris.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 0, minute: 0, second: 1))!
        second.refresh()
        XCTAssertEqual(second.frictionUsage?.day, "2026-11-28", "renewed at the old midnight")
        XCTAssertNil(second.frictionUsage?.quotaSecondsUsed[list.id])
    }
}
#endif
