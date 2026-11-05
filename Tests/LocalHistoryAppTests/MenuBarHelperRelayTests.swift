#if os(macOS)
import AppKit
import GoalongMenuBarRelay
import XCTest
@testable import LocalHistoryApp

/// T-048 C4: the helper that carries the icon while Control Centre parks Goalong's own item.
/// Nothing here opens an app, a window, or posts a distributed notification.
final class MenuBarHelperRelayTests: XCTestCase {
    private let state = MenuBarRelay.State(image: Data([1, 2, 3]), title: "12:30", toolTip: "Goalong", help: "Ouvre le panneau",
                                           development: true)

    func testEveryMessageRoundTripsAsAPropertyList() throws {
        let messages: [MenuBarRelay.Message] = [.ready, .quit, .state(state),
                                                .click(menu: true, frame: CGRect(x: 1211, y: 1084, width: 38, height: 33)),
                                                .placed(frame: CGRect(x: 7, y: -7, width: 24, height: 24))]
        for message in messages {
            // Distributed notifications carry property-list values only.
            XCTAssertTrue(PropertyListSerialization.propertyList(message.userInfo, isValidFor: .binary), "\(message)")
            let data = try PropertyListSerialization.data(fromPropertyList: message.userInfo, format: .binary, options: 0)
            let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [AnyHashable: Any]
            XCTAssertEqual(MenuBarRelay.Message(userInfo: decoded), message)
        }
    }

    func testDecoderRefusesMalformedOrOversizedPayloads() {
        XCTAssertNil(MenuBarRelay.Message(userInfo: nil))
        XCTAssertNil(MenuBarRelay.Message(userInfo: ["kind": "launch"]))
        XCTAssertNil(MenuBarRelay.Message(userInfo: ["kind": "click", "menu": true, "frame": [1.0, 2.0, 3.0]]))
        XCTAssertNil(MenuBarRelay.Message(userInfo: ["kind": "placed", "frame": [1.0, 2.0, -3.0, 4.0]]))
        XCTAssertNil(MenuBarRelay.Message(userInfo: ["kind": "placed", "frame": [Double.nan, 2.0, 3.0, 4.0]]))
        var big = state
        big.image = Data(count: 512 * 1024 + 1)
        XCTAssertNil(MenuBarRelay.Message(userInfo: MenuBarRelay.Message.state(big).userInfo))
        var long = state
        long.title = String(repeating: "x", count: 100)
        guard case let .state(trimmed)? = MenuBarRelay.Message(userInfo: MenuBarRelay.Message.state(long).userInfo) else {
            return XCTFail("a long title is trimmed, not refused")
        }
        XCTAssertEqual(trimmed.title.count, 40)
    }

    func testLaunchArgumentsAreStrict() {
        let token = UUID().uuidString
        let launch = MenuBarRelay.Launch(hostPID: 4242, token: token, itemName: "goalong-status")
        XCTAssertEqual(launch.arguments, ["--host-pid", "4242", "--token", token, "--item", "goalong-status"])
        XCTAssertEqual(MenuBarRelay.Launch(arguments: launch.arguments), launch)
        XCTAssertNil(MenuBarRelay.Launch(arguments: ["--host-pid", "1", "--token", token, "--item", "goalong-status"]))
        XCTAssertNil(MenuBarRelay.Launch(arguments: ["--host-pid", "4242", "--token", "x", "--item", "goalong-status"]))
        XCTAssertNil(MenuBarRelay.Launch(arguments: ["--host-pid", "4242", "--token", token, "--item", "a b"]))
        XCTAssertNil(MenuBarRelay.Launch(arguments: ["--host-pid", "4242", "--token", token, "--item", "goalong-status", "--x"]))
    }

