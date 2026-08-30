#if os(macOS)
    import AppKit
    import XCTest
    @testable import LocalHistoryApp

    final class ApplicationMenuControllerTests: XCTestCase {
        func testMainMenuExposesStandardMacApplicationControls() throws {
            let controller = ApplicationMenuController(
                onOpenSettings: {},
                onCheckForUpdates: {},
                canCheckForUpdates: { true },
                onQuit: {}
            )

            XCTAssertEqual(
                controller.mainMenu.items.compactMap(\.submenu?.title),
                [ProductIdentity.displayName, "File", "Edit", "View", "Window"]
            )

            let applicationMenu = try XCTUnwrap(controller.mainMenu.items.first?.submenu)
            let titles = applicationMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            XCTAssertEqual(
                titles,
                [
                    "About \(ProductIdentity.displayName)",
                    "Check for Updates…",
                    "Settings…",
                    "Services",
                    "Hide \(ProductIdentity.displayName)",
                    "Hide Others",
                    "Show All",
                    "Quit \(ProductIdentity.displayName)",
                ]
            )
            XCTAssertEqual(applicationMenu.item(withTitle: "Settings…")?.keyEquivalent, ",")
            XCTAssertEqual(
                applicationMenu.item(withTitle: "Quit \(ProductIdentity.displayName)")?.keyEquivalent,
                "q"
            )
        }

        func testUpdateItemTracksWhetherTheInstalledBuildCanCheck() throws {
            var canCheck = false
            let controller = ApplicationMenuController(
                onOpenSettings: {},
                onCheckForUpdates: {},
                canCheckForUpdates: { canCheck },
                onQuit: {}
            )
            let applicationMenu = try XCTUnwrap(controller.mainMenu.items.first?.submenu)
            let updateItem = try XCTUnwrap(applicationMenu.item(withTitle: "Check for Updates…"))

            controller.menuNeedsUpdate(applicationMenu)
            XCTAssertFalse(updateItem.isEnabled)

            canCheck = true
            controller.menuNeedsUpdate(applicationMenu)
            XCTAssertTrue(updateItem.isEnabled)
        }
    }
#endif
