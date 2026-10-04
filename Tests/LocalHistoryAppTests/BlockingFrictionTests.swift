#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class BlockingFrictionTests: XCTestCase {
    private func target(_ at: Date, browser: Bool = true, url: String = "example.org/a") -> BlockingObservation {
        .init(bundleIdentifier: browser ? "browser" : "editor", pid: 42001, windowFrame: nil, isBrowser: browser, url: browser ? url : nil, privateWindow: false, at: at)
    }
    @MainActor func testLegacyJSONDefaultsAndAdditiveBounds() throws {
        let old = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Ancien\",\"mode\":\"block\",\"sites\":[],\"apps\":[],\"program\":{\"ranges\":[]}}".utf8)
        let list = try JSONDecoder().decode(BlockList.self, from: old)
        XCTAssertEqual(list.effectiveAction, .block); XCTAssertEqual(list.delaySeconds, 10); XCTAssertEqual(list.allowanceMinutes, 10)
        var next = list; next.action = .slowDown; next.slowDownSeconds = 2
        XCTAssertFalse(BlockingRules.validate(BlockingDocument(lists: [next])))
        let usage = try JSONDecoder().decode(BlockDayUsage.self, from: Data("{\"day\":\"2026-10-04\",\"quotaSecondsUsed\":[],\"breaksTaken\":[],\"breakEnds\":[]}".utf8))
        XCTAssertNil(usage.slowDownShown)
    }
    @MainActor func testDelayRenounceCountAndHostAllowanceExpiry() {
        var now = Date(); let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")], action: .slowDown, slowDownSeconds: 3, continueMinutes: 1)
        let backend = FrictionBackend(), c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        c.observe(target(now)); XCTAssertNotNil(c.friction); XCTAssertEqual(c.frictionUsage?.slowDownShown?[list.id], 1)
        c.observe(target(now)); XCTAssertEqual(c.frictionUsage?.slowDownShown?[list.id], 1)
        c.continueFriction(); XCTAssertNotNil(c.friction); XCTAssertEqual(backend.continues, 0)
        now = now.addingTimeInterval(3); c.continueFriction(); XCTAssertNil(c.friction); XCTAssertEqual(backend.continues, 1)
        c.observe(target(now, url: "example.org/other")); XCTAssertNil(c.friction)
        now = now.addingTimeInterval(61); c.observe(target(now)); XCTAssertEqual(c.frictionUsage?.slowDownShown?[list.id], 2)
        c.renounceFriction(); XCTAssertEqual(c.frictionUsage?.renounced?[list.id], 1); XCTAssertEqual(backend.renounces, 1)
        XCTAssertEqual(c.frictionUsage?.continued?[list.id], 1)
    }
    @MainActor func testHardBlockAlwaysWinsAndPrivacyFailsClosed() {
        let now = Date(); let slow = BlockList(name: "Slow", sites: [.init(pattern: "example.org")], action: .slowDown)
        let hard = BlockList(name: "Hard", sites: [.init(pattern: "example.org")])
        let backend = FrictionBackend(), c = BlockingController(document: .init(lists: [slow, hard]), clock: { now }, backend: backend)
        c.start(listIDs: [slow.id, hard.id], until: now.addingTimeInterval(600), lock: .free)
        c.observe(target(now)); XCTAssertNil(c.friction); XCTAssertEqual(backend.blocks, 1)
        let only = BlockingController(document: .init(lists: [slow]), clock: { now }, backend: backend)
        only.start(listIDs: [slow.id], until: now.addingTimeInterval(600), lock: .free)
        var privateTarget = target(now); privateTarget.privateWindow = true; only.observe(privateTarget)
        XCTAssertNil(only.friction); XCTAssertEqual(backend.blocks, 2)
    }
    @MainActor func testSlowDownLockStrictnessAndFreeze() {
        let now = Date(); var list = BlockList(name: "Slow", sites: [.init(pattern: "example.org")], action: .slowDown)
        list.program.lockedUntil = now.addingTimeInterval(600)
        let c = BlockingController(document: .init(lists: [list]), clock: { now })
        var next = list; next.slowDownSeconds = 3; XCTAssertNotEqual(c.editCheck(next), .allowed)
        next = list; next.continueMinutes = 20; XCTAssertNotEqual(c.editCheck(next), .allowed)
        next = list; next.action = .block; XCTAssertEqual(c.editCheck(next), .allowed)
        let backend = FrictionBackend(), freeze = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend)
        freeze.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        freeze.startFreeze(until: now.addingTimeInterval(600), mode: .shield, allowedApps: [])
        freeze.observe(target(now)); XCTAssertNil(freeze.friction); XCTAssertEqual(backend.shields, 1)
    }
    @MainActor func testAppRenounceRequiresNewActivationAndCountsSurviveMidnight() {
        var now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86399)
        let list = BlockList(name: "Apps", apps: [.init(bundleIdentifier: "editor", name: "Editor")], action: .slowDown)
        let backend = FrictionBackend(), c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        let day = BlockingController.dayKey(now)
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        c.observe(target(now, browser: false)); c.renounceFriction(); c.observe(target(now, browser: false)); XCTAssertNil(c.friction)
        var launched = target(now, browser: false); launched.isActivation = true; c.observe(launched); XCTAssertNotNil(c.friction)
        now = now.addingTimeInterval(2); c.refresh(enforceLast: false)
        XCTAssertEqual(c.frictionCounts(day: day).renounced?[list.id], 1)
    }
    @MainActor func testQuotaLeftSlowsAndExhaustionBlocksBreakAllows() {
        var now = Date(); let list = BlockList(name: "Slow", sites: [.init(pattern: "example.org")], quotaMinutesPerDay: 1, breaks: .init(count: 1, minutes: 1), action: .slowDown)
        let backend = FrictionBackend(), c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        c.observe(target(now)); XCTAssertNotNil(c.friction)
        for _ in 0..<4 { now = now.addingTimeInterval(15); c.observe(target(now)) }
        XCTAssertNil(c.friction); XCTAssertGreaterThan(backend.blocks, 0)
        c.takeBreak(listID: list.id); c.observe(target(now)); XCTAssertNil(c.friction)
        let app = BlockList(name: "Apps", apps: [.init(bundleIdentifier: "editor", name: "Editor")], quotaMinutesPerDay: 1, action: .slowDown)
        var usage = BlockDayUsage(day: BlockingController.dayKey(now)); usage.quotaSecondsUsed[app.id] = 60
        let appController = BlockingController(document: .init(lists: [app], usage: usage), clock: { now }, backend: backend)
        appController.start(listIDs: [app.id], until: now.addingTimeInterval(600), lock: .free)
        let before = backend.blocks; appController.observe(target(now, browser: false))
        XCTAssertEqual(backend.blocks, before); XCTAssertEqual(backend.heldApps, 1)
    }
}
private final class FrictionBackend: BlockingEnforcementBackend {
    var accessibilityAvailable = true; var canLockScreen = false; var browsers: [BlockingBrowserSupport] = []
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    var blocks = 0, continues = 0, renounces = 0, shields = 0, heldApps = 0
    func observeBrowser(_ t: BlockingObservation) {}
    func updateProtection(locked: Bool) -> BlockingProtectionState { .init() }
    func blockApp(_ t: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) { blocks += 1 }
    func blockSlowDownApp(_ t: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) { heldApps += 1 }
    func blockSite(_ t: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) { blocks += 1 }
    func clearSite() {}; func updateFreeze(_ f: BlockFreeze?) {}; func returnToShield() { shields += 1 }; func shutdown() {}
    func slowDown(_ t: BlockingObservation, presentation: BlockingFrictionPresentation, onRenounce: @escaping () -> Void, onContinue: @escaping () -> Void) {}
    func clearSlowDown() {}; func renounceSlowDown(_ t: BlockingObservation) { renounces += 1 }; func continueSlowDown(_ t: BlockingObservation) { continues += 1 }
}
#endif
