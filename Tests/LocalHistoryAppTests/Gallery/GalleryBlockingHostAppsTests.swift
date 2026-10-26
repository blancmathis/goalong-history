#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// The blocking fixtures never read the host's running apps (T-044 C7-11): with Xcode open on the Mac that renders
/// the gallery, « pret », « blocage-actif » and « mot-de-passe » showed a trigger block; with Xcode closed,
/// « declenche » lost its own. One of the two host states fails without the fixed apps, whichever it is.
@MainActor final class GalleryBlockingHostAppsTests: XCTestCase {
    private func triggerBlocks(_ controller: BlockingController) -> Int {
        controller.refresh()
        return controller.activeBlocks.filter { if case .trigger = $0.origin { return true } else { return false } }.count
    }

    func testFixturesShowTheSameTriggerBlocksWhateverRunsOnTheHost() {
        let F = GalleryFixtures.self
        XCTAssertEqual(triggerBlocks(F.blockingIdle()), 0, "pret")
        XCTAssertEqual(triggerBlocks(F.blockingActive()), 0, "blocage-actif")
        XCTAssertEqual(triggerBlocks(F.blockingGuarded()), 0, "mot-de-passe")
        XCTAssertEqual(triggerBlocks(F.blockingProtected(.running)), 0, "protection")
        XCTAssertEqual(triggerBlocks(F.blockingTriggered()), 1, "declenche")
    }
}
#endif
