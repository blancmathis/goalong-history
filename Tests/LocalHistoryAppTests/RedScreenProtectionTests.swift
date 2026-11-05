#if os(macOS)
import BraiseCore
import Foundation
import GoalongGuardCore
import ServiceManagement
import XCTest
@testable import LocalHistoryApp

/// T-048 B5: one « protégé » predicate (a severe block or a protected red-screen range) for the guard's arming,
/// « Quitter » and SIGTERM, and the guard's consent for the ranges. Fake gamma, fake guard client, fake BTM service:
/// no colour change, no SMAppService, no launchd, no signal sent, no process started or killed.
@MainActor final class RedScreenProtectionTests: XCTestCase {
    private final class FakeGuardClient: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var consent: Bool
        var canRemove = true
        private(set) var updates: [Date?] = []
        init(consent: Bool) { self.consent = consent }
        var needsConsent: Bool { !consent }
        var hasConsent: Bool { consent }
        func recordConsent() { consent = true }
        func update(severeUntil: Date?) -> BlockingProtectionState.Component {
            updates.append(severeUntil); return severeUntil == nil ? .notInstalled : .running
        }
        func removeService() {}
    }
    private final class FakeService: GuardServiceControlling, @unchecked Sendable {
        var status: SMAppService.Status = .enabled
        func register() throws {}
        func unregister() throws { status = .notRegistered }
    }
    private final class Clocks {
        var now: Date; var up: TimeInterval = 1_000
        init(_ now: Date) { self.now = now }
        func pass(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds); up += seconds }
    }
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 22:00 in Paris.
    private let wednesday22h = ISO8601DateFormatter().date(from: "2026-11-04T21:00:00Z")!
    private var rangeEnd: Date { wednesday22h.addingTimeInterval(3_600) }

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-red-protection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func defaults() throws -> UserDefaults {
        let name = "goalong-red-protection-" + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }; return value
    }
    private func blocking(_ clocks: Clocks, root: URL, client: FakeGuardClient?, document: BlockingDocument = BlockingDocument(),
                          redScreen: RedScreenGuardDemand = .until(nil), marker: Date? = nil) throws -> (BlockingController, GuardFiles) {
        let store = BlockingStore(directory: root.appendingPathComponent("Blocking", isDirectory: true))
        try store.save(document)
        if let marker { XCTAssertTrue(GoalongGuardFiles.files(for: store.directory).writeMarker(until: marker)) }
        let c = BlockingController(document: document, clock: { clocks.now }, store: store, continuous: { clocks.up },
                                   boot: { "boot-1" }, guardClient: client, redScreen: redScreen)
        c.refresh()
        return (c, GoalongGuardFiles.files(for: store.directory))
    }
    /// Wednesday (ISO 3) 21:00–23:00.
    private func evening(_ lock: BlockLock?) -> BlockProgramRange {
        BlockProgramRange(weekdays: [3], startMinute: 21 * 60, endMinute: 23 * 60, lock: lock)
    }

    // MARK: Consent

    /// The text names both cases and its version went up: a member who accepted the old text reads it once more.
    func testConsentTextNamesBlocksAndProtectedRanges() throws {
        XCTAssertTrue(GuardConsent.text.contains("blocages"))
        XCTAssertTrue(GuardConsent.text.contains("plages d’écran rouge protégées"))
        XCTAssertEqual(GuardConsent.version, 2)
        let defaults = try defaults()
        XCTAssertFalse(GuardConsent.isGiven(defaults))
        defaults.set(1, forKey: GuardConsent.versionKey)
        XCTAssertFalse(GuardConsent.isGiven(defaults), "consent to the old text does not cover the ranges")
        GuardConsent.record(defaults)
        XCTAssertTrue(GuardConsent.isGiven(defaults))
        XCTAssertTrue(RedScreenRangeEditor.showsConsent(lock: .locked, needed: true))
        XCTAssertTrue(RedScreenRangeEditor.showsConsent(lock: .typing, needed: true))
        XCTAssertFalse(RedScreenRangeEditor.showsConsent(lock: .free, needed: true), "a free range arms nothing")
        XCTAssertFalse(RedScreenRangeEditor.showsConsent(lock: .password, needed: false))
    }

    /// The real client (fake BTM service): registered under the old text → asked once more; accepted → given;
    /// the member removes the service → asked again, and no range brings it back before that.
    func testClientAsksTheNewConsentOnceAndForgetsItOnRemoval() throws {
        let defaults = try defaults(), service = FakeService()
        defaults.set("old-build", forKey: GoalongGuardClient.registeredBuildKey)
        let identity = try XCTUnwrap(GuardIdentity(bundleIdentifier: "ai.goalong.localhistory.dev", channel: "dev"))
        let client = GoalongGuardClient(identity: identity, defaults: defaults, overrideActive: { false }, service: service)
        XCTAssertTrue(client.needsConsent, "registered under version 1: the new text is shown once")
        XCTAssertFalse(client.hasConsent)
        client.recordConsent()
        XCTAssertFalse(client.needsConsent); XCTAssertTrue(client.hasConsent)
        for _ in 0..<200 where client.isWorking { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } // wall: lets the BTM queue answer
        XCTAssertFalse(client.isWorking)
        client.removeService()
        for _ in 0..<200 where client.isWorking { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } // wall: lets the BTM queue answer
        XCTAssertFalse(client.hasConsent, "removed: a range does not register it again silently")
        XCTAssertTrue(client.needsConsent)
    }

    /// Without consent a protected range runs without the guard (no marker, client disarmed); a locked block still
    /// arms it as before. The consent given, the range in progress arms it at once.
    func testProtectedRangeArmsTheGuardOnlyWithConsent() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient(consent: false)
        let (blocks, files) = try blocking(clocks, root: root, client: client)
        let runtime = BlockingRuntime(controller: blocks, redScreenKeeper: { XCTFail("module on: no keeper"); return nil })
        runtime.setRedScreenGuard(until: rangeEnd, lock: .locked)
        XCTAssertEqual(blocks.protectedUntil, rangeEnd, "still protected: Quitter and SIGTERM hold")
        XCTAssertNil(blocks.guardUntil)
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent)
        XCTAssertEqual(client.updates.last, .some(nil))
        XCTAssertTrue(blocks.guardNeedsConsent)

        runtime.recordGuardConsent()
        XCTAssertTrue(client.consent)
        XCTAssertEqual(blocks.guardUntil, rangeEnd)
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(rangeEnd))
        XCTAssertEqual(client.updates.last, .some(rangeEnd))

        // A block without consent: unchanged, it arms the guard (its confirmation showed the text).
        let other = FakeGuardClient(consent: false), clocks2 = Clocks(wednesday22h)
        let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        let document = BlockingDocument(lists: [list])
        let (locked, lockedFiles) = try blocking(clocks2, root: try self.root(), client: other, document: document)
        locked.start(listIDs: [list.id], until: rangeEnd, lock: .locked)
        XCTAssertEqual(locked.severeUntil, rangeEnd)
        XCTAssertEqual(lockedFiles.readMarker(now: clocks2.now), .date(rangeEnd))
        XCTAssertEqual(other.updates.last, .some(rangeEnd))
    }

    /// Module Blocage off: the keeper follows the same rule.
    func testKeeperArmsNothingWithoutConsent() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient(consent: false)
        let files = GoalongGuardFiles.files(for: root.appendingPathComponent("Blocking", isDirectory: true))
        let runtime = BlockingRuntime(controller: nil, redScreenKeeper: { RedScreenGuardKeeper(client: client, files: files, clock: { clocks.now }) })
        runtime.setRedScreenGuard(until: rangeEnd, lock: .typing)
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent)
        XCTAssertEqual(client.updates.last, .some(nil))
        XCTAssertTrue(runtime.guardNeedsConsent)
        XCTAssertEqual(runtime.protectedUntil(now: clocks.now), rangeEnd, "protected even without the guard")
        runtime.recordGuardConsent()
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(rangeEnd))
        XCTAssertEqual(client.updates.last, .some(rangeEnd))
    }

    // MARK: « Quitter »

    /// The rule, pure: the same answer for a block and for a range of the same strength.
    func testQuitRuleIsTheSameForBlocksAndRanges() {
        typealias P = GoalongProtection
        XCTAssertEqual(P.quit(blocksLocked: false, blocksPassword: false, redScreenLock: nil), .allowed)
        XCTAssertEqual(P.quit(blocksLocked: false, blocksPassword: false, redScreenLock: .free), .allowed)
        XCTAssertEqual(P.quit(blocksLocked: true, blocksPassword: false, redScreenLock: nil), .locked(redScreen: false))
        XCTAssertEqual(P.quit(blocksLocked: false, blocksPassword: false, redScreenLock: .locked), .locked(redScreen: true))
        XCTAssertEqual(P.quit(blocksLocked: false, blocksPassword: true, redScreenLock: nil), .password)
        XCTAssertEqual(P.quit(blocksLocked: false, blocksPassword: false, redScreenLock: .password), .password)
        XCTAssertEqual(P.quit(blocksLocked: false, blocksPassword: false, redScreenLock: .typing), .redScreenPage)
        XCTAssertEqual(P.quit(blocksLocked: false, blocksPassword: true, redScreenLock: .typing), .redScreenPage)
        XCTAssertEqual(P.quit(blocksLocked: true, blocksPassword: true, redScreenLock: .typing), .locked(redScreen: false))
    }

    /// Through the live chain (red screen → runtime → controller): a locked range refuses « Quitter » like a locked
    /// block; a « Difficile » range sends to its page. Range over: « Quitter » is free again.
    func testQuitDuringALockedOrTypingRangeFollowsTheBlockRule() throws {
        for (lock, expected) in [(BlockLock.locked, GoalongProtection.Quit.locked(redScreen: true)), (.typing, .redScreenPage)] {
            let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient(consent: true)
            let (blocks, _) = try blocking(clocks, root: root, client: client)
            let runtime = BlockingRuntime(controller: blocks, redScreenKeeper: { nil })
            let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
            let red = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: { clocks.now }, calendar: paris,
                                           continuous: { clocks.up }, boot: { "boot-1" }, hasPassword: { false })
            addTeardownBlock { @MainActor in red.shutdown() }
            for range in red.ranges.program.ranges { try red.deleteRange(range.id) }
            let braise = BraiseRuntime(registersShortcut: false, defaults: try defaults(), factory: { red })
            braise.guardSink = { runtime.setRedScreenGuard(until: $0, lock: $1) }
            braise.start()
            XCTAssertEqual(runtime.quitRule(now: clocks.now), .allowed, "\(lock)")
            try red.saveRange(evening(lock), intensity: 0.8)
            braise.setRedScreenFollowsSchedule(true)
            XCTAssertEqual(runtime.redScreen, .until(rangeEnd, lock: lock))
            XCTAssertEqual(runtime.quitRule(now: clocks.now), expected, "\(lock)")
            XCTAssertTrue(blocks.quitIsLocked, "\(lock)")
            XCTAssertFalse(blocks.quitRequiresPassword)
            XCTAssertFalse(blocks.consumeQuitAuthorization(), "no quit token while the range holds")
            clocks.pass(3_601); red.evaluate()
            XCTAssertEqual(runtime.quitRule(now: clocks.now), .allowed, "\(lock): range over")
            XCTAssertFalse(blocks.quitIsLocked)
        }
    }

    /// A « Mot de passe » range asks the blocking password like a password block: wrong refuses, right approves once.
    func testQuitDuringAPasswordRangeAsksTheBlockingPassword() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient(consent: true)
        let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: clocks.now))
        let (blocks, _) = try blocking(clocks, root: root, client: client, document: BlockingDocument(passwordLock: credential))
        let runtime = BlockingRuntime(controller: blocks, redScreenKeeper: { nil })
        XCTAssertFalse(blocks.quitRequiresPassword)
        runtime.setRedScreenGuard(until: rangeEnd, lock: .password)
        XCTAssertEqual(runtime.quitRule(now: clocks.now), .password)
        XCTAssertTrue(blocks.quitRequiresPassword); XCTAssertFalse(blocks.quitIsLocked)
        XCTAssertFalse(blocks.consumeQuitAuthorization())
        XCTAssertNotEqual(blocks.authorizeQuit(password: "wrong"), .ok)
        XCTAssertFalse(blocks.consumeQuitAuthorization())
        XCTAssertEqual(blocks.authorizeQuit(password: "fixture"), .ok)
        XCTAssertTrue(blocks.consumeQuitAuthorization()); XCTAssertFalse(blocks.consumeQuitAuthorization(), "one quit only")
    }

    /// Module Blocage off: no password to check, so every protected range is stopped on its page (locked: refused).
    func testQuitWithTheBlockingModuleOff() {
        let now = wednesday22h
        let runtime = BlockingRuntime(controller: nil, redScreenKeeper: { nil })
        XCTAssertEqual(runtime.quitRule(now: now), .allowed, "launch, before the red screen reports, no marker left")
        runtime.setRedScreenGuard(until: rangeEnd, lock: .locked)
        XCTAssertEqual(runtime.quitRule(now: now), .locked(redScreen: true))
        runtime.setRedScreenGuard(until: rangeEnd, lock: .password)
        XCTAssertEqual(runtime.quitRule(now: now), .locked(redScreen: true), "no password without the module: « Verrouillé », like its window")
        runtime.setRedScreenGuard(until: rangeEnd, lock: .typing)
        XCTAssertEqual(runtime.quitRule(now: now), .redScreenPage)
        XCTAssertEqual(runtime.quitRule(now: rangeEnd.addingTimeInterval(1)), .allowed, "range over")
        runtime.setRedScreenGuard(until: nil, lock: .free)
        XCTAssertEqual(runtime.quitRule(now: now), .allowed)
    }

    // MARK: SIGTERM

    /// SIGTERM reads the same predicate: ignored during a protected range (consent or not, module on or off), honoured
    /// at a session end, from launchd or with the installer override, and once the range is over.
    func testSigtermDuringAProtectedRangeFollowsTheBlockRule() throws {
        let clocks = Clocks(Date()) // wall: the SIGTERM path reads the runtime's wall clock
        let end = clocks.now.addingTimeInterval(3_600)
        let (blocks, _) = try blocking(clocks, root: try root(), client: FakeGuardClient(consent: false))
        let on = BlockingRuntime(controller: blocks, redScreenKeeper: { nil })
        let off = BlockingRuntime(controller: nil, redScreenKeeper: { nil })
        for runtime in [on, off] {
            XCTAssertTrue(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: 4242, installOverride: false))
            runtime.setRedScreenGuard(until: end, lock: .typing)
            XCTAssertNotNil(runtime.protectedUntil())
            XCTAssertFalse(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: 4242, installOverride: false))
            XCTAssertTrue(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: true, senderPID: 4242, installOverride: false))
            XCTAssertTrue(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: 1, installOverride: false))
            XCTAssertTrue(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: 4242, installOverride: true))
            runtime.setRedScreenGuard(until: nil, lock: .free)
            XCTAssertTrue(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: 4242, installOverride: false))
        }
        // Time passes the end, module off (no report of the end): SIGTERM is honoured again.
        off.setRedScreenGuard(until: end, lock: .locked)
        XCTAssertEqual(off.protectedUntil(now: end.addingTimeInterval(-1)), end)
        XCTAssertNil(off.protectedUntil(now: end.addingTimeInterval(1)), "range over by the clock")
        XCTAssertNil(blocks.guardUntil, "no consent: the predicate holds, the guard stays off")
    }

    // MARK: T-048 B6

    /// Module off: Concentration's lock message reads the runtime, and « Verrouiller » records a consent only where
    /// that message showed `GuardConsent.text`.
    func testLockConfirmationRecordsTheConsentOnlyWhereItsTextIsShown() throws {
        let defaults = try defaults()
        let runtime = BlockingRuntime(controller: nil, redScreenKeeper: { nil })
        runtime.consentDefaults = defaults
        runtime.guardAllowed = { false }
        XCTAssertFalse(FocusComposer.lockMessage(runtime).contains(GuardConsent.text))
        runtime.recordGuardConsent()
        XCTAssertFalse(GuardConsent.isGiven(defaults), "text not shown: nothing recorded")
        runtime.guardAllowed = { true }
        XCTAssertTrue(FocusComposer.lockMessage(runtime).contains(GuardConsent.text), "module off: shown from the runtime's state")
        runtime.recordGuardConsent()
        XCTAssertTrue(GuardConsent.isGiven(defaults))
    }

    /// Module off, first report of the red screen (no range): a `guard-until` an earlier process left is removed and
    /// the client disarmed, as a controller does.
    func testFirstReportWithTheModuleOffClearsAStaleMarker() throws {
        let clocks = Clocks(wednesday22h), client = FakeGuardClient(consent: true)
        let files = GoalongGuardFiles.files(for: try root().appendingPathComponent("Blocking", isDirectory: true))
        XCTAssertTrue(files.writeMarker(until: wednesday22h.addingTimeInterval(-60)))
        var made = 0
        let runtime = BlockingRuntime(controller: nil, redScreenKeeper: {
            made += 1; return RedScreenGuardKeeper(client: client, files: files, clock: { clocks.now })
        })
        runtime.guardAllowed = { true }; runtime.testGuardFiles = files
        XCTAssertNil(runtime.protectedUntil(now: clocks.now), "a past marker protects nothing")
        runtime.setRedScreenGuard(until: nil, lock: .free)
        XCTAssertEqual(made, 1)
        XCTAssertFalse(files.markerExists())
        XCTAssertEqual(client.updates, [nil])
        runtime.setRedScreenGuard(until: nil, lock: .locked)
        XCTAssertEqual(client.updates, [nil, nil], "the keeper stays: nil again, nothing armed")

        // No marker left: no keeper, no BTM call.
        let quiet = BlockingRuntime(controller: nil, redScreenKeeper: { XCTFail("nothing to put right"); return nil })
        quiet.guardAllowed = { true }; quiet.testGuardFiles = files
        quiet.setRedScreenGuard(until: nil, lock: .free)
    }

    /// Launch, before the red screen reports: a future marker its range left holds « Quitter » and SIGTERM, module
    /// Blocage on or off, by one rule (`GoalongProtection.kept`).
    func testLaunchMarkerHoldsQuitAndSigtermInBothModes() throws {
        let clocks = Clocks(Date()) // wall: the SIGTERM path reads the runtime's wall clock
        let kept = Date(timeIntervalSince1970: clocks.now.addingTimeInterval(3_600).timeIntervalSince1970.rounded(.up))
        let (blocks, _) = try blocking(clocks, root: try root(), client: FakeGuardClient(consent: true), redScreen: .unknown, marker: kept)
        let on = BlockingRuntime(controller: blocks, redScreenKeeper: { nil })
        let files = GoalongGuardFiles.files(for: try root().appendingPathComponent("Blocking", isDirectory: true))
        XCTAssertTrue(files.writeMarker(until: kept))
        let off = BlockingRuntime(controller: nil, redScreenKeeper: { nil })
        off.guardAllowed = { true }; off.testGuardFiles = files
        for runtime in [on, off] {
            XCTAssertEqual(runtime.protectedUntil()?.timeIntervalSince1970 ?? 0, kept.timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(runtime.quitRule(), .locked(redScreen: true))
            XCTAssertEqual(AppDelegate.quitPrompt(runtime: runtime), .locked(redScreen: true))
            XCTAssertFalse(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: 4242, installOverride: false))
            runtime.setRedScreenGuard(until: nil, lock: .free)
            XCTAssertNil(runtime.protectedUntil(), "the red screen reported: its word wins")
            XCTAssertEqual(runtime.quitRule(), .allowed)
        }
        XCTAssertEqual(GoalongProtection.kept(.date(kept), now: clocks.now, severe: kept.addingTimeInterval(-0.5)), nil,
                       "a block's own marker (rounded up) is not a range")
        XCTAssertEqual(GoalongProtection.kept(.invalid, now: clocks.now, severe: nil), nil)
    }

    /// Switching the module off during a protected range: the controller's client goes on to the keeper (one client).
    func testSwitchingTheModuleOffDuringARangeKeepsOneClient() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient(consent: true)
        let (blocks, files) = try blocking(clocks, root: root, client: client)
        var handed: [ObjectIdentifier] = []
        let runtime = BlockingRuntime(controller: blocks, redScreenKeeper: { XCTFail("no second client"); return nil }, handOver: { given in
            handed.append(ObjectIdentifier(given as AnyObject))
            return RedScreenGuardKeeper(client: given, files: files, clock: { clocks.now })
        })
        runtime.setRedScreenGuard(until: rangeEnd, lock: .locked)
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(rangeEnd))
        runtime.apply(enabled: false)
        XCTAssertNil(runtime.controller)
        XCTAssertEqual(handed, [ObjectIdentifier(client)])
        XCTAssertTrue(runtime.redScreenKeeper?.client === client)
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(rangeEnd))
        XCTAssertEqual(client.updates.last, .some(rangeEnd))
    }

    /// « Quitter », module off, locked range: the alert, not a free quit (`quitPrompt` is what the app delegate shows).
    func testQuitPromptWithTheModuleOffAndALockedRange() {
        let runtime = BlockingRuntime(controller: nil, redScreenKeeper: { nil })
        let end = Date().addingTimeInterval(3_600) // wall: `quitPrompt` reads the runtime's wall clock
        XCTAssertEqual(AppDelegate.quitPrompt(runtime: runtime), .quit)
        runtime.setRedScreenGuard(until: end, lock: .locked)
        XCTAssertEqual(AppDelegate.quitPrompt(runtime: runtime), .locked(redScreen: true))
        runtime.setRedScreenGuard(until: end, lock: .typing)
        XCTAssertEqual(AppDelegate.quitPrompt(runtime: runtime), .redScreenPage)
        runtime.setRedScreenGuard(until: end, lock: .password)
        XCTAssertEqual(AppDelegate.quitPrompt(runtime: runtime), .locked(redScreen: true))
    }

    /// The keeper's own timer ends the range: marker removed and client disarmed, without a new report.
    func testKeeperTimerEndsTheRange() throws {
        let client = FakeGuardClient(consent: true)
        let files = GoalongGuardFiles.files(for: try root().appendingPathComponent("Blocking", isDirectory: true))
        let keeper = RedScreenGuardKeeper(client: client, files: files, runsTimers: true)
        let end = Date().addingTimeInterval(1.2) // wall: the keeper's timer runs on the wall clock
        keeper.update(until: end)
        XCTAssertTrue(files.markerExists())
        XCTAssertNotNil(client.updates.last ?? nil)
        for _ in 0..<300 where files.markerExists() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } // wall: lets the timer fire
        XCTAssertFalse(files.markerExists(), "range over: marker removed")
        XCTAssertEqual(client.updates.last, .some(nil), "client disarmed")
    }
}
#endif
