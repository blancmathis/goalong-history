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
        XCTAssertEqual(BlockingRules.neverBlocked, Set(["ai.goalong.localhistory", "ai.goalong.localhistory.dev", "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.SecurityAgent", "com.apple.coreautha", "com.apple.ScreenSaver.Engine"]))
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
        XCTAssertFalse(DashboardSection.sidebarSections(modules: [.blocking]).contains(.blocking))
        XCTAssertEqual(DashboardSection.blocking.sidebarParent, .concentration)
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
    @MainActor func testFirstQuotaSampleAfterMidnightKeepsYesterdayInHistory() {
        var now = date(5, 23, 59).addingTimeInterval(56)
        let list = BlockList(name: "Quota", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 30)
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        now = now.addingTimeInterval(1); c.observe(target(now))
        now = now.addingTimeInterval(2); c.observe(target(now))
        XCTAssertEqual(c.snapshot.usage?.quotaSecondsUsed[list.id], 2)
        // 00:00:00.5, 4.5 s after the last refresh: the sample itself must archive yesterday.
        now = now.addingTimeInterval(1.5); c.observe(target(now))
        XCTAssertEqual(c.snapshot.usage?.day, "2026-10-06")
        XCTAssertEqual(c.snapshot.usageHistory?["2026-10-05"]?.quotaSecondsUsed[list.id], 2)
        XCTAssertEqual(c.frictionCounts(day: "2026-10-05").quotaSecondsUsed[list.id], 2)
    }
    @MainActor func testFreezeAlertEndIsTheEndTheEngineStores() {
        let now = date(); let c = BlockingController(clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        XCTAssertEqual(BlockingWallClock.freezeEnd(now.addingTimeInterval(120), now: now), now.addingTimeInterval(300))
        XCTAssertEqual(BlockingWallClock.freezeEnd(now.addingTimeInterval(1_800), now: now), now.addingTimeInterval(1_800))
        XCTAssertEqual(BlockingWallClock.freezeEnd(now.addingTimeInterval(30 * 3_600), now: now), now.addingTimeInterval(24 * 3_600))
        c.startFreeze(until: now.addingTimeInterval(120), mode: .shield, allowedApps: [])
        XCTAssertEqual(c.freeze?.end, BlockingWallClock.freezeEnd(now.addingTimeInterval(120), now: now))
    }
    func testWallClockArithmeticHoldsOnDSTDays() {
        func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ s: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min, second: s))!
        }
        XCTAssertEqual(BlockingWallClock.next(hour: 8, minute: 0, after: at(3, 28, 22), calendar: calendar), at(3, 29, 8))
        XCTAssertEqual(BlockingWallClock.next(hour: 8, minute: 0, after: at(10, 24, 22), calendar: calendar), at(10, 25, 8))
        XCTAssertEqual(BlockingWallClock.next(hour: 23, minute: 0, after: at(10, 25, 22), calendar: calendar), at(10, 25, 23))
        for day in [(3, 29), (10, 25)] {
            XCTAssertEqual(BlockingWallClock.endOfDay(at(day.0, day.1, 12), calendar: calendar), at(day.0, day.1, 23, 59, 59))
            for minute in [600, 720] {
                XCTAssertEqual(BlockingWallClock.minuteOfDay(BlockingWallClock.wallTime(minute, on: at(day.0, day.1, 12), calendar: calendar), calendar: calendar), minute)
            }
        }
    }
    func testPageStopsFreeManualTriggerAndProgramBlocksOnly() {
        let id = UUID()
        XCTAssertTrue(BlockSession.Origin.manual.stopsFromPage)
        XCTAssertTrue(BlockSession.Origin.trigger(id).stopsFromPage)
        XCTAssertTrue(BlockSession.Origin.program(id).stopsFromPage)
        XCTAssertFalse(BlockSession.Origin.commitment(id).stopsFromPage)
        XCTAssertFalse(BlockSession.Origin.focus.stopsFromPage)
    }
    func testProgramLockSheetNeverProposesAnEndBeforeTheCurrentLock() {
        let now = date()
        XCTAssertEqual(BlockingProgramLock.initialUntil(current: nil, now: now, calendar: calendar), calendar.date(byAdding: .day, value: 14, to: now))
        let later = now.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(BlockingProgramLock.initialUntil(current: later, now: now, calendar: calendar), later)
    }
    func testSecondaryLineReadsAsASentenceAndSaysRalentiForSlowDown() {
        var slow = BlockList(name: "Lent"); slow.action = .slowDown
        let hard = BlockList(name: "Dur")
        XCTAssertEqual(BlockingFormat.verb([slow]), "Ralenti")
        XCTAssertEqual(BlockingFormat.verb([slow, hard]), "Bloqué")
        XCTAssertEqual(BlockingFormat.verb([]), "Bloqué")
        XCTAssertEqual(BlockingFormat.triggerPhrase(["Xcode"]), "tant que Xcode est ouvert")
        XCTAssertEqual(BlockingFormat.triggerPhrase(["Xcode", "Figma", "Slack"]), "tant que Xcode, Figma sont ouverts")
        XCTAssertEqual(BlockingFormat.triggerPhrase([]), "tant qu’une app de travail est ouverte")
    }
    @MainActor func testLockedRefusalsNameThePasswordBlock() throws {
        let now = date()
        var list = BlockList(name: "Sites", sites: [.init(pattern: "youtube.com")], quotaMinutesPerDay: 30, breaks: BlockBreaks(count: 1, minutes: 5))
        list.program.ranges = [.init(weekdays: [1], startMinute: 600, endMinute: 660)]
        let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        for (lock, prefix) in [(BlockLock.password, "Pendant un blocage par mot de passe, "), (.locked, "Pendant un verrou, ")] {
            let c = BlockingController(document: .init(lists: [list], passwordLock: credential), clock: { now }, calendar: calendar)
            c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: lock)
            XCTAssertFalse(c.activeBlocks.isEmpty)
            var quota = list; quota.quotaMinutesPerDay = 60
            var breaks = list; breaks.breaks = BlockBreaks(count: 2, minutes: 5)
            var program = list; program.program.ranges = []
            for next in [quota, breaks, program] {
                guard case .refused(let reason) = c.editCheck(next) else { XCTFail("\(lock) must refuse"); continue }
                XCTAssertTrue(reason.hasPrefix(prefix), reason)
            }
        }
    }
    @MainActor func testUnreadableAddressFailsClosedInPrivateAndNormalWindows() {
        for privateWindow in [true, false] {
            var now = date(); let backend = FakeBlockingBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 30)
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
            var t = target(now, url: nil); t.privateWindow = privateWindow; c.observe(t); let count = backend.siteBlocks
            now = now.addingTimeInterval(3); t.at = now; c.observe(t); XCTAssertEqual(backend.siteBlocks, count + 1)
            guard case .unsupportedBrowser? = backend.lastReason else { return XCTFail("\(String(describing: backend.lastReason))") }
            backend.accessibilityAvailable = false; c.refresh(); XCTAssertFalse(c.siteBlockingAvailable)
            XCTAssertNil(c.snapshot.usage?.quotaSecondsUsed[list.id])
        }
    }
    /// Aside regression: an activation (address not read yet) left an unreadable clock behind when the
    /// member switched away before the first read; every later activation then covered the browser at once.
    @MainActor func testActivationDoesNotReuseAnEarlierUnreadableClock() {
        var now = date(); let backend = FakeBlockingBackend()
        let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "x.com")])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(7200), lock: .free)
        func activate() { var t = target(now, url: nil); t.isActivation = true; c.observe(t) }
        activate()
        now = now.addingTimeInterval(1); c.observe(BlockingObservation(bundleIdentifier: "com.apple.finder", pid: 43000, windowFrame: nil,
            isBrowser: false, url: nil, privateWindow: false, at: now))
        now = now.addingTimeInterval(1800); activate(); c.refresh()
        XCTAssertEqual(backend.siteBlocks, 0); XCTAssertNil(backend.lastReason)
        var t = target(now, url: "https://wikipedia.org/a"); c.observe(t)
        XCTAssertEqual(backend.siteBlocks, 0); XCTAssertNil(backend.lastReason)
        // A truly unreadable address still covers the browser after 3 s of reads.
        t.url = nil; for _ in 0..<4 { c.observe(t); now = now.addingTimeInterval(1); t.at = now }
        guard case .unsupportedBrowser = backend.lastReason else { return XCTFail("expected whole-browser cover") }
    }
    /// A private window follows the lists, counts the quota, and no address of it reaches the Blocking folder.
    @MainActor func testPrivateWindowFollowsListsAndWritesNoAddress() throws {
        let store = try temporaryStore(); var now = date(); let backend = FakeBlockingBackend()
        let quota = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 1)
        let sites = BlockList(name: "Réseaux", sites: [BlockSiteRule(pattern: "instagram.com")])
        try store.save(BlockingDocument(lists: [quota, sites]))
        let c = BlockingController(clock: { now }, store: store, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [quota.id, sites.id], until: now.addingTimeInterval(3600), lock: .free)
        func visit(_ url: String) { var t = target(now, url: url); t.privateWindow = true; c.observe(t) }
        let start = backend.siteBlocks
        visit("wikipedia.org/zq-private-allowed"); XCTAssertEqual(backend.siteBlocks, start)
        visit("instagram.com/zq-private-listed"); XCTAssertEqual(backend.siteBlocks, start + 1)
        XCTAssertEqual(backend.lastReason, .site("instagram.com/zq-private-listed"))
        visit("youtube.com/zq-private-quota"); XCTAssertEqual(backend.siteBlocks, start + 1)
        for _ in 0..<5 { now = now.addingTimeInterval(15); visit("youtube.com/zq-private-quota") }
        XCTAssertEqual(c.snapshot.usage?.quotaSecondsUsed[quota.id], 60)
        XCTAssertEqual(backend.lastReason, .quotaUsed("youtube.com/zq-private-quota", minutes: 1))
        now = now.addingTimeInterval(20); c.refresh()
        XCTAssertEqual(try store.load().usage?.quotaSecondsUsed[quota.id], 60)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: store.directory, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where !file.hasDirectoryPath {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(text.contains("zq-private") || text.contains("wikipedia"), file.lastPathComponent); checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }
    func testReadButUnlistedAddressKeepsSchemeAndHostOnly() {
        XCTAssertEqual(BlockingRules.blockingAddress("https://www.youtube.com/shorts?q=1"), "youtube.com/shorts")
        XCTAssertEqual(BlockingRules.blockingAddress("http://user:pw@127.0.0.1:7788/runs?id=1"), "http://127.0.0.1:7788")
        XCTAssertEqual(BlockingRules.blockingAddress("localhost:3000/app"), "http://localhost:3000")
        XCTAssertEqual(BlockingRules.blockingAddress("chrome-extension://abc/popup.html"), "chrome-extension://abc")
        XCTAssertEqual(BlockingRules.blockingAddress("file:///Users/me/secret.pdf"), "file:")
    }
    /// A local page (127.0.0.1, localhost) is read, not unreadable: it never covers the whole browser.
    @MainActor func testLocalPagesAreReadAddresses() {
        var now = date(); let backend = FakeBlockingBackend()
        let sites = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 60)
        let c = BlockingController(document: BlockingDocument(lists: [sites]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [sites.id], until: now.addingTimeInterval(3600), lock: .free)
        for raw in ["http://127.0.0.1:7788/", "http://localhost:3000/dashboard"] {
            var t = target(now, url: BlockingRules.blockingAddress(raw))
            for _ in 0..<5 { c.observe(t); now = now.addingTimeInterval(1); t.at = now }
            XCTAssertEqual(backend.siteBlocks, 0, raw); XCTAssertEqual(backend.appBlocks, 0, raw)
            XCTAssertNil(backend.lastReason, raw); XCTAssertFalse(c.siteActionStillRequired(t), raw)
        }
        XCTAssertNil(c.snapshot.usage?.quotaSecondsUsed[sites.id])
        // A truly unreadable address still covers the whole browser after 3 s.
        var t = target(now, url: nil)
        for _ in 0..<4 { c.observe(t); now = now.addingTimeInterval(1); t.at = now }
        guard case .unsupportedBrowser = backend.lastReason else { return XCTFail("expected whole-browser cover") }
    }
    @MainActor func testLocalPagesUnderAllowOnlyAreTabBlocks() {
        let now = date(); let backend = FakeBlockingBackend()
        let list = BlockList(name: "Travail", mode: .allowOnly, sites: [BlockSiteRule(pattern: "example.com")])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: .free)
        for raw in ["http://127.0.0.1:7788/", "http://localhost:3000/dashboard"] {
            let address = BlockingRules.blockingAddress(raw)
            c.observe(target(now, url: address))
            XCTAssertEqual(backend.lastReason, .site(address), raw); XCTAssertEqual(backend.appBlocks, 0, raw)
        }
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
    /// R2-019: day keys written under a Buddhist or Japanese calendar are re-keyed to Gregorian once, counters kept.
    @MainActor func testLegacyCalendarDayKeysAreRekeyedOnLoad() throws {
        let now = date(15), list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        for (identifier, today, yesterday) in [(Calendar.Identifier.buddhist, "2569-10-15", "2569-10-14"), (.japanese, "0008-10-15", "0008-10-14"), (.indian, "1948-07-23", "1948-07-22")] {
            var legacy = Calendar(identifier: identifier); legacy.timeZone = calendar.timeZone
            var usage = BlockDayUsage(day: today); usage.quotaSecondsUsed[list.id] = 120; usage.breaksTaken[list.id] = 1
            var past = BlockDayUsage(day: yesterday); past.quotaSecondsUsed[list.id] = 300
            let store = try temporaryStore()
            try store.save(BlockingDocument(lists: [list], usage: usage, usageHistory: [yesterday: past]))
            for _ in 0..<2 {  // the second launch changes nothing
                let c = BlockingController(clock: { now }, store: store, calendarProvider: { legacy }, continuous: { now.timeIntervalSince1970 })
                XCTAssertEqual(c.frictionCounts(day: "2026-10-15").quotaSecondsUsed[list.id], 120, "\(identifier)")
                XCTAssertEqual(c.frictionCounts(day: "2026-10-15").breaksTaken[list.id], 1)
                XCTAssertEqual(c.frictionCounts(day: "2026-10-14").quotaSecondsUsed[list.id], 300, "\(identifier)")
                let saved = try store.load()
                XCTAssertEqual(saved.usage?.day, "2026-10-15"); XCTAssertEqual(Set(saved.usageHistory?.keys ?? [:].keys), ["2026-10-14"])
                XCTAssertEqual(saved.usageHistory?["2026-10-14"]?.day, "2026-10-14")
            }
        }
    }
    /// R2-076: the « + » button and the drag build their draft the same way, without needing a drag.
    @MainActor func testNewRangeDraftForADay() throws {
        let list = UUID()
        let draft = try XCTUnwrap(BlockingWeekEditor.newDraft(day: 1, start: BlockingWeekEditor.defaultStart,
                                                              end: BlockingWeekEditor.defaultEnd, firstList: list))
        XCTAssertNil(draft.existing); XCTAssertEqual(draft.days, [1]); XCTAssertEqual(draft.listIDs, [list])
        XCTAssertEqual(draft.start, 540); XCTAssertEqual(draft.end, 600)
        XCTAssertEqual(BlockingWeekEditor.newDraft(day: 2, start: 1_380, end: 1_440, firstList: list)?.end, 1_440)
        XCTAssertNil(BlockingWeekEditor.newDraft(day: 1, start: 540, end: 600, firstList: nil), "no list, no draft")
    }
    /// R2-065: the icon cluster lists each app or host once, so ids stay unique and "+N" counts unique items.
    func testIconClusterDeduplicatesItems() {
        let mail = BlockAppRule(bundleIdentifier: "com.apple.mail", name: "Mail")
        let one = BlockList(name: "A", sites: [.init(pattern: "youtube.com"), .init(pattern: "youtube.com/shorts")], apps: [mail])
        let two = BlockList(name: "B", sites: [.init(pattern: "youtube.com")], apps: [mail])
        XCTAssertEqual(BlockingIconCluster.items(for: [one, two]), [.app(mail), .site("youtube.com")])
    }
    /// R2-075: a failed marker write is retried on the next refresh, then not repeated.
    @MainActor func testFailedLockMarkerWriteIsRetried() throws {
        let store = try temporaryStore(), now = date(), list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        try store.save(BlockingDocument(lists: [list], sessions: [BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(3600), lock: .locked)]))
        let marker = store.directory.appendingPathComponent("locked-until")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)  // makes the rename fail
        var clockNow = now
        let c = BlockingController(clock: { clockNow }, store: store, continuous: { clockNow.timeIntervalSince1970 })
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory)); XCTAssertTrue(isDirectory.boolValue)
        try FileManager.default.removeItem(at: marker)
        c.refresh()
        let expected = "\(Int(now.timeIntervalSince1970) + 3600)\n"
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), expected)
        try Data("sentinel".utf8).write(to: marker); c.refresh()
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "sentinel", "a successful write is not repeated")
        // An unlink failure when the lock ends also retries.
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: marker.appendingPathComponent("f"))
        clockNow = now.addingTimeInterval(3601); c.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker); c.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    /// A click on a block opens the editor of that block, with its own hours; while a free, all-day range is
    /// blocking right now, the hours can still be changed and the range deleted (a free block freezes nothing).
    @MainActor func testClickingABlockEditsItsHoursAndCanDeleteIt() throws {
        let now = date()
        let weekdays = Set(1...7)
        let range = BlockProgramRange(weekdays: weekdays, startMinute: 0, endMinute: 1_440)
        var list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        list.program = BlockProgram(ranges: [range])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        XCTAssertFalse(c.activeBlocks.isEmpty, "the all-day free range blocks right now, as in the report")
        XCTAssertFalse(c.isStricterOnly(list.id), "a free block must not freeze its list")
        let draft = try XCTUnwrap(BlockingWeekEditor.editDraft(listID: list.id, rangeID: range.id, controller: c))
        XCTAssertEqual(draft.existing, range.id, "a click on a block edits it, it does not draw a new range")
        XCTAssertEqual([draft.start, draft.end], [0, 1_440]); XCTAssertEqual(draft.days, weekdays)
        var changed = try XCTUnwrap(c.list(list.id))
        changed.program.ranges[0].startMinute = 540; changed.program.ranges[0].endMinute = 1_020
        c.save(changed); XCTAssertNil(c.error); XCTAssertEqual(c.list(list.id)?.program.ranges.first?.startMinute, 540)
        XCTAssertEqual(c.list(list.id)?.program.ranges.first?.endMinute, 1_020)
        var removed = try XCTUnwrap(c.list(list.id)); removed.program.ranges.removeAll()
        c.save(removed); XCTAssertNil(c.error); XCTAssertEqual(c.list(list.id)?.program.ranges.count, 0)
        XCTAssertNil(BlockingWeekEditor.editDraft(listID: list.id, rangeID: range.id, controller: c), "a deleted range has no editor")
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
    func testRangeLockLegacyDecodeAndPasswordCredentialEncoding() throws {
        let vector = BlockPasswordLock(salt: Data(0..<16), hash: Data([UInt8](repeating: 0, count: 32)), iterations: 200_000, createdAt: date())
        var expected = vector
        let hex = "3f84897cea554f262085f818cba47df3ff873fbc9730534e3c7b47d123194432"
        expected.hash = Data(stride(from: 0, to: hex.count, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index), end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        })
        XCTAssertTrue(expected.matches("blocking-test-vector"))
        let range = try JSONDecoder().decode(BlockProgramRange.self, from: Data("{\"id\":\"\(UUID())\",\"weekdays\":[1],\"startMinute\":600,\"endMinute\":900}".utf8))
        XCTAssertNil(range.lock); XCTAssertEqual(range.effectiveLock, .free)
        let credential = try XCTUnwrap(BlockPasswordLock.make("blocking-test-secret-é\0suffix", at: date()))
        XCTAssertEqual(credential.salt.count, 16); XCTAssertEqual(credential.hash.count, 32)
        XCTAssertGreaterThanOrEqual(credential.iterations, 200_000)
        XCTAssertTrue(credential.matches("blocking-test-secret-é\0suffix"))
        XCTAssertFalse(credential.matches("blocking-test-secret-é"))
        let encoded = try JSONEncoder().encode(credential)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("blocking-test-secret"))
        XCTAssertEqual(try JSONDecoder().decode(BlockPasswordLock.self, from: encoded), credential)
        XCTAssertNotEqual(credential.salt, BlockPasswordLock.make("blocking-test-secret-é\0suffix", at: date())?.salt)
    }

    @MainActor func testProgramTypingSkipRequiresItsChallengeAndDoesNotSkipOverlap() {
        let now = date()
        let a = BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900, lock: .typing)
        let b = BlockProgramRange(weekdays: [1], startMinute: 660, endMinute: 840, lock: .locked)
        let list = BlockList(name: "Programme", program: .init(ranges: [a, b]))
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, calendar: calendar)
        XCTAssertEqual(c.activeBlocks.count, 2)
        c.stop(a.id); XCTAssertEqual(c.activeBlocks.count, 2)
        c.stop(a.id, typed: "incorrect"); XCTAssertEqual(c.activeBlocks.count, 2)
        c.stop(a.id, typed: c.typingChallenge(for: a.id))
        XCTAssertEqual(c.activeBlocks.map(\.id), [b.id]); XCTAssertEqual(c.snapshot.programSkips?[a.id], date(5, 15))
        c.stop(b.id, typed: c.typingChallenge(for: b.id)); XCTAssertEqual(c.activeBlocks.count, 1)
    }

    @MainActor func testLockedProgramRangeLockCanOnlyIncreaseAcrossAllPairs() throws {
        let now = date(), credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        for oldLock in BlockLock.allCases {
            let range = BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900, lock: oldLock)
            let list = BlockList(name: "Programme", program: .init(ranges: [range], lockedUntil: now.addingTimeInterval(3600)))
            let c = BlockingController(document: .init(lists: [list], passwordLock: credential), clock: { now }, calendar: calendar)
            XCTAssertEqual(c.activeBlocks.first?.lock, .locked)
            for newLock in BlockLock.allCases {
                var next = list; next.program.ranges[0].lock = newLock
                XCTAssertEqual(c.editCheck(next) == .allowed, newLock.strength >= oldLock.strength, "\(oldLock) → \(newLock)")
            }
        }
    }

    @MainActor func testScheduledSessionActivatesAtStartAndEndsExclusively() throws {
        var now = date(); let list = BlockList(name: "Sites", sites: [.init(pattern: "youtube.com")])
        let backend = FakeBlockingBackend()
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, calendar: calendar,
            continuous: { now.timeIntervalSince1970 }, runsTimers: true)
        defer { c.shutdown() }
        let start = now.addingTimeInterval(120), end = now.addingTimeInterval(300)
        let id = try XCTUnwrap(c.schedule(listIDs: [list.id], start: start, end: end, lock: .locked))
        XCTAssertTrue(c.activeBlocks.isEmpty); XCTAssertEqual(c.scheduledBlocks.map(\.id), [id]); XCTAssertTrue(c.hasTimer)
        XCTAssertFalse(c.needsObservation); XCTAssertEqual(c.nextProgramStart?.date, start); XCTAssertTrue(backend.protectionRequired)
        var relaxed = list; relaxed.sites = []; XCTAssertEqual(c.editCheck(relaxed), .allowed)
        now = start.addingTimeInterval(-60); c.refresh(); XCTAssertTrue(c.needsObservation)
        now = start; c.refresh(); XCTAssertEqual(c.activeBlocks.map(\.id), [id]); XCTAssertTrue(c.scheduledBlocks.isEmpty)
        XCTAssertNotEqual(c.editCheck(relaxed), .allowed)
        now = end; c.refresh(); XCTAssertTrue(c.activeBlocks.isEmpty); XCTAssertFalse(c.hasLocks); XCTAssertFalse(c.hasTimer)
    }

    @MainActor func testScheduledCancellationUsesEveryLockFriction() throws {
        let now = date(), list = BlockList(name: "Sites"), credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let c = BlockingController(document: .init(lists: [list], passwordLock: credential), clock: { now })
        for lock in BlockLock.allCases {
            let id = try XCTUnwrap(c.schedule(listIDs: [list.id], start: now.addingTimeInterval(60), end: now.addingTimeInterval(300), lock: lock))
            switch lock {
            case .free: XCTAssertEqual(c.cancelScheduled(id: id), .ok)
            case .typing:
                XCTAssertNotEqual(c.cancelScheduled(id: id), .ok)
                XCTAssertEqual(c.cancelScheduled(id: id, typed: c.typingChallenge(for: id)), .ok)
            case .password:
                XCTAssertNotEqual(c.cancelScheduled(id: id), .ok)
                XCTAssertEqual(c.cancelScheduled(id: id, password: "fixture"), .ok)
            case .locked: XCTAssertNotEqual(c.cancelScheduled(id: id, password: "fixture"), .ok)
            }
        }
        XCTAssertEqual(c.scheduledBlocks.count, 1); XCTAssertEqual(c.scheduledBlocks.first?.lock, .locked)
        XCTAssertNil(c.schedule(listIDs: [list.id], start: now.addingTimeInterval(-1), end: now.addingTimeInterval(60), lock: .free))
        XCTAssertNil(c.schedule(listIDs: [list.id, list.id], start: now.addingTimeInterval(60), end: now.addingTimeInterval(120), lock: .free))
    }

    @MainActor func testQuitPreservesFutureSessionsAndProgramRegistrationIncludesFreeRanges() throws {
        let store = try temporaryStore(), now = date()
        var list = BlockList(name: "Programme")
        let future = BlockSession(listIDs: [list.id], start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200), lock: .free)
        try store.save(.init(lists: [list], sessions: [future]))
        let c = BlockingController(clock: { now }, store: store, continuous: { now.timeIntervalSince1970 })
        XCTAssertTrue(c.requiresLaunchAtLogin); XCTAssertFalse(c.hasLocks); c.shutdown()
        XCTAssertEqual(try store.load().sessions, [future])
        list.program.ranges = [.init(weekdays: [2], startMinute: 600, endMinute: 900)]
        let backend = FakeBlockingBackend()
        let d = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, calendar: calendar)
        XCTAssertTrue(d.activeBlocks.isEmpty); XCTAssertTrue(backend.protectionRequired)
        XCTAssertFalse(d.hasLocks)
    }

    @MainActor func testPasswordMustBeSetAndCannotChangeWhileReferenced() throws {
        let now = date(), list = BlockList(name: "Sites")
        let c = BlockingController(document: .init(lists: [list]), clock: { now })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .password); XCTAssertTrue(c.activeBlocks.isEmpty)
        var program = list; program.program.ranges = [.init(weekdays: [1], startMinute: 600, endMinute: 900, lock: .password)]
        c.save(program); XCTAssertTrue(c.list(list.id)!.program.ranges.isEmpty)
        XCTAssertFalse(c.setPassword("")); XCTAssertTrue(c.setPassword("fixture")); XCTAssertTrue(c.hasPassword)
        XCTAssertFalse(c.setPassword("replacement"))
        XCTAssertEqual(c.changePassword(old: "wrong", new: "replacement"), .wrong(remaining: 4))
        let id = try XCTUnwrap(c.schedule(listIDs: [list.id], start: now.addingTimeInterval(60), end: now.addingTimeInterval(300), lock: .password))
        XCTAssertNotEqual(c.changePassword(old: "fixture", new: "replacement"), .ok)
        XCTAssertNotEqual(c.removePassword(old: "fixture"), .ok)
        c.delete(list.id); XCTAssertNotNil(c.list(list.id))
        XCTAssertEqual(c.cancelScheduled(id: id, password: "fixture"), .ok)
        XCTAssertEqual(c.changePassword(old: "fixture", new: "replacement"), .ok)
        XCTAssertEqual(c.removePassword(old: "fixture"), .wrong(remaining: 4))
        XCTAssertEqual(c.removePassword(old: "replacement"), .ok); XCTAssertFalse(c.hasPassword)
    }

    @MainActor func testPasswordActiveListStrictnessAndQuitAuthorizationAreScoped() throws {
        var now = date(); let list = BlockList(name: "Sites", sites: [.init(pattern: "youtube.com")])
        let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let c = BlockingController(document: .init(lists: [list], passwordLock: credential), clock: { now }, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .password)
        let id = c.activeBlocks[0].id
        XCTAssertTrue(c.quitRequiresPassword); XCTAssertTrue(c.hasLocks); XCTAssertFalse(c.quitIsLocked)
        var relaxed = list; relaxed.sites = []
        if case .refused(let reason) = c.editCheck(relaxed) { XCTAssertTrue(reason.contains("mot de passe")) } else { XCTFail("Relaxation admitted") }
        c.delete(list.id); XCTAssertNotNil(c.list(list.id)); c.stop(id); XCTAssertEqual(c.activeBlocks.count, 1)
        XCTAssertFalse(c.consumeQuitAuthorization())
        XCTAssertEqual(c.authorizeQuit(password: "fixture"), .ok); XCTAssertEqual(c.activeBlocks.count, 1)
        XCTAssertTrue(c.consumeQuitAuthorization()); XCTAssertFalse(c.consumeQuitAuthorization())
        XCTAssertEqual(c.authorizeQuit(password: "fixture"), .ok)
        now = now.addingTimeInterval(31); XCTAssertFalse(c.consumeQuitAuthorization())
        XCTAssertEqual(c.authorizeQuit(password: "fixture"), .ok)
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .password)
        XCTAssertFalse(c.consumeQuitAuthorization())
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .locked)
        XCTAssertNotEqual(c.authorizeQuit(password: "fixture"), .ok); XCTAssertTrue(c.quitIsLocked)
        XCTAssertEqual(c.unlockWithPassword("fixture", blockID: id), .ok)
        XCTAssertEqual(c.activeBlocks.count, 2)
    }

    @MainActor func testPasswordProgramSkipProtectsOnlyThisOccurrence() throws {
        var now = date(); let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let range = BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900, lock: .password)
        let list = BlockList(name: "Programme", program: .init(ranges: [range]))
        let c = BlockingController(document: .init(lists: [list], passwordLock: credential), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        XCTAssertEqual(c.activeBlocks.first?.lock, .password)
        XCTAssertEqual(c.unlockWithPassword("wrong", blockID: range.id), .wrong(remaining: 4)); XCTAssertEqual(c.activeBlocks.count, 1)
        XCTAssertEqual(c.unlockWithPassword("fixture", blockID: range.id), .ok); XCTAssertTrue(c.activeBlocks.isEmpty)
        XCTAssertNotEqual(c.removePassword(old: "fixture"), .ok)
        now = date(12); c.refresh(); XCTAssertEqual(c.activeBlocks.first?.lock, .password)
    }

    @MainActor func testPasswordCooldownPersistsAndDoublesUpToOneHour() throws {
        let store = try temporaryStore(); var now = date()
        let list = BlockList(name: "Sites"), credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let session = BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(86_400), lock: .password)
        try store.save(.init(lists: [list], sessions: [session], passwordLock: credential))
        let c = BlockingController(clock: { now }, store: store, continuous: { now.timeIntervalSince1970 })
        for attempt in 1...4 { XCTAssertEqual(c.unlockWithPassword("wrong", blockID: session.id), .wrong(remaining: 5 - attempt)) }
        let firstWait = now.addingTimeInterval(60)
        XCTAssertEqual(c.unlockWithPassword("wrong", blockID: session.id), .wait(until: firstWait))
        XCTAssertEqual(c.authorizeQuit(password: "fixture"), .wait(until: firstWait))
        XCTAssertEqual(try store.load().passwordLock?.failedAttempts, 5)
        let relaunched = BlockingController(clock: { now }, store: store, continuous: { now.timeIntervalSince1970 })
        XCTAssertEqual(relaunched.unlockWithPassword("fixture", blockID: session.id), .wait(until: firstWait))
        for delay in [120.0, 240, 480, 960, 1920, 3600, 3600] {
            now = try XCTUnwrap(relaunched.snapshot.passwordLock?.retryAfter)
            XCTAssertEqual(relaunched.unlockWithPassword("wrong", blockID: session.id), .wait(until: now.addingTimeInterval(delay)))
        }
        now = try XCTUnwrap(relaunched.snapshot.passwordLock?.retryAfter)
        XCTAssertEqual(relaunched.unlockWithPassword("fixture", blockID: session.id), .ok)
        XCTAssertEqual(try store.load().passwordLock?.failedAttempts, 0); XCTAssertNil(try store.load().passwordLock?.retryAfter)
        XCTAssertTrue(relaunched.activeBlocks.isEmpty)
    }

    @MainActor func testMissingOrUnreadablePasswordNeverRecoversToWeakerDocument() throws {
        let store = try temporaryStore(); var now = date(); let list = BlockList(name: "Sites")
        let session = BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(600), lock: .password)
        let doc = BlockingDocument(lists: [list], sessions: [session])
        try store.save(.init(lists: [list])); try store.save(doc)
        for badCredential in [NSNull(), "invalid", ["salt": "not-base64", "hash": 3], ["salt": "", "hash": "", "iterations": 1, "createdAt": 0]] as [Any] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
            object["passwordLock"] = badCredential
            try JSONSerialization.data(withJSONObject: object).write(to: store.directory.appendingPathComponent("blocking.json"))
            let recovered = try store.loadRecovering(); XCTAssertEqual(recovered.recovery, .none)
            let c = BlockingController(document: recovered.document, clock: { now }, continuous: { now.timeIntervalSince1970 })
            XCTAssertFalse(c.hasPassword); XCTAssertEqual(c.activeBlocks.first?.lock, .locked)
            XCTAssertNotEqual(c.unlockWithPassword("anything", blockID: session.id), .ok)
            XCTAssertFalse(c.setPassword("replacement")); c.stop(session.id); XCTAssertEqual(c.activeBlocks.count, 1)
        }
        let c = BlockingController(document: doc, clock: { now }, continuous: { now.timeIntervalSince1970 })
        now = now.addingTimeInterval(600); c.refresh(); XCTAssertTrue(c.activeBlocks.isEmpty); XCTAssertFalse(c.hasLocks)
    }

    @MainActor func testPasswordLockRejectsRuntimeAndModuleSwitchDisable() throws {
        let now = date(), list = BlockList(name: "Sites"), credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let c = BlockingController(document: .init(lists: [list], sessions: [.init(listIDs: [list.id], start: now, end: now.addingTimeInterval(600), lock: .password)], passwordLock: credential), clock: { now })
        let name = "blocking-password-runtime-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let modules = GoalongModuleStore(defaults: defaults); modules.setEnabled(.blocking, true)
        let runtime = BlockingRuntime(controller: c); runtime.start(modules: modules)
        modules.setEnabled(.blocking, false); XCTAssertTrue(modules.isEnabled(.blocking)); XCTAssertTrue(runtime.controller === c)
        runtime.apply(enabled: false); XCTAssertTrue(runtime.controller === c); XCTAssertTrue(modules.isEnabled(.blocking))
    }

    @MainActor func testPasswordClockJumpPreservesSessionAndCooldown() throws {
        var now = date(), uptime = 100.0; let list = BlockList(name: "Sites")
        var credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        credential.failedAttempts = 5; credential.retryAfter = now.addingTimeInterval(60)
        let session = BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(600), lock: .password)
        let c = BlockingController(document: .init(lists: [list], sessions: [session], passwordLock: credential), clock: { now }, continuous: { uptime }, boot: { "test" })
        now = now.addingTimeInterval(3601); uptime += 1; c.refresh()
        XCTAssertEqual(c.activeBlocks.first?.end, date().addingTimeInterval(4200))
        XCTAssertEqual(c.snapshot.passwordLock?.retryAfter, date().addingTimeInterval(3660))
    }

    @MainActor func testStoreFailureCannotAuthorizePasswordRelease() throws {
        let store = try temporaryStore(), now = date(), list = BlockList(name: "Sites")
        let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let session = BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(600), lock: .password)
        try store.save(.init(lists: [list], sessions: [session], passwordLock: credential))
        let c = BlockingController(clock: { now }, store: store, continuous: { now.timeIntervalSince1970 })
        try FileManager.default.removeItem(at: store.directory)
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: store.directory.deletingLastPathComponent())
        XCTAssertNotEqual(c.unlockWithPassword("fixture", blockID: session.id), .ok)
        XCTAssertNotEqual(c.authorizeQuit(password: "fixture"), .ok)
        XCTAssertFalse(c.consumeQuitAuthorization()); XCTAssertEqual(c.activeBlocks.count, 1)
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
        monitor.sampleNow(); monitor.sampleNow()
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
        XCTAssertTrue(lane.contains("provider.requestBlocking")); XCTAssertTrue(lane.contains("finish(nil)"))
        for forbidden in ["recorder.record", "JevIngress.", "ActivityAnalysisRuntime.", "setLatest("] { XCTAssertFalse(lane.contains(forbidden)) }
    }

    @MainActor func testLoginItemNoticeDoesNotTurnSavedEditsIntoRefusals() throws {
        let now = date()
        var list = BlockList(name: "Programme", sites: [.init(pattern: "youtube.com")])
        list.program.ranges = [.init(weekdays: [2], startMinute: 600, endMinute: 900)]
        for component in [BlockingProtectionState.Component.awaitingApproval, .failed("Démarrage à la connexion indisponible.")] {
            let backend = FakeBlockingBackend(); backend.protectionComponent = component
            let c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, calendar: calendar)
            XCTAssertNotNil(c.error, "the login-item notice stays visible")
            XCTAssertEqual(c.addKeyword("match", to: list.id), .allowed)
            XCTAssertEqual(c.addException("youtube.com/@cours", to: list.id), .allowed)
            XCTAssertEqual(c.lists.first?.keywords, ["match"])
            XCTAssertEqual(c.lists.first?.exceptions, [.init(pattern: "youtube.com/@cours")])
            XCTAssertNoThrow(try c.addDistraction(XCTUnwrap(JevDistractionTarget.site(host: "reddit.com")), to: list.id))
            XCTAssertTrue(c.lists.first?.sites.contains(.init(pattern: "reddit.com")) == true)
            XCTAssertNotNil(c.error, "the login-item notice stays visible")
            // A genuine refusal is still reported.
            XCTAssertNotEqual(c.addKeyword("x", to: list.id), .allowed)
        }
    }

    @MainActor func testLockedListStillRefusesLooserEditsWithLoginItemNotice() throws {
        let now = date(); var list = BlockList(name: "Sites", sites: [.init(pattern: "youtube.com")]); list.keywords = ["match"]
        let backend = FakeBlockingBackend(); backend.protectionComponent = .awaitingApproval
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, calendar: calendar)
        c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: .locked)
        XCTAssertFalse(c.activeBlocks.isEmpty)
        guard case .refused = c.removeKeyword("match", from: list.id) else { return XCTFail("a looser edit must be refused") }
        XCTAssertEqual(c.addKeyword("direct", to: list.id), .allowed)
    }
    private func zone(_ id: String) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: id)!; return result
    }
    /// R1-228: a zone change holds a locked window in progress, then future programs follow the new zone.
    @MainActor func testZoneChangeHoldsTheActiveLockedProgramAndMovesFutureStarts() {
        var current = zone("Europe/Paris"), now = date(5, 10)
        var list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 720, lock: .locked)])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendarProvider: { current },
                                   continuous: { now.timeIntervalSince1970 })
        XCTAssertEqual(c.activeBlocks.first?.end, date(5, 12))
        current = zone("America/New_York"); c.refresh()   // 04:00 in New York
        XCTAssertEqual(c.activeBlocks.first?.end, date(5, 12), "the locked window keeps its Paris end")
        XCTAssertEqual(c.activeBlocks.first?.lock, .locked)
        now = date(5, 11, 59); c.refresh(); XCTAssertFalse(c.activeBlocks.isEmpty)
        now = date(5, 12, 1); c.refresh(); XCTAssertTrue(c.activeBlocks.isEmpty)
        XCTAssertEqual(c.nextProgramStart?.date, date(5, 15), "09:00 in New York")
        XCTAssertEqual(c.nextProgramStart?.date, BlockingSchedule.nextStart(of: list.program, after: now, calendar: current))
        now = date(5, 15, 1); c.refresh(); XCTAssertEqual(c.activeBlocks.first?.end, date(5, 18))
    }
    /// R1-228: moving east keeps the usage day in progress until its old midnight, then follows the new zone.
    @MainActor func testZoneChangeKeepsTheQuotaDayUntilItsOldMidnight() {
        var current = zone("America/New_York")
        var now = zone("America/New_York").date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 20))!
        let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 20)
        let document = BlockingDocument(lists: [list], usage: BlockDayUsage(day: "2026-10-05", quotaSecondsUsed: [list.id: 600]))
        let c = BlockingController(document: document, clock: { now }, calendarProvider: { current }, continuous: { now.timeIntervalSince1970 })
        XCTAssertEqual(c.frictionUsage?.quotaSecondsUsed[list.id], 600)
        current = zone("Europe/Paris"); c.refresh()   // 02:00 on Tuesday in Paris
        XCTAssertEqual(c.frictionUsage?.day, "2026-10-05"); XCTAssertEqual(c.frictionUsage?.quotaSecondsUsed[list.id], 600)
        now = date(6, 5, 59); c.refresh()
        XCTAssertEqual(c.frictionUsage?.day, "2026-10-05"); XCTAssertEqual(c.frictionUsage?.quotaSecondsUsed[list.id], 600)
        now = date(6, 6, 1); c.refresh()
        XCTAssertEqual(c.frictionUsage?.day, "2026-10-06"); XCTAssertNil(c.frictionUsage?.quotaSecondsUsed[list.id])
        XCTAssertEqual(c.snapshot.usageHistory?["2026-10-05"]?.quotaSecondsUsed[list.id], 600)
        now = date(7, 0, 1); c.refresh(); XCTAssertEqual(c.frictionUsage?.day, "2026-10-07", "Paris midnight now")
    }
    /// R1-228: the running controller re-reads the zone on the system notification, without waiting for a timer.
    @MainActor func testZoneChangeNotificationRecomputesTheNextStart() {
        var current = zone("Europe/Paris"); let now = date(5, 6)
        var list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 720)])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendarProvider: { current },
                                   continuous: { now.timeIntervalSince1970 }, runsTimers: true)
        defer { c.shutdown() }
        XCTAssertEqual(c.nextProgramStart?.date, date(5, 9))
        current = zone("America/New_York")
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(c.nextProgramStart?.date, date(5, 15))
    }
    /// R2-088: a program due during sleep starts on wake without waiting for the next timer tick.
    @MainActor func testWakeNotificationStartsAProgramDueDuringSleep() {
        var now = date(5, 8)
        var list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 720)])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, calendar: calendar,
                                   continuous: { now.timeIntervalSince1970 }, runsTimers: true)
        defer { c.shutdown() }
        XCTAssertTrue(c.activeBlocks.isEmpty)
        now = date(5, 9, 30)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(c.activeBlocks.isEmpty); XCTAssertTrue(c.needsObservation); XCTAssertTrue(c.hasTimer)
    }

    /// R4-blocage-02: a range added to several lists is checked on every list before the first write.
    @MainActor func testRangeOnSeveralListsIsAllOrNone() {
        let now = date()
        let a = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
        var b = BlockList(name: "Réseaux", sites: [BlockSiteRule(pattern: "x.com")])
        b.reason = String(repeating: "a", count: 200)
        var locked = BlockList(name: "Travail", sites: [BlockSiteRule(pattern: "reddit.com")])
        locked.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900)], lockedUntil: now.addingTimeInterval(3600))
        let c = BlockingController(document: BlockingDocument(lists: [a, b, locked]), clock: { now }, calendar: calendar,
                                   continuous: { now.timeIntervalSince1970 })
        func adding(_ list: BlockList) -> BlockList {
            var next = list; next.program.ranges.append(BlockProgramRange(weekdays: [2], startMinute: 540, endMinute: 600)); return next
        }
        let refused = c.saveAll([adding(a), adding(b)])
        XCTAssertEqual(refused?.hasPrefix("« Réseaux » : "), true)
        XCTAssertEqual(c.list(a.id)?.program.ranges.count, 0, "nothing written when one list refuses")
        XCTAssertEqual(c.list(b.id)?.program.ranges.count, 0)
        // A refused change of a locked range returns its reason: the popover stays open on it.
        var shorter = locked; shorter.program.ranges[0].endMinute = 840
        XCTAssertNotNil(c.save(shorter))
        XCTAssertEqual(c.list(locked.id)?.program.ranges.first?.endMinute, 900)
        // Without the refused list, every chosen list gets its own copy of the range.
        let valid = BlockingController(document: BlockingDocument(lists: [a, locked]), clock: { now }, calendar: calendar,
                                       continuous: { now.timeIntervalSince1970 })
        XCTAssertNil(valid.saveAll([adding(a), adding(locked)]))
        XCTAssertEqual(valid.list(a.id)?.program.ranges.count, 1); XCTAssertEqual(valid.list(locked.id)?.program.ranges.count, 2)
    }

    /// R4-blocage-03: the composer reads the clock when it starts; a start time already past starts now.
    func testNowPlanUsesTheClockOfTheStart() {
        let now = date()
        let past = BlockingNowPlan(later: true, startAt: now.addingTimeInterval(-10), minutes: 30, now: now)
        XCTAssertFalse(past.startsLater); XCTAssertEqual(past.start, now)
        XCTAssertEqual(past.end.timeIntervalSince(now), 30 * 60, "the full duration from this second")
        let later = BlockingNowPlan(later: true, startAt: now.addingTimeInterval(3_600), minutes: 60, now: now)
        XCTAssertTrue(later.startsLater); XCTAssertEqual(later.end, now.addingTimeInterval(7_200))
        let until = BlockingNowPlan(later: false, startAt: now, until: date(5, 9), now: now, calendar: calendar)
        XCTAssertEqual(until.end, date(6, 9), "an earlier time of day means tomorrow")
    }

    /// R4-blocage-01: the lock alert says the day of the end, and both ends of a later block.
    func testLockAlertSaysTheDay() {
        let now = date(5, 10) // Monday
        func t(_ d: Date) -> String { BlockingFormat.time(d) }
        XCTAssertEqual(BlockingFormat.deadline(date(5, 12), now: now, calendar: calendar), t(date(5, 12)))
        XCTAssertEqual(BlockingFormat.deadline(date(6, 0), now: now, calendar: calendar), "minuit")
        XCTAssertEqual(BlockingFormat.deadline(date(6, 2), now: now, calendar: calendar), "demain à \(t(date(6, 2)))")
        XCTAssertEqual(BlockingFormat.deadline(date(10, 12), now: now, calendar: calendar), "samedi à \(t(date(10, 12)))")
        XCTAssertEqual(BlockingFormat.deadline(date(11, 0), now: now, calendar: calendar), "samedi à minuit")
        let saturday = BlockingNowPlan(later: true, startAt: date(10, 10), minutes: 120, now: now)
        XCTAssertEqual(saturday.lockTitle(.locked, calendar: calendar), "Verrouiller samedi de \(t(date(10, 10))) à \(t(date(10, 12))) ?")
        XCTAssertTrue(saturday.lockMessage(.locked, calendar: calendar).contains("avant samedi à \(t(date(10, 12)))"))
        let overnight = BlockingNowPlan(later: false, startAt: now, minutes: 20 * 60, now: now)
        XCTAssertEqual(overnight.lockTitle(.password, calendar: calendar), "Protéger par mot de passe jusqu’à demain à \(t(date(6, 6))) ?")
        XCTAssertEqual(BlockingFormat.period(from: date(5, 22), to: date(6, 2), now: now, calendar: calendar),
                       "de aujourd’hui à \(t(date(5, 22))) à demain à \(t(date(6, 2)))")
    }

    /// R4-blocage-05 and 07: a range ending at 24:00 reads 24:00; long durations keep their minutes.
    func testRangeLabelAndLongRemaining() {
        XCTAssertEqual(BlockingFormat.rangeLabel(name: "Vidéo", weekday: 1, start: 1_320, end: 1_440, lock: .locked),
                       "Vidéo, lundi, 22:00 à 24:00, verrouillé")
        XCTAssertEqual(BlockingFormat.rangeLabel(name: "Vidéo", weekday: 7, start: 540, end: 600, lock: .free), "Vidéo, dimanche, 9:00 à 10:00")
        XCTAssertEqual(BlockingFormat.remaining(86_400), "1 jour")
        XCTAssertEqual(BlockingFormat.remaining(86_400 + 2_400), "1 jour 40 min")
        XCTAssertEqual(BlockingFormat.remaining(86_400 + 3 * 3_600 + 2_400), "1 jour 3 h 40")
        XCTAssertEqual(BlockingFormat.remaining(2 * 86_400 + 3 * 3_600), "2 jours 3 h")
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
    var protectionRequired = false
    var protectionComponent: BlockingProtectionState.Component?
    func updateProtection(locked: Bool) -> BlockingProtectionState {
        protectionRequired = locked
        var result = BlockingProtectionState()
        if locked && loginFailure { result.component = .failed("Démarrage à la connexion indisponible.") }
        if locked, let protectionComponent { result.component = protectionComponent }
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
