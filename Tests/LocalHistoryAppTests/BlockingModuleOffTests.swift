#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-044 r8 C8-04: switching the Blocage module off stopped a running « Difficile » block without its typed
/// text. Any started block or program window other than « Libre » now refuses it, as a lock does; the
/// typed text ends the block and reopens the switch. Witness: a « Libre » block lets the module go.
@MainActor final class BlockingModuleOffTests: XCTestCase {
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    /// 2026-10-05 is a Monday.
    private func date(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: hour))! }
    private func modules() -> GoalongModuleStore {
        let name = "blocking-module-off-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let modules = GoalongModuleStore(defaults: defaults); modules.setEnabled(.blocking, true)
        return modules
    }

    func testDifficileBlockRefusesModuleOffUntilTyped() {
        for lock in [BlockLock.free, .typing] {
            let now = date(10)
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar,
                                       continuous: { now.timeIntervalSince1970 })
            let modules = modules(), runtime = BlockingRuntime(controller: c); runtime.start(modules: modules)
            c.start(listIDs: [list.id], until: date(12), lock: lock)
            let id = c.activeBlocks[0].id
            modules.setEnabled(.blocking, false)
            if lock == .free {
                XCTAssertFalse(modules.isEnabled(.blocking)); XCTAssertNil(runtime.controller)
                continue
            }
            XCTAssertTrue(modules.isEnabled(.blocking), "Difficile: module switched off"); XCTAssertTrue(runtime.controller === c)
            XCTAssertEqual(c.activeBlocks.first?.lock, .typing)
            XCTAssertNotNil(c.moduleOffRefusal); XCTAssertEqual(c.error, c.moduleOffRefusal)
            runtime.apply(enabled: false)
            XCTAssertTrue(runtime.controller === c, "Difficile: runtime stopped")
            c.stop(id, typed: c.typingChallenge(for: id)); XCTAssertTrue(c.activeBlocks.isEmpty)
            XCTAssertNil(c.moduleOffRefusal)
            modules.setEnabled(.blocking, false)
            XCTAssertFalse(modules.isEnabled(.blocking)); XCTAssertNil(runtime.controller)
        }
    }

    func testDifficileProgramWindowRefusesModuleOff() {
        for lock in [BlockLock.free, .typing] {
            let now = date(10)
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 1_020, lock: lock)])
            let c = BlockingController(document: BlockingDocument(lists: [l]), clock: { now }, calendar: calendar,
                                       continuous: { now.timeIntervalSince1970 })
            XCTAssertEqual(c.activeBlocks.first?.lock, lock)
            let modules = modules(), runtime = BlockingRuntime(controller: c); runtime.start(modules: modules)
            modules.setEnabled(.blocking, false)
            XCTAssertEqual(modules.isEnabled(.blocking), lock != .free, "\(lock)")
        }
    }
}
#endif
