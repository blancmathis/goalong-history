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
                [ProductIdentity.displayName, "Fichier", "Édition", "Présentation", "Fenêtre", "Aide"]
            )

            let applicationMenu = try XCTUnwrap(controller.mainMenu.items.first?.submenu)
            let titles = applicationMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            XCTAssertEqual(
                titles,
                [
                    "À propos de \(ProductIdentity.displayName)",
                    "Rechercher les mises à jour…",
                    "Réglages…",
                    "Services",
                    "Masquer \(ProductIdentity.displayName)",
                    "Masquer les autres",
                    "Tout afficher",
                    "Quitter et rouvrir \(ProductIdentity.displayName)",
                    "Quitter \(ProductIdentity.displayName)",
                ]
            )
            XCTAssertEqual(applicationMenu.item(withTitle: "Réglages…")?.keyEquivalent, ",")
            XCTAssertEqual(applicationMenu.item(withTitle: "Quitter et rouvrir \(ProductIdentity.displayName)")?.keyEquivalent, "")
            XCTAssertEqual(
                applicationMenu.item(withTitle: "Quitter \(ProductIdentity.displayName)")?.keyEquivalent,
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
            let updateItem = try XCTUnwrap(applicationMenu.item(withTitle: "Rechercher les mises à jour…"))

            controller.menuNeedsUpdate(applicationMenu)
            XCTAssertFalse(updateItem.isEnabled)

            canCheck = true
            controller.menuNeedsUpdate(applicationMenu)
            XCTAssertTrue(updateItem.isEnabled)
        }
    }
#endif
