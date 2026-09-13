#if os(macOS)
import Foundation
import XCTest
@testable import AppleSystemScreenTime

final class ScreenTimeActivationAccessTests: XCTestCase {
    func testReadableSourceRemainsAvailableWhenOptionalAppleStoreIsDenied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let readable = root.appendingPathComponent("readable.db")
        let denied = root.appendingPathComponent("private.db")
        let missing = root.appendingPathComponent("missing")
        try Data().write(to: readable)
        try Data().write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        for pair in [(readable, denied), (denied, readable)] {
            let source = AppleSystemScreenTimeSource(deviceID: "test", paths: AppleSystemScreenTimePaths(
                knowledgeDatabase: pair.0, biomeSyncDatabase: pair.1,
                biomeLocalDirectory: missing, biomeRemoteDirectory: missing, appleAccountDeviceDatabase: missing))
            XCTAssertEqual(source.activationAccess(), .available)
            XCTAssertNotEqual(source.collect(for: Date()).status.kind, .fullDiskAccessRequired)
            XCTAssertEqual(source.makeStatus(hasData: false, permissionDenied: true,
                remoteDeviceCount: 0, warnings: []).kind, .partial)
        }
    }

    func testPreflightDistinguishesMissingReadableDeniedAndSymlinkWithoutCollecting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("knowledge.db")
        let missing = root.appendingPathComponent("missing")
        let source = AppleSystemScreenTimeSource(deviceID: "test", paths: AppleSystemScreenTimePaths(
            knowledgeDatabase: sourceFile, biomeSyncDatabase: missing,
            biomeLocalDirectory: missing, biomeRemoteDirectory: missing, appleAccountDeviceDatabase: missing))
        XCTAssertEqual(source.activationAccess(), .noData)
        let bytes = Data("not a database: access check must not parse it".utf8)
        try bytes.write(to: sourceFile)
        XCTAssertEqual(source.activationAccess(), .available)
        XCTAssertEqual(try Data(contentsOf: sourceFile), bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourceFile.path)
        XCTAssertEqual(source.activationAccess(), .permissionRequired)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceFile.path)
        try FileManager.default.removeItem(at: sourceFile)
        try FileManager.default.createSymbolicLink(at: sourceFile, withDestinationURL: missing)
        XCTAssertEqual(source.activationAccess(), .unavailable)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["knowledge.db"])
    }
}
#endif
