#if os(macOS)
import AppKit
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class BlockingEngineTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: "Europe/Paris")!; return result
    }
    private func date(_ day: Int = 5, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func target(_ at: Date, url: String? = "https://youtube.com/shorts/x") -> BlockingObservation {
        BlockingObservation(bundleIdentifier: "com.google.Chrome", pid: 42000, windowFrame: CGRect(x: 1, y: 1, width: 800, height: 600),
                            isBrowser: true, url: url, privateWindow: false, at: at)
    }
    private func temporaryStore() throws -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("blocking-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }

    func testNormalizationAndIDN() {
        XCTAssertEqual(BlockingRules.normalize(" HTTPS://user:pass@WWW.YouTube.COM:443/SHORTS/?q=secret#x "), "youtube.com/shorts")
        XCTAssertEqual(BlockingRules.normalize("https://école.fr/"), "xn--cole-9oa.fr")
        for value in ["", "localhost", "127.0.0.1", "http://[::1]", "https://single", "https://bad..com", "https://-bad.com", "ftp://youtube.com", "youtube.com/a b"] {
            XCTAssertNil(BlockingRules.normalize(value), value)
        }
    }
    func testHostAndPathSegmentMatching() {
        let rule = BlockSiteRule(pattern: "youtube.com/shorts")
        for value in ["youtube.com/shorts", "m.youtube.com/shorts/x", "https://youtube.com/shorts?q=1"] { XCTAssertTrue(BlockingRules.matches(rule, url: value), value) }
        for value in ["youtube.com/shortsx", "notyoutube.com/shorts", "youtube.com.evil.org/shorts"] { XCTAssertFalse(BlockingRules.matches(rule, url: value), value) }
    }
    func testNeverBlockedInventoryAndNonRegular() {
        XCTAssertEqual(BlockingRules.neverBlocked, Set(["ai.goalong.localhistory", "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.SecurityAgent", "com.apple.coreautha", "com.apple.ScreenSaver.Engine"]))
        for id in BlockingRules.neverBlocked { var t = target(date()); t.bundleIdentifier = id; XCTAssertTrue(BlockingRules.exempt(t)) }
        var t = target(date()); t.regular = false; XCTAssertTrue(BlockingRules.exempt(t))
    }
    func testWebContentAppsAreAppsNotBrowsers() {
        XCTAssertTrue(BlockingRules.isKnownBrowser("org.mozilla.firefox", configured: []))
        XCTAssertTrue(BlockingRules.isKnownBrowser("com.apple.Safari", configured: ["com.apple.Safari"]))
        XCTAssertFalse(BlockingRules.isKnownBrowser("com.tinyspeck.slackmacgap", configured: ["com.apple.Safari"]))
        // An Electron app with no readable address is an app: allowOnly blocks it, a site list does not.
        let slack = BlockingObservation(bundleIdentifier: "com.tinyspeck.slackmacgap", pid: 42, windowFrame: nil,
                                        isBrowser: false, url: nil, privateWindow: false, at: Date())
        XCTAssertTrue(BlockingRules.wouldBlock(slack, list: BlockList(name: "Focus", mode: .allowOnly, sites: [BlockSiteRule(pattern: "notion.so")])))
        XCTAssertFalse(BlockingRules.wouldBlock(slack, list: BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])))
    }

    func testAllowOnlyBrowserInternalAndApps() {
        let list = BlockList(name: "Travail", mode: .allowOnly, sites: [BlockSiteRule(pattern: "example.com")], apps: [BlockAppRule(bundleIdentifier: "editor", name: "Éditeur")])
        XCTAssertFalse(BlockingRules.wouldBlock(target(date(), url: "example.com/docs"), list: list))
        XCTAssertTrue(BlockingRules.wouldBlock(target(date()), list: list))
        var t = target(date()); t.isInternalPage = true; t.url = "chrome://newtab"; XCTAssertFalse(BlockingRules.wouldBlock(t, list: list))
        t.isBrowser = false; t.isInternalPage = false; t.bundleIdentifier = "editor"; XCTAssertFalse(BlockingRules.wouldBlock(t, list: list))
        t.bundleIdentifier = "game"; XCTAssertTrue(BlockingRules.wouldBlock(t, list: list))
    }
    func testOvernightISOWeekdaysAndMergedRanges() {
        let range = BlockProgramRange(weekdays: [1], startMinute: 23 * 60, endMinute: 60)
        let program = BlockProgram(ranges: [range])
        XCTAssertNotNil(BlockingSchedule.currentWindow(of: program, at: date(6, 0, 30), calendar: calendar))
        XCTAssertNil(BlockingSchedule.currentWindow(of: program, at: date(5, 0, 30), calendar: calendar))
        XCTAssertEqual(BlockingSchedule.isoWeekday(date(4), calendar: calendar), 7)
        let touching = BlockProgramRange(weekdays: [2], startMinute: 60, endMinute: 120)
        XCTAssertEqual(BlockingSchedule.currentWindow(of: BlockProgram(ranges: [range, touching]), at: date(6, 0, 30), calendar: calendar)?.end, date(6, 2))
    }
    func testDSTUsesCivilMinutes() {
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 3, minute: 30))!
        let autumn = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 3, minute: 30))!
        let program = BlockProgram(ranges: [BlockProgramRange(weekdays: [7], startMinute: 60, endMinute: 240)])
        XCTAssertEqual(BlockingSchedule.currentWindow(of: program, at: spring, calendar: calendar)?.end.timeIntervalSince(BlockingSchedule.currentWindow(of: program, at: spring, calendar: calendar)!.start), 7200)
        XCTAssertEqual(BlockingSchedule.currentWindow(of: program, at: autumn, calendar: calendar)?.end.timeIntervalSince(BlockingSchedule.currentWindow(of: program, at: autumn, calendar: calendar)!.start), 14400)
    }
    func testStoreMissingAndRoundtripModes() throws {
        let store = try temporaryStore()
        XCTAssertEqual(try store.load(), BlockingDocument())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        let doc = BlockingDocument(lists: [BlockList(name: "Personnel")])
        try store.save(doc); XCTAssertEqual(try store.load(), doc)
        let dir = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let file = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("blocking.json").path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), ["blocking.json"])
    }
    func testStoreRejectsSymlinkAndUnknownVersion() throws {
        let store = try temporaryStore(); try store.save(BlockingDocument())
        let file = store.directory.appendingPathComponent("blocking.json")
        try Data("{\"version\":99,\"lists\":[],\"sessions\":[]}".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(BlockingDocument()))
    }
    func testStoreRejectsLinkedDirectoryAndSpecialFile() throws {
        let store = try temporaryStore()
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: store.directory.deletingLastPathComponent())
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(BlockingDocument()))
    }
    @MainActor func testOffRuntimeDoesNothing() throws {
        let name = "blocking-off-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let modules = GoalongModuleStore(defaults: defaults)
        let runtime = BlockingRuntime(); runtime.start(modules: modules)
        XCTAssertNil(runtime.controller)
        XCTAssertEqual(DashboardSection.sidebarSections(modules: modules.enabled), DashboardSection.primarySections)
        XCTAssertTrue(DashboardSection.sidebarSections(modules: [.blocking]).contains(.blocking))
        XCTAssertTrue(SettingsPane.primary.contains(.modules))
    }
    func testModuleDisableRefusalPreservesSwitch() {
        let name = "blocking-gate-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let modules = GoalongModuleStore(defaults: defaults)
        modules.setEnabled(.blocking, true); modules.blockingDisableCheck = { false }
        modules.setEnabled(.blocking, false)
        XCTAssertTrue(modules.isEnabled(.blocking)); XCTAssertTrue(defaults.bool(forKey: GoalongModule.blocking.defaultsKey))
    }

    @MainActor func testIdleControllerNoTimerOrFile() throws {
        let store = try temporaryStore()
        let c = BlockingController(store: store, runsTimers: true); defer { c.shutdown() }
        XCTAssertFalse(c.hasTimer); XCTAssertFalse(c.needsObservation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    @MainActor func testManualLocksAndTypingChallenge() {
        var now = date(); let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: .locked)
        let id = c.activeBlocks[0].id; c.stop(id); XCTAssertEqual(c.activeBlocks.count, 1); XCTAssertNotNil(c.error)
        now = now.addingTimeInterval(3601); c.refresh(); XCTAssertTrue(c.activeBlocks.isEmpty)
        c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: .typing)
        let typing = c.activeBlocks[0].id, challenge = c.typingChallenge(for: typing)
        XCTAssertEqual(challenge.count, 120); XCTAssertEqual(challenge, c.typingChallenge(for: typing))
        XCTAssertFalse(challenge.contains { "01IlOo".contains($0) })
        c.stop(typing, typed: "incorrect"); XCTAssertEqual(c.activeBlocks.count, 1)
        c.stop(typing, typed: challenge); XCTAssertTrue(c.activeBlocks.isEmpty)
    }
    @MainActor func testStricterOnlyMatrix() {
        let now = date(); var list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 20, breaks: BlockBreaks(count: 2, minutes: 5))
        list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900)], lockedUntil: now.addingTimeInterval(3600))
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        var next = list; next.sites.append(BlockSiteRule(pattern: "x.com")); next.quotaMinutesPerDay = 10; next.breaks = nil
        XCTAssertEqual(c.editCheck(next), .allowed)
        next = list; next.sites = []; XCTAssertNotEqual(c.editCheck(next), .allowed)
        next = list; next.quotaMinutesPerDay = 21; XCTAssertNotEqual(c.editCheck(next), .allowed)
        next = list; next.quotaMinutesPerDay = nil; XCTAssertEqual(c.editCheck(next), .allowed)
        next = list; next.breaks?.count = 3; XCTAssertNotEqual(c.editCheck(next), .allowed)
        next = list; next.program.lockedUntil = nil; XCTAssertNotEqual(c.editCheck(next), .allowed)
        next = list; next.program.ranges[0].endMinute = 899; XCTAssertNotEqual(c.editCheck(next), .allowed)
        c.delete(list.id); XCTAssertEqual(c.lists.count, 1)
    }
    @MainActor func testAllowOnlyReplacementCannotBroaden() {
        let now = date(); var list = BlockList(name: "Travail", mode: .allowOnly, sites: [BlockSiteRule(pattern: "example.com")])
        list.program.lockedUntil = now.addingTimeInterval(3600)
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now })
        var next = list; next.sites = [BlockSiteRule(pattern: "youtube.com")]; XCTAssertNotEqual(c.editCheck(next), .allowed)
        next.sites = []; XCTAssertEqual(c.editCheck(next), .allowed)
    }
    @MainActor func testQuotaMultipleListsAndIdle() {
        var now = date(); let backend = FakeBlockingBackend()
        let a = BlockList(name: "Quota", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 1)
        let b = BlockList(name: "Immédiat", sites: [BlockSiteRule(pattern: "x.com")])
        let c = BlockingController(document: BlockingDocument(lists: [a, b]), clock: { now }, backend: backend, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [a.id, b.id], until: now.addingTimeInterval(3600), lock: .free)
        c.observe(target(now)); XCTAssertEqual(backend.siteBlocks, 0)
        for _ in 0..<4 { now = now.addingTimeInterval(15); c.observe(target(now)) }
        XCTAssertEqual(c.snapshot.usage?.quotaSecondsUsed[a.id], 60); XCTAssertGreaterThan(backend.siteBlocks, 0)
        c.observe(target(now, url: "x.com")); XCTAssertGreaterThan(backend.siteBlocks, 1)
        var idle = target(now); idle.idleSeconds = 121; now = now.addingTimeInterval(15); idle.at = now; c.observe(idle)
        XCTAssertEqual(c.snapshot.usage?.quotaSecondsUsed[a.id], 60)
    }
    @MainActor func testBreaksLockedAndMidnightAndFreeze() {
        var now = date(5, 23, 59)
        let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")], breaks: BlockBreaks(count: 1, minutes: 5))
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(7200), lock: .locked)
        c.takeBreak(listID: list.id); XCTAssertEqual(c.snapshot.usage?.breaksTaken[list.id], 1)
        XCTAssertEqual(c.snapshot.usage?.breakEnds[list.id], date(6, 0))
        c.takeBreak(listID: list.id); XCTAssertEqual(c.snapshot.usage?.breaksTaken[list.id], 1)
        now = date(6, 0); c.refresh(); XCTAssertEqual(c.activeBlocks[0].breaksLeft[list.id], 1)
        c.startFreeze(until: now.addingTimeInterval(600), mode: .shield, allowedApps: [])
        c.takeBreak(listID: list.id); XCTAssertNotNil(c.error); XCTAssertNil(c.snapshot.usage?.breakEnds[list.id])
        let original = c.freeze; c.startFreeze(until: now.addingTimeInterval(300), mode: .shield, allowedApps: []); XCTAssertEqual(c.freeze, original)
    }
    @MainActor func testQuotaMidnightOnlyChargesNewDay() {
        var now = date(5, 23, 59).addingTimeInterval(55)
        let list = BlockList(name: "Quota", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 1)
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        c.observe(target(now)); now = now.addingTimeInterval(10); c.observe(target(now))
        XCTAssertEqual(c.snapshot.usage?.quotaSecondsUsed[list.id], 5)
        XCTAssertEqual(c.snapshot.usage?.day, "2026-10-06")
    }
    @MainActor func testPrivateAndUnsupportedBrowserFailClosed() {
        var now = date(); let backend = FakeBlockingBackend()
        let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 30)
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        var t = target(now, url: nil); t.privateWindow = true; c.observe(t); XCTAssertEqual(backend.lastReason, .privateWindow)
        t.privateWindow = false; c.observe(t); let count = backend.siteBlocks
        now = now.addingTimeInterval(3); t.at = now; c.observe(t); XCTAssertEqual(backend.siteBlocks, count + 1)
        backend.accessibilityAvailable = false; c.refresh(); XCTAssertFalse(c.siteBlockingAvailable)
        XCTAssertNil(c.snapshot.usage?.quotaSecondsUsed[list.id])
    }
    @MainActor func testClockJumpExtendsManualProgramAndFreeze() {
        var now = date(), uptime = 100.0
        var list = BlockList(name: "Programme", sites: [BlockSiteRule(pattern: "youtube.com")])
        list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 780)], lockedUntil: now.addingTimeInterval(7200))
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "boot" })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: .locked)
        c.startFreeze(until: now.addingTimeInterval(3600), mode: .shield, allowedApps: [])
        now = now.addingTimeInterval(7210); uptime += 10; c.refresh()
        XCTAssertEqual(c.snapshot.sessions[0].end, date().addingTimeInterval(10800))
        XCTAssertEqual(c.freeze?.end, date().addingTimeInterval(10800))
        XCTAssertTrue(c.activeBlocks.contains { if case .program = $0.origin { return true }; return false })
    }
    func testRebootBackwardsPreservesRemainingAndContinuousSleep() {
        let old = BlockingClockState(wall: date(), continuous: 100, boot: "old")
        XCTAssertEqual(BlockingClock.adjustment(previous: old, now: BlockingClockState(wall: date().addingTimeInterval(-3600), continuous: 1, boot: "new")), -3600)
        XCTAssertEqual(BlockingClock.adjustment(previous: old, now: BlockingClockState(wall: date().addingTimeInterval(7200), continuous: 7300, boot: "old")), 0)
    }
    @MainActor func testFileChangedUnderRunningGoalongIsRestoredAndMarkerFollowsLocks() throws {
        let store = try temporaryStore(), now = date(), list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        let doc = BlockingDocument(lists: [list], sessions: [BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(3600), lock: .locked)])
        try store.save(doc)
        var clockNow = now
        let c = BlockingController(clock: { clockNow }, store: store, continuous: { clockNow.timeIntervalSince1970 })
        let marker = store.directory.appendingPathComponent("locked-until")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "\(Int(now.timeIntervalSince1970) + 3600)\n")
        try Data("bad-json".utf8).write(to: store.directory.appendingPathComponent("blocking.json"))
        c.refresh(); XCTAssertTrue(c.hasLocks); XCTAssertEqual(c.activeBlocks.count, 1); XCTAssertNotNil(c.error)
        XCTAssertEqual(try store.load().sessions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("blocking.damaged.json").path))
        c.delete(list.id); XCTAssertEqual(c.lists.count, 1)
        clockNow = now.addingTimeInterval(3601); c.refresh()
        XCTAssertFalse(c.hasLocks); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    @MainActor func testDamagedStoreIsNeverALockAndAcceptsEdits() throws {
        let store = try temporaryStore(), now = date()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("bad-json".utf8).write(to: store.directory.appendingPathComponent("blocking.json"))
        let c = BlockingController(clock: { now }, store: store, continuous: { now.timeIntervalSince1970 })
        XCTAssertFalse(c.hasLocks); XCTAssertNotNil(c.error)
        c.startFreeze(until: now.addingTimeInterval(600), mode: .shield, allowedApps: [])
        XCTAssertTrue(c.hasLocks); XCTAssertNotNil(try store.load().freeze)
    }
    func testStoreKeepsPreviousGenerationAndRecovers() throws {
        let store = try temporaryStore(), directory = store.directory
        let first = BlockingDocument(lists: [BlockList(name: "Un")]), second = BlockingDocument(lists: [BlockList(name: "Deux")])
        try store.save(first); try store.save(second)
        XCTAssertEqual(try store.loadRecovering().recovery, .none)
        try Data("bad-json".utf8).write(to: directory.appendingPathComponent("blocking.json"))
        var loaded = try store.loadRecovering()
        XCTAssertEqual(loaded.recovery, .previous); XCTAssertEqual(loaded.document, first); XCTAssertEqual(try store.load(), first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("blocking.damaged.json")), Data("bad-json".utf8))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("blocking.json"))
        loaded = try store.loadRecovering(); XCTAssertEqual(loaded.recovery, .previous); XCTAssertEqual(loaded.document, first)
        for name in ["blocking.json", "blocking.previous.json"] { try Data("{}".utf8).write(to: directory.appendingPathComponent(name)) }
        loaded = try store.loadRecovering()
        XCTAssertEqual(loaded.recovery, .reset); XCTAssertEqual(loaded.document, BlockingDocument())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blocking.previous.damaged.json").path))
    }
    @MainActor func testUnlockedProgramStopAndLockedProgramRefusal() {
        let now = date(); var list = BlockList(name: "Programme", sites: [BlockSiteRule(pattern: "youtube.com")])
        list.program.ranges = [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900)]
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        let id = c.activeBlocks[0].id; c.stop(id); XCTAssertTrue(c.activeBlocks.isEmpty)
        let d = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        d.lockProgram(listID: list.id, until: now.addingTimeInterval(600)); d.stop(id); XCTAssertEqual(d.activeBlocks.count, 1)
    }
    @MainActor func testActualBlockingOnlySamplesRecordNothingAndRetainNothing() throws {
        let store = try temporaryStore(), root = store.directory.deletingLastPathComponent()
        let config = ConfigManager()
        let permissions = PermissionManager(statusProbe: { PermissionStatus(accessibility: false, inputMonitoring: false,
            accessibilityPreflight: false, accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: false,
            inputMonitoringProvidedByAccessibility: false) })
        let events = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let jsonl = try JSONLStore(retentionDays: 0, eventsDirectory: events, prepareApplicationStorage: false)
        let integrity = IntegrityStateStore(fileURL: root.appendingPathComponent("integrity.json"), prepareStorage: {})
        let sealer = MinuteSealer(stateStore: integrity, identity: BlockingFixtureIdentity(), initialDate: date(),
                                 sealDirectory: root.appendingPathComponent("seals"), prepareStorage: {}, sealAppender: { _, _ in })
        let recorder = EventRecorder(store: jsonl, integrityJournal: IntegrityJournal(stateStore: integrity), minuteSealer: sealer)
        let state = CaptureState(isGloballyPaused: { false }); state.setManualPaused(true)
        var samples = 0
        let provider = ContextProvider(configManager: config, permissions: permissions, blockingProbe: { [self] in samples += 1; return target(date()) })
        let monitor = ContextMonitor(provider: provider, recorder: recorder, state: state, configManager: config, permissions: permissions,
            captureHealth: CaptureHealthStore(permissions: permissions, fileURL: root.appendingPathComponent("health.json")),
            semanticContextStore: SemanticContextStore(semanticDirectory: root.appendingPathComponent("semantic")),
            memoryStore: LocalActivityMemoryStore(rootDirectory: root))
        var observed = 0; monitor.blockingSink = { _ in observed += 1 }
        monitor.setBlockingObservationEnabled(true)
        XCTAssertNil(monitor.sampleNow()); XCTAssertNil(monitor.sampleNow())
        monitor.setBlockingObservationEnabled(false)
        recorder.flush()
        XCTAssertEqual(samples, 3); XCTAssertEqual(observed, 3)
        XCTAssertNil(monitor.latestSnapshot); XCTAssertEqual(jsonl.metrics.appendedLineCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("semantic").path))
    }

    @MainActor func testRebootBackwardRestoresExactRemainingDuration() {
        let previous = date(), list = BlockList(name: "Quota", sites: [BlockSiteRule(pattern: "youtube.com")])
        let doc = BlockingDocument(lists: [list], sessions: [BlockSession(listIDs: [list.id], start: previous,
            end: previous.addingTimeInterval(600), lock: .locked)], clock: BlockingClockState(wall: previous, continuous: 100, boot: "old"))
        let now = previous.addingTimeInterval(-3600)
        let c = BlockingController(document: doc, clock: { now }, continuous: { 10 }, boot: { "new" })
        XCTAssertEqual(c.activeBlocks.count, 1)
        XCTAssertEqual(c.activeBlocks.first?.end.timeIntervalSince(now), 600)
    }

    @MainActor func testEndingLastBlockClearsVeilWithoutAnotherObservation() {
        var now = date(); let backend = FakeBlockingBackend()
        let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                   continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(60), lock: .free)
        c.observe(target(now)); XCTAssertEqual(backend.siteBlocks, 1)
        let cleared = backend.clearSites
        now = now.addingTimeInterval(60); c.refresh()
        XCTAssertFalse(c.needsObservation); XCTAssertGreaterThan(backend.clearSites, cleared)
    }

    @MainActor func testLoginFailureReachesExistingPageErrorAPI() {
        let now = date(), backend = FakeBlockingBackend(), list = BlockList(name: "Apps", apps: [BlockAppRule(bundleIdentifier: "game", name: "Jeu")])
        backend.loginFailure = true
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend)
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .locked)
        XCTAssertEqual(c.error, "Démarrage à la connexion indisponible.")
    }

    @MainActor func testAppRelaunchAndForceTerminationAuthorization() {
        let now = date(), backend = FakeBlockingBackend()
        let list = BlockList(name: "Apps", apps: [BlockAppRule(bundleIdentifier: "game", name: "Jeu")])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend)
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        var app = target(now); app.isBrowser = false; app.bundleIdentifier = "game"; app.isForeground = false
        c.observe(app); c.observe(app); XCTAssertEqual(backend.appBlocks, 2)
        XCTAssertTrue(backend.appStillBlocked?(app) == true)
        c.stop(c.activeBlocks[0].id); XCTAssertTrue(backend.appStillBlocked?(app) == false)
    }

    @MainActor func testOffStopsPersistedFreeSession() throws {
        let store = try temporaryStore(), now = date(), list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        try store.save(BlockingDocument(lists: [list], sessions: [BlockSession(listIDs: [list.id], start: now,
            end: now.addingTimeInterval(600), lock: .free)]))
        let c = BlockingController(clock: { now }, store: store)
        c.shutdown(); XCTAssertTrue(try store.load().sessions.isEmpty)
    }

    func testBlockingOnlyLaneDoesNotEnterHistoryPipeline() throws {
        XCTAssertTrue(ContextMonitor.usesBlockingOnlyLane(capturing: false, blockingEnabled: true))
        XCTAssertFalse(ContextMonitor.usesBlockingOnlyLane(capturing: true, blockingEnabled: true))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/ContextMonitor.swift"))
        let lane = source.components(separatedBy: "if blockingObservationEnabled &&")[1].components(separatedBy: "guard historyRequested, state.isCapturing")[0]
        XCTAssertTrue(lane.contains("provider.requestBlocking")); XCTAssertTrue(lane.contains("return nil"))
        for forbidden in ["recorder.record", "JevIngress.", "ActivityAnalysisRuntime.", "setLatest("] { XCTAssertFalse(lane.contains(forbidden)) }
    }
}

private final class BlockingFixtureIdentity: MinuteSealSigningIdentity {
    let info = DeviceIdentityInfo(deviceID: "blocking-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test")
    func sign(_ message: Data) throws -> Data { Data(SHA256Digest.hashHex(message).utf8) }
}

@MainActor private final class FakeBlockingBackend: BlockingEnforcementBackend {
    var accessibilityAvailable = true
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    func observeBrowser(_ target: BlockingObservation) {}
    var canLockScreen = true
    var browsers: [BlockingBrowserSupport] = []
    var clearSites = 0
    var loginFailure = false
    var siteBlocks = 0
    var appBlocks = 0
    var lastReason: BlockingVeilPresentation.Reason?
    func updateProtection(locked: Bool) -> BlockingProtectionState {
        var result = BlockingProtectionState()
        if locked && loginFailure { result.component = .failed("Démarrage à la connexion indisponible.") }
        return result
    }
    func blockApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) { appBlocks += 1 }
    func blockSite(_ target: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) { siteBlocks += 1; lastReason = presentation.reason }
    func clearSite() { clearSites += 1 }
    func updateFreeze(_ freeze: BlockFreeze?) {}
    func returnToShield() {}
    func shutdown() {}
}
#endif
