#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// A Mac clock set back by hand must not freeze wall-clock throttles (T-044 C3-01, C3-02):
/// `now - last >= N` stays negative until the wall clock catches up with `last`.
final class ClockRollbackThrottleTests: XCTestCase {
    private func parameters(excluded: [String]) -> ContextReadParameters {
        var config = RecorderConfig.default
        config.captureWindowTitles = true; config.captureElementLabels = true; config.captureURLs = true
        config.excludedBundleIdentifiers = []; config.excludedDomains = excluded
        var privacy = GoalongPrivacyPolicy(); privacy.revision = "none"
        let app = ForegroundAXApplication(pid: 42, name: "Safari", bundleIdentifier: "com.apple.Safari")
        return ContextReadParameters(foregroundApplication: app, applications: [42: app], config: config,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true,
            idleSeconds: 1, privacy: privacy, pauseRevision: "initial")
    }

    /// History lane: after the clock is set back, the address of the same window is never re-read,
    /// so a page of an excluded domain is recorded with its title under the previous URL.
    func testClockSetBackStillRereadsTheBrowserAddress() {
        var now = Date(timeIntervalSince1970: 1_791_158_400)
        let reader = ContextAXReader(clock: AXCaptureClock(date: { now }))
        let tree = ScriptedAXTree(browser: true), input = parameters(excluded: ["secret.example.org"])
        let first = AXAccess.withClient(tree.client) { reader.capture(parameters: input) }
        XCTAssertEqual(first.snapshot?.url?.value, "https://example.com/work")
        // Same tab, new page, 10 s later in real time; the user set the Mac clock back 1 h meanwhile.
        tree.attributes[Int(CFHash(tree.window))]?["AXDocument"] = "https://secret.example.org/diagnosis" as CFString
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Secret diagnosis" as CFString
        now = now.addingTimeInterval(-3_600)
        let second = AXAccess.withClient(tree.client) { reader.capture(parameters: input) }
        XCTAssertEqual(second.snapshot?.suppressionReason, .excludedDomain,
                       "excluded page recorded after a clock rollback: url=\(second.snapshot?.url?.value ?? "nil") title=\(second.snapshot?.window?.title ?? "nil")")
        XCTAssertNil(second.snapshot?.window?.title)
    }

    /// Control: the same navigation 2 s later without a clock change is suppressed.
    func testControlWithoutRollbackSuppressesTheExcludedPage() {
        var now = Date(timeIntervalSince1970: 1_791_158_400)
        let reader = ContextAXReader(clock: AXCaptureClock(date: { now }))
        let tree = ScriptedAXTree(browser: true), input = parameters(excluded: ["secret.example.org"])
        _ = AXAccess.withClient(tree.client) { reader.capture(parameters: input) }
        tree.attributes[Int(CFHash(tree.window))]?["AXDocument"] = "https://secret.example.org/diagnosis" as CFString
        now = now.addingTimeInterval(2)
        let second = AXAccess.withClient(tree.client) { reader.capture(parameters: input) }
        XCTAssertEqual(second.snapshot?.suppressionReason, .excludedDomain)
    }

