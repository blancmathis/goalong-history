#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// Scriptable tree: no cross-process RPC, and every requested attribute is visible.
final class ScriptedAXTree {
    let window = AXUIElementCreateApplication(50_001)
    let focus = AXUIElementCreateApplication(50_002)
    let app = AXUIElementCreateApplication(50_003)
    let system = AXUIElementCreateApplication(50_004)
    var attributes: [Int: [String: CFTypeRef]] = [:]
    var errors: [String: AXError] = [:]
    private let readLock = NSLock()
    private var readLog: [String] = []
    var reads: [String] {
        get { readLock.lock(); defer { readLock.unlock() }; return readLog }
        set { readLock.lock(); readLog = newValue; readLock.unlock() }
    }
    var beforeRead: ((String) -> Void)?
    lazy var client: AXClient = {
        let value = AXClient(read: { [unowned self] node, attribute in
            let name = attribute as String
            self.beforeRead?(name)
            self.readLock.lock(); self.readLog.append(name); self.readLock.unlock()
            if let error = self.errors[name] { return AXReadResult(error: error, value: nil) }
            let value = self.attributes[Int(CFHash(node))]?[name]
            return AXReadResult(error: value == nil ? .attributeUnsupported : .success, value: value)
        })
        value.application = { [unowned self] _ in self.app }
        value.systemWide = { [unowned self] in self.system }
        value.setTimeout = { _, _ in .success }
        value.getPID = { _, pointer in pointer.pointee = 42; return .success }
        value.hitTest = { [unowned self] _, _, _, pointer in pointer.pointee = self.focus; return .success }
        return value
    }()
    init(secure: Bool = false, browser: Bool = false) {
        attributes[Int(CFHash(app))] = ["AXFocusedWindow": window, "AXFocusedUIElement": focus]
        attributes[Int(CFHash(system))] = ["AXFocusedApplication": app]
        attributes[Int(CFHash(window))] = ["AXTitle": "Document" as CFString,
            "AXRole": "AXWindow" as CFString, "AXChildren": [focus] as CFArray]
        if browser { attributes[Int(CFHash(window))]?["AXDocument"] = "https://example.com/work" as CFString }
        attributes[Int(CFHash(focus))] = ["AXRole": "AXTextField" as CFString,
            "AXSubrole": (secure ? "AXSecureTextField" : "AXTextField") as CFString,
            "AXTitle": "Name" as CFString, "AXDescription": "Editor" as CFString,
            "AXIdentifier": "editor" as CFString, "AXValue": "Never keyboard text" as CFString]
    }
}

final class AXCaptureParityTests: XCTestCase {
    func testBaselinePublicFieldsAndHitTestAreExact() {
        let tree = ScriptedAXTree(browser: true)
        var config = RecorderConfig.default
        config.captureWindowTitles = true
        config.captureElementLabels = true
        AXAccess.withClient(tree.client) {
            XCTAssertEqual(AXReader.windowSnapshot(tree.window, config: config),
                           WindowSnapshot(title: "Document", role: "AXWindow", subrole: nil))
            XCTAssertEqual(AXReader.elementSnapshot(tree.focus, config: config),
                           ElementSnapshot(role: "AXTextField", subrole: "AXTextField", title: "Name",
                                           label: "Editor", identifier: "editor", isSecure: false))
            XCTAssertEqual(AXReader.browserURL(from: tree.window, addressFieldMarkers: []), "https://example.com/work")
            XCTAssertTrue(CFEqual(AXReader.actionableElement(at: .zero), tree.focus))
            XCTAssertEqual(AXReader.focusedApplicationProcessIdentifier(), 42)
        }
        XCTAssertFalse(tree.reads.contains("AXValue"))
        XCTAssertFalse(tree.reads.contains("AXSelectedText"))
    }

    func testSecureSubroleReadsNoContentEvenWithoutProtectionAttribute() {
        let tree = ScriptedAXTree(secure: true)
        var config = RecorderConfig.default
        config.captureElementLabels = true
        AXAccess.withClient(tree.client) {
            let snapshot = AXReader.elementSnapshot(tree.focus, config: config)
            XCTAssertTrue(snapshot.isSecure)
            XCTAssertNil(snapshot.title); XCTAssertNil(snapshot.label); XCTAssertNil(snapshot.identifier)
            XCTAssertTrue(AXReader.isSecureElement(tree.focus))
        }
        XCTAssertTrue(Set(tree.reads).isSubset(of: ["AXRole", "AXSubrole", "AXProtectedContent"]))
    }

    func testAXErrorsRemainTypedAtClientBoundaryAndProduceNoStaleValue() {
        let tree = ScriptedAXTree()
        for error in [AXError.attributeUnsupported, .noValue, .invalidUIElement, .apiDisabled, .cannotComplete] {
            tree.errors["AXTitle"] = error
            AXAccess.withClient(tree.client) {
                var value: CFTypeRef? = "old" as CFString
                XCTAssertEqual(AXAccess.copyAttributeValue(tree.window, "AXTitle" as CFString, &value), error)
                XCTAssertNil(value)
                XCTAssertNil(AXReader.string(tree.window, attribute: "AXTitle" as CFString))
            }
        }
    }

    func testMetricsContainOnlyOpaqueIDsOperationAndDurationAndScopeIsRestored() {
        var tick: TimeInterval = 0
        var metrics: [AXOperationMetric] = []
        let clock = AXCaptureClock(date: { Date(timeIntervalSince1970: 42) }, uptime: { tick += 1; return tick }, identifier: { "request-1" })
        let client = AXClient(clock: clock, metric: { metrics.append($0) }, read: { _, _ in AXReadResult(error: .noValue, value: nil) })
        AXAccess.withClient(client, requestID: clock.identifier()) {
            XCTAssertNil(AXReader.string(AXUIElementCreateApplication(50_001), attribute: "AXTitle" as CFString))
        }
        XCTAssertTrue(AXAccess.client === AXClient.system)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].requestID, "request-1")
        XCTAssertEqual(metrics[0].operation, "attribute")
        XCTAssertEqual(metrics[0].duration, 1)
        XCTAssertEqual(metrics[0].error, AXError.noValue.rawValue)
        let result = client.measure(.execution, requestID: "request-1") { 42 }
        client.measure(.publication, requestID: "request-1") {}
        XCTAssertEqual(result, 42)
        XCTAssertEqual(metrics.map(\.stage), [.rpc, .execution, .publication])
        XCTAssertEqual(metrics.map(\.duration), [1, 1, 1])
    }
}
#endif
