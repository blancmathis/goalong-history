#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp

/// T-062: the first Spotlight launch must open the window; login item, launchd and guard relaunches stay quiet.
final class LaunchWindowIntentTests: XCTestCase {
    private let core = AEEventClass(kCoreEventClass)
    private let openApp = AEEventID(kAEOpenApplication)

    func testPersonLaunchOpensTheWindow() {
        XCTAssertEqual(LaunchWindowIntent.classify(eventClass: core, eventID: openApp, launchedAs: nil,
                                                   isGuardRelaunch: false), .showWindow)
    }

    func testLoginAndServiceItemLaunchesStayQuiet() {
        for launchedAs in [OSType(keyAELaunchedAsLogInItem), OSType(keyAELaunchedAsServiceItem)] {
            XCTAssertEqual(LaunchWindowIntent.classify(eventClass: core, eventID: openApp, launchedAs: launchedAs,
                                                       isGuardRelaunch: false), .quiet)
        }
    }

    func testLaunchWithoutEventStaysQuiet() {
        XCTAssertEqual(LaunchWindowIntent.classify(eventClass: nil, eventID: nil, launchedAs: nil,
                                                   isGuardRelaunch: false), .quiet)
    }

    func testDocumentOrURLLaunchIsLeftToItsHandler() {
        XCTAssertEqual(LaunchWindowIntent.classify(eventClass: core, eventID: AEEventID(kAEOpenDocuments),
                                                   launchedAs: nil, isGuardRelaunch: false), .quiet)
    }

    func testGuardRelaunchStaysQuietEvenFromAnOpenAppEvent() {
        XCTAssertEqual(LaunchWindowIntent.classify(eventClass: core, eventID: openApp, launchedAs: nil,
                                                   isGuardRelaunch: true), .quiet)
    }

    func testShowWindowRequestIsScopedToThisBuildChannel() {
        XCTAssertTrue(LaunchWindowIntent.showWindowNotification.rawValue.hasPrefix(ProductIdentity.bundleIdentifier + "."))
    }

}
#endif
