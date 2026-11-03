import Foundation
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongCLIExecutableResolverTests: XCTestCase {
    func testBareNameResolvesThroughPathAndSymlinkToBundleExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-resolver-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("App.app/Contents/MacOS", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        for dir in [macOS, bin, elsewhere] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let real = macOS.appendingPathComponent("Goalong History")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("goalong"), withDestinationURL: real)

        let byName = GoalongCLIExecutableResolver.resolve(
            argv0: "goalong", path: "\(elsewhere.path):\(bin.path)", currentDirectory: elsewhere.path)
        XCTAssertEqual(byName?.path, real.path)

        let bySlash = GoalongCLIExecutableResolver.resolve(
            argv0: bin.appendingPathComponent("goalong").path, path: "", currentDirectory: elsewhere.path)
        XCTAssertEqual(bySlash?.path, real.path)

        let relative = GoalongCLIExecutableResolver.resolve(
            argv0: "../bin/goalong", path: "", currentDirectory: elsewhere.path)
        XCTAssertEqual(relative?.path, real.path)

        XCTAssertNil(GoalongCLIExecutableResolver.resolve(
            argv0: "goalong", path: elsewhere.path, currentDirectory: elsewhere.path))
    }
}
