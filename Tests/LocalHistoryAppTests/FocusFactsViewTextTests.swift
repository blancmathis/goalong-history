#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// ux-popover-04: a short recap never claims the recording was suspended.
final class FocusFactsViewTextTests: XCTestCase {
    func testUnmeasuredTextSeparatesTheThreeCauses() {
        XCTAssertTrue(FocusFactsView.unmeasuredText(FocusFacts(available: false)).contains("suspendu ou lecture indisponible"))
        XCTAssertEqual(FocusFactsView.unmeasuredText(FocusFacts(activeSeconds: 0, available: true)),
                       "Aucune activité mesurée pendant cette séance.")
        let short = FocusFactsView.unmeasuredText(FocusFacts(activeSeconds: 45, available: true))
        XCTAssertEqual(short, "Moins d’une minute d’activité mesurée.")
        XCTAssertFalse(short.contains("suspendu"))
    }
}
#endif
