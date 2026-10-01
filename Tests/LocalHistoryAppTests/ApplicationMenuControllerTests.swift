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

        func testViewMenuNavigatesToEachPrimaryDestinationWithCommandDigits() throws {
            var opened: [DashboardSection] = []
            let controller = ApplicationMenuController(
                onOpenSettings: {}, onNavigate: { opened.append($0) },
                onCheckForUpdates: {}, canCheckForUpdates: { true }, onQuit: {}
            )
            let view = try XCTUnwrap(controller.mainMenu.items.first { $0.submenu?.title == "Présentation" }?.submenu)
            let entries = view.items.filter { $0.representedObject is String }
            XCTAssertEqual(entries.map(\.title), ["Activité", "Mon travail", "Historique", "Surveillance temps réel"])
            XCTAssertEqual(entries.map(\.keyEquivalent), ["1", "2", "3", "4"])
            for entry in entries {
                _ = (entry.target as? NSObject)?.perform(entry.action, with: entry)
            }
            XCTAssertEqual(opened, [.overview, .work, .history, .monitoring])
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
