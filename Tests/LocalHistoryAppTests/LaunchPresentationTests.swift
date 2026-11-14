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

        private func shows(_ origin: LaunchOrigin, quiet: Double = 0, uptime: TimeInterval = 3600,
                           login: Date? = Date(timeIntervalSince1970: 1_000)) -> Bool {
            LaunchPresentation.showsDashboardAtLaunch(origin: origin, quietRelaunchUntil: quiet, now: now,
                                                      systemUptime: uptime, sessionLogin: login)
        }

        func testOnlyAMemberOpenOutsideBootAndUpdateShowsTheWindow() {
            XCTAssertTrue(shows(.member))
            for other in [LaunchOrigin.loginItem, .serviceItem, .guardRelaunch, .document, .unknown] {
                XCTAssertFalse(shows(other), "\(other)")
            }
            // Sparkle's relaunch: quiet marker still valid.
            XCTAssertFalse(shows(.member, quiet: now.timeIntervalSince1970 + 60))
            XCTAssertTrue(shows(.member, quiet: now.timeIntervalSince1970 - 1))
            // Session restore right after boot.
            XCTAssertFalse(shows(.member, uptime: 30))
        }

        /// Decision 2026-11-14: logout then login without reboot. Uptime is long; the login item's event may
        /// lack the login-item flag (SMAppService). The new session's age keeps the window closed.
        func testLoginItemAfterLogoutWithoutRebootStaysQuiet() {
            let justLoggedIn = now.addingTimeInterval(-20)
            XCTAssertFalse(shows(.member, uptime: 4 * 86_400, login: justLoggedIn))
            XCTAssertFalse(shows(.loginItem, uptime: 4 * 86_400, login: now.addingTimeInterval(-3600)))
            XCTAssertFalse(LaunchPresentation.isClearMemberOpen(origin: .member, now: now, systemUptime: 4 * 86_400,
                                                                sessionLogin: justLoggedIn))
            // Unknown login time: not a clear member's open.
            XCTAssertFalse(shows(.member, login: nil))
            // Same session, minutes later: Spotlight shows the window.
            XCTAssertTrue(shows(.member, uptime: 4 * 86_400,
                                login: now.addingTimeInterval(-LaunchPresentation.sessionQuietPeriod)))
        }

        func testConsoleLoginIsTheLatestUserConsoleRecord() {
            typealias R = LoginSession.Record
            let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 900)
            let records = [
                R(isUserProcess: true, line: "console", user: "member", date: old),
                R(isUserProcess: true, line: "console", user: "member", date: new),
                R(isUserProcess: true, line: "ttys000", user: "member", date: Date(timeIntervalSince1970: 950)),
                R(isUserProcess: true, line: "console", user: "other", date: Date(timeIntervalSince1970: 990)),
                R(isUserProcess: false, line: "console", user: "member", date: Date(timeIntervalSince1970: 999)),
            ]
            XCTAssertEqual(LoginSession.latestConsoleLogin(records, user: "member"), new)
            XCTAssertNil(LoginSession.latestConsoleLogin(records, user: "nobody"))
            // Live read (no console session on a CI runner): never in the future.
            if let live = LoginSession.consoleLoginDate() { XCTAssertLessThanOrEqual(live, Date()) }
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