    func testHelperSitsInsideItsHostAppAndCarriesItsOwnID() {
        let app = URL(fileURLWithPath: "/Applications/Goalong History.app")
        let helper = MenuBarRelay.helperURL(inApp: app)
        XCTAssertEqual(helper.path, "/Applications/Goalong History.app/Contents/Helpers/Goalong Menu Bar.app")
        XCTAssertEqual(MenuBarRelay.hostAppURL(ofHelper: helper)?.path, app.path)
        XCTAssertNil(MenuBarRelay.hostAppURL(ofHelper: URL(fileURLWithPath: "/tmp/Goalong Menu Bar.app")))
        XCTAssertNil(MenuBarRelay.hostAppURL(ofHelper: URL(fileURLWithPath: "/Applications/X.app/Contents/MacOS/Goalong Menu Bar.app")))
        XCTAssertEqual(MenuBarRelay.helperBundleID(host: "ai.goalong.localhistory"), "ai.goalong.localhistory.menubar")
        XCTAssertEqual(MenuBarRelay.helperBundleID(host: "ai.goalong.localhistory.dev"), "ai.goalong.localhistory.dev.menubar")
        XCTAssertNotEqual(MenuBarRelay.toHelper(host: "ai.goalong.localhistory"), MenuBarRelay.toHelper(host: "ai.goalong.localhistory.dev"))
    }

    @MainActor func testHostOpensOnlyANestedHelperWithTheMatchingID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Goalong History.app")
        let contents = MenuBarRelay.helperURL(inApp: app).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "ai.goalong.localhistory.menubar", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertNotNil(MenuBarHelperHost.helperURL(appURL: app, hostID: "ai.goalong.localhistory"))
        XCTAssertNil(MenuBarHelperHost.helperURL(appURL: app, hostID: "ai.goalong.localhistory.dev"), "dev must not open the release helper")
        XCTAssertNil(MenuBarHelperHost.helperURL(appURL: app, hostID: "com.example.other"))
        XCTAssertNil(MenuBarHelperHost.helperURL(appURL: root.appendingPathComponent("Missing.app"), hostID: "ai.goalong.localhistory"))
    }

    @MainActor func testMissingHelperIsLoggedOnceAndNeverRetried() {
        let host = MenuBarHelperHost(hostID: "ai.goalong.localhistory",
                                     appURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Goalong History.app"))
        host.appItemConfirmed(.parkedBySystem)
        XCTAssertEqual(host.launches, MenuBarHelperHost.maxLaunches)
        XCTAssertFalse(host.isHosting)
        host.appItemConfirmed(.underNotch)
        host.appItemConfirmed(nil)
        XCTAssertFalse(host.isHosting)
    }

    func testHostLogLineNamesWhoShowsTheIcon() {
        XCTAssertEqual(MenuBarHelperHost.hostLogLine("helper", state: .shown, frame: CGRect(x: 1211, y: 1084, width: 38, height: 33),
                                                     item: "goalong-status", bundleID: "ai.goalong.localhistory.menubar"),
                       "icon-host=helper state=shown frame=1211,1084,38,33 item=goalong-status bid=ai.goalong.localhistory.menubar")
        XCTAssertEqual(MenuBarHelperHost.hostLogLine("none", item: "", bundleID: "ai.goalong.localhistory.menubar", reason: "helper-missing"),
                       "icon-host=none item=? bid=ai.goalong.localhistory.menubar reason=helper-missing")
    }

    @MainActor func testWatchHandsConfirmedStateToTheHelperAndHidesTheBannerWhileItShowsTheIcon() {
        let watch = MenuBarVisibilityWatch()
        var told: [MenuBarItemVisibility?] = []
        watch.onConfirmed = { told.append($0) }
        watch.record(.parkedBySystem, frame: .zero)
        watch.record(.parkedBySystem, frame: .zero)
        XCTAssertEqual(told, [nil, .parkedBySystem])
        XCTAssertEqual(watch.banner, .parkedBySystem)
        watch.helperShowsIcon = true
        XCTAssertNil(watch.banner, "the helper carries the icon: no banner")
        watch.record(.unknown, frame: .zero)
        XCTAssertEqual(told.count, 2, ".unknown tells nothing")
        watch.record(.underNotch, frame: .zero); watch.record(.underNotch, frame: .zero)
        XCTAssertEqual(watch.banner, .underNotch, "the helper does not hide a notch problem")
        watch.helperShowsIcon = false
        watch.record(.shown, frame: .zero)
        XCTAssertEqual(told.last, .some(nil))
        XCTAssertNil(watch.banner)
    }
}
#endif
