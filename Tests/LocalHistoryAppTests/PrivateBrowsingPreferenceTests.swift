#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class PrivateBrowsingPreferenceTests: XCTestCase {
    func testDefaultAndLegacyConfigurationsExcludePrivateWindows() throws {
        XCTAssertTrue(RecorderConfig.default.suppressesPrivateWindow(detected: true))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RecorderConfig.default)) as? [String: Any])
        json.removeValue(forKey: "capturePrivateBrowsing")
        let legacy = try JSONDecoder().decode(RecorderConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.suppressesPrivateWindow(detected: true))
        XCTAssertFalse(legacy.suppressesPrivateWindow(detected: false))
    }

    func testExplicitChoicePersistsAndCanBeTurnedOffWithoutChangingOtherProtections() throws {
        let original = RecorderConfig.default
        var draft = DashboardSettingsDraft(config: original)
        XCTAssertFalse(draft.capturePrivateBrowsing)
        draft.capturePrivateBrowsing = true
        let saved = try JSONDecoder().decode(RecorderConfig.self, from: JSONEncoder().encode(draft.applying(to: original)))
        XCTAssertFalse(saved.suppressesPrivateWindow(detected: true))
        XCTAssertEqual(saved.excludedBundleIdentifiers, original.excludedBundleIdentifiers)
        XCTAssertEqual(saved.excludedDomains, original.excludedDomains)
        XCTAssertEqual(saved.redactAllURLQueryValues, original.redactAllURLQueryValues)
        XCTAssertEqual(saved.captureURLs, original.captureURLs)
        var restored = DashboardSettingsDraft(config: saved)
        restored.capturePrivateBrowsing = false
        XCTAssertTrue(restored.applying(to: saved).suppressesPrivateWindow(detected: true))
    }
}
#endif
