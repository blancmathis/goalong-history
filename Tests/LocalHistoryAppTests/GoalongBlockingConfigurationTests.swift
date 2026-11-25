#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryQueryCLI

/// Exercises the public agent boundary with disposable native controllers, never the installed app.
@MainActor final class GoalongBlockingConfigurationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-25T10:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }
    private func controller(_ document: BlockingDocument = BlockingDocument(), store: BlockingStore? = nil) -> BlockingController {
        let instant = now
        let value = BlockingController(document: document, clock: { instant }, store: store, calendar: calendar,
            continuous: { instant.timeIntervalSince1970 }, boot: { "blocking-configuration-test" }, runsTimers: false, runningApps: { [] })
        addTeardownBlock { @MainActor in value.shutdown() }
        return value
    }
    private func store() -> BlockingStore {
        let directory = URL(fileURLWithPath: "/private/tmp/goalong-block-configuration-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return BlockingStore(directory: directory)
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try decoded(FocusJSON.encode(value))
    }
    private func decoded(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func put(_ list: BlockList, match: String, to controller: BlockingController) throws -> [String: Any] {
        try decoded(GoalongBlockingConfiguration.handle(
            GoalongFocusRequest(command: "block-list put", options: ["--if-match": match], body: data(["list": object(list)])),
            controller: controller))
    }
    private func putObject(_ object: [String: Any], to controller: BlockingController, match: String = "new") throws -> Data {
        try GoalongBlockingConfiguration.handle(
            GoalongFocusRequest(command: "block-list put", options: ["--if-match": match], body: data(object)),
            controller: controller)
    }
    private func show(_ id: UUID, from controller: BlockingController) throws -> [String: Any] {
        try decoded(GoalongBlockingConfiguration.handle(
            GoalongFocusCLI.parse(command: "block-list", arguments: ["show", id.uuidString]), controller: controller))
    }
    private func assertError(_ expected: GoalongFocusError, file: StaticString = #filePath, line: UInt = #line,
                             _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? GoalongFocusError, expected, file: file, line: line)
        }
    }
    private func protectedList() -> BlockList {
        var range = BlockProgramRange(weekdays: Set(1...7), startMinute: 1260, endMinute: 1380, lock: .password)
        range.pause = PausePolicy(budgetMinutes: 10)
        return BlockList(name: "Sites choisis", sites: [.init(pattern: "video.example")], program: BlockProgram(ranges: [range]))
    }
    private func protectedController(_ list: BlockList) throws -> BlockingController {
        let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let value = controller(.init(lists: [list], passwordLock: credential))
        value.stopGrant = RuleStopGrant(uptime: { 1000 }, verifyPassword: { $0 == "fixture" ? .ok : .wrong(remaining: 3) })
        return value
    }

    func testCreateShowAndCompareAndSwapPersistTheNativeList() throws {
        let store = store()
        let c = controller(store: store)
        let list = BlockList(name: "Sites choisis", sites: [.init(pattern: "video.example")])
        let created = try put(list, match: "new", to: c)
        let firstHash = try XCTUnwrap(created["fingerprint"] as? String)
        XCTAssertEqual(firstHash.count, 64)
        XCTAssertTrue(firstHash.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(created["schema"] as? Int, 1)
        XCTAssertEqual(created["locked"] as? Bool, false)
        XCTAssertEqual(created["hasPassword"] as? Bool, false)
        XCTAssertEqual(try show(list.id, from: c)["fingerprint"] as? String, firstHash)
        XCTAssertEqual(try store.load().lists.first?.id, list.id)

        var changed = try XCTUnwrap(c.list(list.id))
        changed.name = "Sites de travail"
        let updated = try put(changed, match: firstHash, to: c)
        let secondHash = try XCTUnwrap(updated["fingerprint"] as? String)
        XCTAssertNotEqual(firstHash, secondHash)
        XCTAssertEqual(try store.load().lists.first?.name, "Sites de travail")
        assertError(.conflict) { _ = try put(list, match: "new", to: c) }
        assertError(.conflict) { _ = try put(list, match: firstHash, to: c) }
        XCTAssertEqual(try show(list.id, from: c)["fingerprint"] as? String, secondHash)
        XCTAssertEqual(c.list(list.id)?.name, "Sites de travail")
        assertError(.notFound) { _ = try show(UUID(), from: c) }
    }

    func testLoopbackConfigurationPersistsAndProtectedAllowListStillRefusesExpansion() throws {
        let store = store()
        let c = controller(store: store)
        let local = BlockList(name: "Local service", mode: .allowOnly, sites: [.init(pattern: "127.0.0.1:4310/project")])
        _ = try put(local, match: "new", to: c)
        XCTAssertEqual(try store.load().lists.first?.sites, local.sites)
        let edited = BlockListEditor.addSite("http://localhost:4310/project/?secret=value", to: local, controller: c)
        XCTAssertNil(edited.error)
        XCTAssertEqual(edited.text, "")
        XCTAssertTrue(try XCTUnwrap(c.list(local.id)).sites.contains(.init(pattern: "localhost:4310/project")))
        XCTAssertEqual(try store.load().lists.first?.sites.count, 2)

        var protected = protectedList()
        protected.mode = .allowOnly
        let guarded = try protectedController(protected)
        XCTAssertTrue(guarded.activeBlocks.isEmpty)
        var expanded = protected
        expanded.sites.append(.init(pattern: "127.0.0.1:4310"))
        let hash = try GoalongBlockingConfiguration.fingerprint(protected)
        assertError(.locked) { _ = try put(expanded, match: hash, to: guarded) }
        XCTAssertEqual(guarded.list(protected.id), protected)
        guarded.start(listIDs: [protected.id], until: now.addingTimeInterval(600), lock: .password)
        XCTAssertTrue(guarded.isStricterOnly(protected.id))
        assertError(.locked) { _ = try put(expanded, match: hash, to: guarded) }
        XCTAssertEqual(guarded.list(protected.id), protected)
    }

    func testFingerprintIsIndependentOfWeekdaySetInsertionOrder() throws {
        var list = protectedList()
        list.program.ranges[0].weekdays = Set([1, 3, 5, 7])
        var reordered = list
        reordered.program.ranges[0].weekdays = Set([7, 5, 3, 1])
        XCTAssertEqual(try GoalongBlockingConfiguration.fingerprint(list),
                       try GoalongBlockingConfiguration.fingerprint(reordered))
        reordered.program.ranges[0].weekdays = Set([1, 3, 5])
        XCTAssertNotEqual(try GoalongBlockingConfiguration.fingerprint(list),
                          try GoalongBlockingConfiguration.fingerprint(reordered))
    }

    func testUnknownPasswordsAndEnforcementFieldsAreRejectedAtTheAgentBoundary() throws {
        let list = BlockList(name: "Liste", sites: [.init(pattern: "video.example")])
        let c = controller(.init(lists: [list]))
        let initial = try object(list)
        let hash = try GoalongBlockingConfiguration.fingerprint(list)
        for key in ["unknown", "password", "passwordLock", "session", "sessions", "freeze", "clock", "allowances"] {
            var invalidList = initial
            invalidList[key] = "not-accepted"
            assertError(.invalidArgument) {
                _ = try putObject(["list": invalidList], to: c, match: hash)
            }
            assertError(.invalidArgument) {
                _ = try putObject(["list": initial, key: "not-accepted"], to: c, match: hash)
            }
            XCTAssertEqual(c.list(list.id), list)
        }
        var badProgram = initial
        badProgram["program"] = ["ranges": [], "session": [:]]
        assertError(.invalidArgument) { _ = try putObject(["list": badProgram], to: c, match: hash) }
        var badSite = initial
        badSite["sites"] = [["pattern": "video.example", "password": "not-accepted"]]
        assertError(.invalidArgument) { _ = try putObject(["list": badSite], to: c, match: hash) }
        var noID = initial
        noID.removeValue(forKey: "id")
        assertError(.invalidArgument) { _ = try putObject(["list": noID], to: c) }
        XCTAssertEqual(c.list(list.id), list)
        XCTAssertFalse(c.hasPassword)
        XCTAssertTrue(c.snapshot.sessions.isEmpty)
    }

    func testExtremeCalendarAndPauseIntegersAreRejectedBeforeNativeCoverageCalculations() throws {
        var list = BlockList(name: "Bornes", sites: [.init(pattern: "video.example")])
        var range = BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 660, lock: .free)
        range.pause = PausePolicy(budgetMinutes: 10)
        list.program.ranges = [range]
        let original = try object(list)
        let originalProgram = try XCTUnwrap(original["program"] as? [String: Any])
        let originalRanges = try XCTUnwrap(originalProgram["ranges"] as? [[String: Any]])
        let c = controller()
        for field in ["weekdays", "startMinute", "endMinute", "budgetMinutes", "maxPauseMinutes", "maxPauses"] {
            var candidate = original
            var program = originalProgram
            var ranges = originalRanges
            if field == "weekdays" { ranges[0][field] = [Int.max] }
            else if field == "startMinute" || field == "endMinute" { ranges[0][field] = Int.max }
            else {
                var pause = try XCTUnwrap(ranges[0]["pause"] as? [String: Any])
                pause[field] = Int.max
                ranges[0]["pause"] = pause
            }
            program["ranges"] = ranges
            candidate["program"] = program
            let body = try data(["list": candidate])
            assertError(.invalidArgument) { try GoalongFocusCLI.validateBlockListInput(body) }
            assertError(.invalidArgument) {
                _ = try GoalongBlockingConfiguration.handle(
                    GoalongFocusRequest(command: "block-list put", options: ["--if-match": "new"], body: body), controller: c)
            }
            XCTAssertTrue(c.lists.isEmpty)
        }
    }

    func testScheduledProtectedWeakeningCannotAskForOrBorrowAPasswordGrant() throws {
        let list = protectedList()
        let c = try protectedController(list)
        XCTAssertTrue(c.activeBlocks.isEmpty, "The protected program is scheduled for later.")
        var asked = 0
        c.askStop = { _ in asked += 1; return false }
        var weaker = list
        weaker.sites = []
        let hash = try GoalongBlockingConfiguration.fingerprint(list)
        assertError(.locked) { _ = try put(weaker, match: hash, to: c) }
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(c.list(list.id), list)

        XCTAssertNil(c.stopGrant.pass(.password, proof: .password("fixture")))
        XCTAssertTrue(c.stopGrant.covers(.password))
        assertError(.locked) { _ = try put(weaker, match: hash, to: c) }
        XCTAssertEqual(asked, 0, "The remote path must never open an authentication dialog.")
        XCTAssertEqual(c.list(list.id), list, "An unrelated native grant cannot authorize an agent write.")

        var stronger = list
        stronger.sites.append(.init(pattern: "games.example"))
        stronger.program.ranges[0].pause?.budgetMinutes = 5
        stronger.program.ranges.append(.init(weekdays: Set(1...7), startMinute: 1080, endMinute: 1140, lock: .free))
        _ = try put(stronger, match: hash, to: c)
        XCTAssertEqual(c.list(list.id)?.sites.count, 2)
        XCTAssertEqual(c.list(list.id)?.program.ranges.first?.pause?.budgetMinutes, 5)
        XCTAssertEqual(c.list(list.id)?.program.ranges.count, 2)
        XCTAssertEqual(asked, 0)
    }

    func testProtectedRangeIdentityAndGeometryCannotHideAnExpandedPause() throws {
        let list = protectedList()
        let c = try protectedController(list)
        var asked = 0
        c.askStop = { _ in asked += 1; return false }
        let hash = try GoalongBlockingConfiguration.fingerprint(list)
        let originalRange = list.program.ranges[0]

        var replacement = list
        replacement.program.ranges[0].id = UUID()
        replacement.program.ranges[0].pause?.budgetMinutes = 30
        assertError(.locked) { _ = try put(replacement, match: hash, to: c) }

        var displaced = list
        displaced.program.ranges[0].startMinute = 1320
        var duplicate = originalRange
        duplicate.id = UUID()
        duplicate.pause?.budgetMinutes = 30
        displaced.program.ranges.append(duplicate)
        assertError(.locked) { _ = try put(displaced, match: hash, to: c) }
        XCTAssertEqual(c.list(list.id), list)
        XCTAssertEqual(asked, 0)
    }

    func testActiveLocksRefuseWeakeningAndAllowAdditionalTargetsWithoutChangingTheSession() throws {
        for lock in [BlockLock.locked, .password] {
            let list = BlockList(name: "Sites", sites: [.init(pattern: "video.example")])
            let c = try protectedController(list)
            var asked = 0
            c.askStop = { _ in asked += 1; return false }
            c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: lock)
            let blocks = c.activeBlocks
            XCTAssertFalse(blocks.isEmpty)
            XCTAssertTrue(c.isStricterOnly(list.id))
            let hash = try GoalongBlockingConfiguration.fingerprint(list)
            var weaker = list
            weaker.sites = []
            assertError(.locked) { _ = try put(weaker, match: hash, to: c) }
            XCTAssertEqual(c.list(list.id), list)

            var stronger = list
            stronger.sites.append(.init(pattern: "games.example"))
            let result = try put(stronger, match: hash, to: c)
            XCTAssertEqual(result["locked"] as? Bool, true)
            XCTAssertEqual(c.list(list.id)?.sites.count, 2)
            XCTAssertEqual(c.activeBlocks, blocks)
            XCTAssertEqual(asked, 0)
        }
    }
}
#endif