    /// Concentration: the once-a-minute measurement request (T-044 B2-02) stops after a clock set back.
    @MainActor func testClockSetBackKeepsRequestingMeasurements() throws {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/clock-rollback-measure-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        var now = Date(timeIntervalSince1970: 1_791_158_400)
        let c = try ConcentrationController(store: s, clock: { now })
        var requests = 0
        c.measurementRefresh = { requests += 1 }
        c.observe(FocusObservation(at: now, observing: false))
        XCTAssertEqual(requests, 1)
        now = now.addingTimeInterval(-3_600)                       // the user sets the Mac clock back 1 h
        for _ in 0..<10 { now = now.addingTimeInterval(61); c.observe(FocusObservation(at: now, observing: false)) }
        XCTAssertGreaterThanOrEqual(requests, 10, "no measurement for ~10 real minutes after a clock rollback (got \(requests))")
    }

    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }

    /// Blocking: the periodic save (every 60 s) keeps running after a clock set back; a kill then loses at most a minute.
    @MainActor func testClockSetBackKeepsPeriodicBlockingSaves() throws {
        let root = URL(fileURLWithPath: "/private/tmp/clock-rollback-blocking-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = BlockingStore(directory: root)
        try store.save(.init(lists: [BlockList(name: "Sites")]))
        var now = Date(timeIntervalSince1970: 1_791_158_400), uptime = 1_000.0
        let b = BlockingController(clock: { now }, store: store, calendar: calendar, continuous: { uptime }, boot: { "test" })
        b.refresh()
        XCTAssertEqual(try store.load().clock?.continuous, 1_000)
        now = now.addingTimeInterval(-3_600)                       // the user sets the Mac clock back 1 h
        for _ in 0..<3 { now = now.addingTimeInterval(61); uptime += 61; b.refresh() }
        XCTAssertGreaterThan(try store.load().clock?.continuous ?? 0, 1_000, "no Blocking save for 3 real minutes after a clock rollback")
    }

    /// Commitments (#109): without any anchored commitment, a clock set back in the same boot cannot open a past day.
    @MainActor func testClockSetBackCannotOpenAPastDayWithoutAnchor() throws {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/clock-rollback-commit-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        var now = FocusCalendar.dayInterval("2026-10-05", calendar: calendar)!.start.addingTimeInterval(8 * 3_600), uptime = 1_000.0
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
        now = now.addingTimeInterval(-86_400); uptime += 10      // same boot, the clock set back one day
        XCTAssertThrowsError(try c.setCommitment(period: .init(kind: .day, key: "2026-10-04"), kind: .work, target: 60)) {
            XCTAssertEqual($0 as? FocusFailure, .invalidArgument)
        }
        XCTAssertNoThrow(try c.setCommitment(period: .init(kind: .day, key: "2026-10-05"), kind: .work, target: 60))
    }

    /// Commitments (C4-03): the launch anchor survives a relaunch in the same boot. Set the clock back one day,
    /// quit and relaunch Goalong (no stored commitment): yesterday still cannot be committed.
    @MainActor func testClockSetBackThenRelaunchCannotOpenAPastDay() throws {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/clock-rollback-relaunch-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        var now = FocusCalendar.dayInterval("2026-10-05", calendar: calendar)!.start.addingTimeInterval(8 * 3_600), uptime = 1_000.0
        _ = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
        now = now.addingTimeInterval(-86_400); uptime += 10      // same boot, the clock set back one day
        let relaunched = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
        XCTAssertThrowsError(try relaunched.setCommitment(period: .init(kind: .day, key: "2026-10-04"), kind: .work, target: 60),
                             "a relaunch in the same boot reopens a day already over")
    }

    /// Source guard: every wall-clock throttle goes through `throttleElapsed(since:)` (a gap either way counts).
    /// Any comparison of a gap measured from the current instant (`now`, `now()`, `Date()`, `clock()`, an
    /// observation `.at`) other than a sign check, any operator, any argument (T-044 C4-02, C4-05).
    func testWallClockThrottlesIgnoreTheDirectionOfTheGap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp")
        let regexes = try ["timeIntervalSince\\((self\\.)?(last\\w*|statusRead)\\)\\s*[<>]",
                           "(\\bnow(\\(\\))?|\\bDate\\(\\)|\\bclock\\(\\)|\\w\\.at)\\.timeIntervalSince\\(([^()]|\\([^()]*\\))*\\)\\s*+[<>]=?+\\s*+(?!0(?![\\d.]))",
                           "timeIntervalSinceNow\\s*[<>]"].map { try NSRegularExpression(pattern: $0) }
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        for file in files {
            for (i, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where regexes.contains(where: { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil })
                // A sign check on the same line bounds the gap both ways (the website pairing window, pinned by the audit).
                && !line.contains(") >= 0,") {
                hits.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(hits, [])
    }
}
#endif
