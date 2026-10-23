#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class SettingsHomeIconsTests: XCTestCase {
    func testSettingsPanesUseDistinctSymbols() {
        let panes = SettingsPane.primary + [.advanced]
        let symbols = panes.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertNotEqual(SettingsPane.advanced.symbol, "slider.horizontal.3")
        XCTAssertNotEqual(SettingsPane.recording.symbol, SettingsPane.storage.symbol)
    }

    func testPermissionRowsShareTheSourceSymbols() {
        for capability in [GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations] {
            XCTAssertFalse(PermissionSetupCopy(capability: capability, status: .ready).symbol.isEmpty)
        }
        XCTAssertEqual(PermissionSetupCopy(capability: .appleScreenTime, status: .ready).symbol, "chart.bar.xaxis")
    }
}
#endif
