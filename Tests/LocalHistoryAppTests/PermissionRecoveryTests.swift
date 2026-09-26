#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class PermissionRecoveryTests: XCTestCase {
        private let bundle = URL(fileURLWithPath: "/Applications/Goalong History.app")
        private let launch = Date(timeIntervalSince1970: 1000)
        private var arguments: [String] {
            ["Goalong History", PermissionRecovery.parentArgument, "123",
             PermissionRecovery.parentLaunchArgument, "1000.0"]
        }

        func testOrdinaryLaunchDoesNotWaitOrLookUpAnotherProcess() {
            XCTAssertEqual(PermissionRecovery.parentState(arguments: ["Goalong"], currentPID: 124,
                bundleURL: bundle, lookup: { _ in XCTFail("Unexpected lookup"); return nil }), .notRequested)
        }

        func testRelaunchWaitsOnlyForExactPreviousAppInstance() {
            XCTAssertEqual(PermissionRecovery.parentState(arguments: arguments, currentPID: 124,
                bundleURL: bundle, lookup: { _ in (self.bundle, self.launch) }), .waiting)
            XCTAssertEqual(PermissionRecovery.parentState(arguments: arguments, currentPID: 124,
                bundleURL: bundle, lookup: { _ in nil }), .ready)
        }

        func testRelaunchRejectsUnrelatedApplicationAndReusedPID() {
            XCTAssertEqual(PermissionRecovery.parentState(arguments: arguments, currentPID: 124,
                bundleURL: bundle, lookup: { _ in (URL(fileURLWithPath: "/Applications/Other.app"), self.launch) }), .invalid)
            XCTAssertEqual(PermissionRecovery.parentState(arguments: arguments, currentPID: 124,
                bundleURL: bundle, lookup: { _ in (self.bundle, self.launch.addingTimeInterval(1)) }), .invalid)
            XCTAssertEqual(PermissionRecovery.parentState(arguments: arguments, currentPID: 124,
                bundleURL: bundle, lookup: { _ in (self.bundle, nil) }), .invalid)
        }

        func testRelaunchRejectsMalformedSelfAndSystemProcessIDs() {
            let malformed: [[String]] = [
                [PermissionRecovery.parentArgument],
                [PermissionRecovery.parentArgument, "not-a-pid"],
                [PermissionRecovery.parentArgument, "0", PermissionRecovery.parentLaunchArgument, "1000"],
                [PermissionRecovery.parentArgument, "1", PermissionRecovery.parentLaunchArgument, "1000"],
                [PermissionRecovery.parentArgument, "-1", PermissionRecovery.parentLaunchArgument, "1000"],
                [PermissionRecovery.parentArgument, "124", PermissionRecovery.parentLaunchArgument, "1000"],
                [PermissionRecovery.parentArgument, "123", PermissionRecovery.parentLaunchArgument, "nan"],
            ]
            for args in malformed {
                XCTAssertEqual(PermissionRecovery.parentState(arguments: args, currentPID: 124,
                    bundleURL: bundle, lookup: { _ in XCTFail("Malformed request must not look up a PID"); return nil }), .invalid)
            }
        }

        func testOnlyMacPermissionFailuresOfferPermissionRecovery() {
            for status: SourceAccessStatus in [.accessibility, .inputMonitoring, .fullDiskAccess] {
                XCTAssertTrue(status.isMacPermission)
            }
            for status: SourceAccessStatus in [.ready, .screenTimeSetup, .unavailable("file missing")] {
                XCTAssertFalse(status.isMacPermission)
            }
        }

        func testActivationUsesSharedBoundedNonPromptingPermissionProbe() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/PermissionManager.swift"))
            let block = try XCTUnwrap(source.components(separatedBy: "static func activationStatus()").dropFirst().first)
                .components(separatedBy: "private static func liveStatus()")[0]
            XCTAssertTrue(block.contains("probeStatus(includeFunctionalCheck: false)"))
            let probe = try XCTUnwrap(source.components(separatedBy: "private static func probeStatus").dropFirst().first)
                .components(separatedBy: "@discardableResult")[0]
            XCTAssertTrue(probe.contains("as String: false"))
            XCTAssertTrue(probe.contains("isExternalProbeTarget"))
            XCTAssertTrue(probe.contains("candidates.prefix(2)"))
            XCTAssertTrue(probe.contains("AXUIElementSetMessagingTimeout(app, 0.12)"))
            XCTAssertFalse(probe.contains("kAXTitleAttribute"))
            XCTAssertFalse(probe.contains("CGRequest"))
            XCTAssertFalse(block.contains("canReadFocusedApplication"))
            XCTAssertFalse(block.contains("AXUIElementCopyAttributeValue"))
            XCTAssertFalse(block.contains("CGRequest"))
        }
    }
#endif
