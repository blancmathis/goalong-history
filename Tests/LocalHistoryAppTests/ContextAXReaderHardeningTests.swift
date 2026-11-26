#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-057 L3: an AX failure never turns into an allowed page.
final class ContextAXReaderHardeningTests: XCTestCase {
    private func blockingParameters() -> ContextReadParameters {
        let app = ForegroundAXApplication(pid: 42, name: "Safari", bundleIdentifier: "com.apple.Safari")
        return ContextReadParameters(foregroundApplication: app, applications: [42: app], config: .default,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true, idleSeconds: 1,
            privacy: GoalongPrivacyPolicy(), pauseRevision: "initial")
    }

    private func safariIsInternal(_ tree: ScriptedAXTree) -> Bool? {
        AXAccess.withClient(tree.client) { ContextAXReader().captureBlocking(parameters: blockingParameters()) }?.isInternalPage
    }

    /// Witness: a Safari window without address whose whole tree reads cleanly and holds no web area
    /// (empty start page) stays an internal page.
    func testSafariProvenEmptyStartPageIsInternal() {
        XCTAssertEqual(safariIsInternal(ScriptedAXTree()), true)
    }

    /// blocage-02: an AX error on the tree walk is "unknown", never "internal page".
    func testSafariReadErrorIsNotAnInternalPage() {
        for attribute in ["AXChildren", "AXRole"] {
            for error in [AXError.cannotComplete, .failure, .invalidUIElement] {
                let tree = ScriptedAXTree(); tree.errors[attribute] = error
                XCTAssertEqual(safariIsInternal(tree), false, "\(attribute) \(error.rawValue)")
            }
        }
    }

    /// blocage-02: a tree larger than the walk limit (220 nodes) is "unknown", never "internal page".
    func testSafariTruncatedWalkIsNotAnInternalPage() {
        let tree = ScriptedAXTree()
        let nodes = (0..<300).map { AXUIElementCreateApplication(60_000 + Int32($0)) }
        for node in nodes { tree.attributes[Int(CFHash(node))] = ["AXRole": "AXGroup" as CFString] }
        tree.attributes[Int(CFHash(tree.window))]?["AXChildren"] = nodes as CFArray
        XCTAssertEqual(safariIsInternal(tree), false)
        XCTAssertNil(AXAccess.withClient(tree.client) { AXReader.webAreaPresence(tree.window) })
        let clean = ScriptedAXTree()
        XCTAssertEqual(AXAccess.withClient(clean.client) { AXReader.webAreaPresence(clean.window) }, false)
    }

    private func historyParameters(excluded: [String] = [], included: [String]? = nil) -> ContextReadParameters {
        var config = RecorderConfig.default
        config.captureWindowTitles = true; config.captureElementLabels = true; config.captureURLs = true
        config.excludedBundleIdentifiers = []; config.excludedDomains = excluded; config.includedDomains = included
        var privacy = GoalongPrivacyPolicy(); privacy.revision = "none"
        let app = ForegroundAXApplication(pid: 42, name: "Safari", bundleIdentifier: "com.apple.Safari")
        return ContextReadParameters(foregroundApplication: app, applications: [42: app], config: config,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true,
            idleSeconds: 1, privacy: privacy, pauseRevision: "initial")
    }

    /// capture-01: same window, new excluded page and title 0.2 s after an allowed capture, no input.
    /// The title must not be recorded under the cached allowed address.
    func testNewTitleIsNotKeptUnderCachedAllowedAddress() {
        for (input, label) in [(historyParameters(excluded: ["exclu.test"]), "exclusion"),
                               (historyParameters(included: ["public.test"]), "include-only")] {
            var now = Date(timeIntervalSince1970: 1_791_158_400)
            let reader = ContextAXReader(clock: AXCaptureClock(date: { now }))
            let tree = ScriptedAXTree(browser: true)
            tree.attributes[Int(CFHash(tree.window))]?["AXDocument"] = "https://public.test/page" as CFString
            let first = AXAccess.withClient(tree.client) { reader.capture(parameters: input) }
            XCTAssertEqual(first.snapshot?.url?.host, "public.test", label)
            tree.attributes[Int(CFHash(tree.window))]?["AXDocument"] = "https://exclu.test/x" as CFString
            tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "SECRET_EXCLU" as CFString
            now = now.addingTimeInterval(0.2)
            let second = AXAccess.withClient(tree.client) { reader.capture(parameters: input) }
            XCTAssertEqual(second.snapshot?.suppressionReason, .excludedDomain, label)
            XCTAssertNil(second.snapshot?.window?.title, label)
        }
    }
}
#endif
