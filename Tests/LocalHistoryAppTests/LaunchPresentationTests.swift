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

        func testOnlyAMemberOpenOutsideBootAndUpdateShowsTheWindow() {
            XCTAssertTrue(LaunchPresentation.showsDashboardAtLaunch(
                origin: .member, quietRelaunchUntil: 0, now: now, systemUptime: 3600))
            for other in [LaunchOrigin.loginItem, .serviceItem, .guardRelaunch, .document, .unknown] {
                XCTAssertFalse(LaunchPresentation.showsDashboardAtLaunch(
                    origin: other, quietRelaunchUntil: 0, now: now, systemUptime: 3600), "\(other)")
            }
            // Sparkle's relaunch: quiet marker still valid.
            XCTAssertFalse(LaunchPresentation.showsDashboardAtLaunch(
                origin: .member, quietRelaunchUntil: now.timeIntervalSince1970 + 60, now: now, systemUptime: 3600))
            XCTAssertTrue(LaunchPresentation.showsDashboardAtLaunch(
                origin: .member, quietRelaunchUntil: now.timeIntervalSince1970 - 1, now: now, systemUptime: 3600))
            // Session restore right after boot.
            XCTAssertFalse(LaunchPresentation.showsDashboardAtLaunch(
                origin: .member, quietRelaunchUntil: 0, now: now, systemUptime: 30))
        }

        func testShowRequestIsScopedToTheBundle() {
            XCTAssertNotEqual(LaunchPresentation.showRequestName(bundleIdentifier: "ai.goalong.localhistory"),
                              LaunchPresentation.showRequestName(bundleIdentifier: "ai.goalong.localhistory.dev"))
        }
    }
#endif
