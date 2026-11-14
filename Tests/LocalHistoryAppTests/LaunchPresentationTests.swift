#if os(macOS)
    import AppKit
    import XCTest
    import GoalongGuardCore
    @testable import LocalHistoryApp

    /// T-062: a member's open shows the dashboard the first time; other launches stay in the menu bar.
    final class LaunchPresentationTests: XCTestCase {
        private let core = AEEventClass(kCoreEventClass)
        private let open = AEEventID(kAEOpenApplication)
        private let now = Date(timeIntervalSince1970: 10_000)

        private func origin(_ arguments: [String] = ["Goalong History"], eventClass: AEEventClass? = nil,
                            eventID: AEEventID? = nil, property: OSType? = nil) -> LaunchOrigin {
            LaunchOrigin.classify(arguments: arguments, eventClass: eventClass ?? core,
                                  eventID: eventID ?? open, launchProperty: property)
        }

        func testSpotlightOrFinderOpenIsTheMember() {
            XCTAssertEqual(origin(), .member)
            XCTAssertEqual(origin(eventID: AEEventID(kAEReopenApplication)), .member)
        }

        func testLoginServiceGuardAndLinkLaunchesAreNotTheMember() {
            XCTAssertEqual(origin(property: OSType(keyAELaunchedAsLogInItem)), .loginItem)
            XCTAssertEqual(origin(property: OSType(keyAELaunchedAsServiceItem)), .serviceItem)
            XCTAssertEqual(origin(["Goalong History", GuardIdentity.relaunchArgument]), .guardRelaunch)
            XCTAssertEqual(origin(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL)),
                           .document)
            XCTAssertEqual(origin(eventID: AEEventID(kAEOpenDocuments)), .document)
            XCTAssertEqual(LaunchOrigin.classify(arguments: ["Goalong History"], eventClass: nil, eventID: nil,
                                                 launchProperty: nil), .unknown)
        }

        func testRealLaunchEventDescriptorIsReadLikeAppKitDeliversIt() {
            let event = NSAppleEventDescriptor(eventClass: core, eventID: open, targetDescriptor: nil,
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            XCTAssertEqual(LaunchOrigin.current(event, arguments: ["Goalong History"]), .member)
            event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: keyAEPropData)
            XCTAssertEqual(LaunchOrigin.current(event, arguments: ["Goalong History"]), .loginItem)
            XCTAssertEqual(LaunchOrigin.current(nil, arguments: ["Goalong History"]), .unknown)
        }

        private func start(_ age: TimeInterval?, _ source: SessionStart.Source = .console) -> SessionStart? {
            age.map { SessionStart(date: now.addingTimeInterval(-$0), source: source) }
        }

        private func shows(_ origin: LaunchOrigin, quiet: Double = 0, age: TimeInterval? = 3600) -> Bool {
            LaunchPresentation.showsDashboardAtLaunch(origin: origin, quietRelaunchUntil: quiet, now: now,
                                                      sessionStart: start(age))
        }

        func testOnlyAMemberOpenOutsideTheSessionStartAndUpdateShowsTheWindow() {
            XCTAssertTrue(shows(.member))
            for other in [LaunchOrigin.loginItem, .serviceItem, .guardRelaunch, .document, .unknown] {
                XCTAssertFalse(shows(other), "\(other)")
            }
            // Sparkle's relaunch: quiet marker still valid.
            XCTAssertFalse(shows(.member, quiet: now.timeIntervalSince1970 + 60))
            XCTAssertTrue(shows(.member, quiet: now.timeIntervalSince1970 - 1))
            // Session restore right after boot or login.
            XCTAssertFalse(shows(.member, age: 30))
        }

        /// R2: only the session's age decides. A long uptime or a short one means nothing by itself.
        func testSessionAgeAloneDecides() {
            let quiet = LaunchPresentation.sessionQuietPeriod
            XCTAssertFalse(shows(.member, age: quiet - 1))
            XCTAssertTrue(shows(.member, age: quiet))
            XCTAssertFalse(shows(.member, age: nil))
            // A start in the future (clock set back) stays quiet.
            XCTAssertFalse(shows(.member, age: -3600))
            for source in [SessionStart.Source.console, .loginWindow, .boot] {
                XCTAssertTrue(LaunchPresentation.isClearMemberOpen(origin: .member, now: now, sessionStart: start(3600, source)))
                XCTAssertFalse(LaunchPresentation.isClearMemberOpen(origin: .member, now: now, sessionStart: start(20, source)))
            }
        }

        /// Decision 2026-11-14: logout then login without reboot. The login item's event may lack the
        /// login-item flag (SMAppService). The new session's age keeps the window closed.
        func testLoginItemAfterLogoutWithoutRebootStaysQuiet() {
            XCTAssertFalse(shows(.member, age: 20))
            XCTAssertFalse(shows(.loginItem, age: 3600))
            XCTAssertFalse(shows(.member, age: nil))
            // Same session, minutes later: Spotlight shows the window.
            XCTAssertTrue(shows(.member, age: LaunchPresentation.sessionQuietPeriod))
        }

        // MARK: R1 — session start fallback chain

        private typealias R = LoginSession.Record
        private let boot = Date(timeIntervalSince1970: 1_000)

        func testConsoleLoginIsTheLatestUserConsoleRecord() {
            let old = Date(timeIntervalSince1970: 2_000), new = Date(timeIntervalSince1970: 9_000)
            let records = [
                R(isUserProcess: true, line: "console", user: "member", date: old),
                R(isUserProcess: true, line: "console", user: "member", date: new),
                R(isUserProcess: true, line: "ttys000", user: "member", date: Date(timeIntervalSince1970: 9_500)),
                R(isUserProcess: true, line: "console", user: "other", date: Date(timeIntervalSince1970: 9_900)),
                R(isUserProcess: false, line: "console", user: "member", date: Date(timeIntervalSince1970: 9_990)),
            ]
            XCTAssertEqual(LoginSession.latestConsoleLogin(records, user: "member"), new)
            XCTAssertNil(LoginSession.latestConsoleLogin(records, user: "nobody"))
            // Live read (no console session on a CI runner): never in the future, never nil (boot time exists).
            if let live = LoginSession.current() { XCTAssertLessThanOrEqual(live.date, Date()) }
        }

        func testConsoleRecordMatchesByUidToo() {
            let when = Date(timeIntervalSince1970: 5_000)
            let records = [R(isUserProcess: true, line: "console", user: "Member.Alias", date: when, uid: 501),
                           R(isUserProcess: true, line: "console", user: "someone", date: Date(timeIntervalSince1970: 6_000), uid: 502)]
            XCTAssertEqual(LoginSession.latestConsoleLogin(records, user: "member", uid: 501), when)
            XCTAssertNil(LoginSession.latestConsoleLogin(records, user: "member", uid: nil))
            XCTAssertNil(LoginSession.latestConsoleLogin(records, user: "member", uid: 503))
        }

        func testSessionStartFallbackChain() {
            let console = Date(timeIntervalSince1970: 5_000), loginWindow = Date(timeIntervalSince1970: 3_000)
            let records = [R(isUserProcess: true, line: "console", user: "member", date: console)]
            func chain(_ records: [R], lw: Date?, boot: Date?) -> SessionStart? {
                LoginSession.sessionStart(records: records, user: "member", uid: 501, loginWindowLaunch: lw, bootTime: boot)
            }
            XCTAssertEqual(chain(records, lw: loginWindow, boot: boot), SessionStart(date: console, source: .console))
            XCTAssertEqual(chain([], lw: loginWindow, boot: boot), SessionStart(date: loginWindow, source: .loginWindow))
            XCTAssertEqual(chain([], lw: nil, boot: boot), SessionStart(date: boot, source: .boot))
            XCTAssertNil(chain([], lw: nil, boot: nil))
            // A console record older than the boot is a leftover: the next source decides.
            let leftover = [R(isUserProcess: true, line: "console", user: "member", date: Date(timeIntervalSince1970: 500))]
            XCTAssertEqual(chain(leftover, lw: loginWindow, boot: boot), SessionStart(date: loginWindow, source: .loginWindow))
            XCTAssertEqual(chain(leftover, lw: nil, boot: boot), SessionStart(date: boot, source: .boot))
            // Dead process records and other lines do not count.
            let dead = [R(isUserProcess: false, line: "console", user: "member", date: console)]
            XCTAssertEqual(chain(dead, lw: nil, boot: boot)?.source, .boot)
        }

        func testBootTimeIsReadAndPast() throws {
            let booted = try XCTUnwrap(LoginSession.bootTime())
            XCTAssertLessThan(booted, Date())
        }

        func testEveryColdLaunchWritesOneJournalRecord() {
            LaunchPresentation.recordLaunch(origin: .member, eventFlag: "none", sessionStart: start(300, .loginWindow),
                                            quietRelaunchUntil: 0, now: now, shows: true, secondCopy: false)
            LaunchPresentation.recordLaunch(origin: .loginItem, eventFlag: "loginItem", sessionStart: nil,
                                            quietRelaunchUntil: now.timeIntervalSince1970 + 5, now: now, shows: false, secondCopy: true)
            XCTAssertEqual(LaunchOrigin.flagName(of: nil), "none")
            let event = NSAppleEventDescriptor(eventClass: core, eventID: open, targetDescriptor: nil,
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: keyAEPropData)
            XCTAssertEqual(LaunchOrigin.flagName(of: event), "loginItem")
            for key in [SupportKey.launchOrigin, .launchEventFlag, .sessionSource] {
                for word in ["member", "loginItem", "serviceItem", "guardRelaunch", "document", "unknown", "none", "other",
                             "console", "loginWindow", "boot"] {
                    XCTAssertTrue(SupportSymbol.isSafe(word, for: key), "\(key) \(word)")
                }
            }
            for origin in [LaunchOrigin.member, .loginItem, .serviceItem, .guardRelaunch, .document, .unknown] {
                XCTAssertTrue(SupportSymbol.isSafe(origin.journalName, for: .launchOrigin))
            }
        }

        // MARK: R4 / R8 — the quiet marker

        private func suite() -> UserDefaults {
            let name = "goalong-launch-presentation-test-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            addTeardownBlock { defaults.removePersistentDomain(forName: name) }
            return defaults
        }

        /// R4: the second copy asks the same question as the first one: a valid marker = no "show window".
        func testSecondCopyHonorsTheQuietRelaunchMarker() {
            let defaults = suite()
            LaunchPresentation.armQuietRelaunch(defaults: defaults, now: now)
            let until = LaunchPresentation.quietRelaunchUntil(defaults: defaults)
            XCTAssertEqual(until, now.timeIntervalSince1970 + LaunchPresentation.quietRelaunchDuration)
            let session = start(3600)
            XCTAssertFalse(LaunchPresentation.showsDashboardAtLaunch(
                origin: .member, quietRelaunchUntil: until, now: now.addingTimeInterval(2), sessionStart: session))
            // The marker is read, not consumed: both copies see it.
            XCTAssertEqual(LaunchPresentation.quietRelaunchUntil(defaults: defaults), until)
            // Expired: Spotlight shows the window again.
            XCTAssertTrue(LaunchPresentation.showsDashboardAtLaunch(
                origin: .member, quietRelaunchUntil: until, now: now.addingTimeInterval(LaunchPresentation.quietRelaunchDuration),
                sessionStart: session))
        }

        /// R8: Sparkle aborts or the copy quits for another reason: no marker stays behind.
        func testQuietRelaunchMarkerIsClearedOnAbort() {
            let defaults = suite()
            LaunchPresentation.armQuietRelaunch(defaults: defaults, now: Date())
            XCTAssertTrue(LaunchPresentation.quietRelaunchIsActive(
                until: LaunchPresentation.quietRelaunchUntil(defaults: defaults), now: Date()))
            LaunchPresentation.clearQuietRelaunch(defaults: defaults)
            XCTAssertEqual(LaunchPresentation.quietRelaunchUntil(defaults: defaults), 0)
            XCTAssertFalse(LaunchPresentation.quietRelaunchIsActive(until: 0, now: Date()))
            XCTAssertTrue(LaunchPresentation.showsDashboardAtLaunch(
                origin: .member, quietRelaunchUntil: LaunchPresentation.quietRelaunchUntil(defaults: defaults),
                now: now, sessionStart: start(3600)))
        }

        func testLoginItemFlagIsReadAsEnumOrType() {
            let event = NSAppleEventDescriptor(eventClass: core, eventID: open, targetDescriptor: nil,
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: keyAEPropData)
            XCTAssertEqual(LaunchOrigin.current(event, arguments: ["Goalong History"]), .loginItem)
        }

        func testShowRequestIsScopedToTheBundle() {
            XCTAssertNotEqual(LaunchPresentation.showRequestName(bundleIdentifier: "ai.goalong.localhistory"),
                              LaunchPresentation.showRequestName(bundleIdentifier: "ai.goalong.localhistory.dev"))
        }
    }
#endif
