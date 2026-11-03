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

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-resolver-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(_ url: URL, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// R10/R11 O18: a directory named like the command, listed before the real binary, is skipped (the shell skips it).
    func testDirectoryWithTheCommandNameIsSkippedInPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let decoy = root.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy.appendingPathComponent("goalong", isDirectory: true), withIntermediateDirectories: true)
        let real = root.appendingPathComponent("bin/goalong")
        try makeExecutable(real)
        let found = GoalongCLIExecutableResolver.resolve(
            argv0: "goalong", path: "\(decoy.path):\(real.deletingLastPathComponent().path)", currentDirectory: root.path)
        XCTAssertEqual(found?.path, real.path)
    }

    /// A non-executable file before the real binary is skipped.
    func testNonExecutableFileIsSkippedInPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain/goalong")
        try makeExecutable(plain, mode: 0o644)
        let real = root.appendingPathComponent("bin/goalong")
        try makeExecutable(real)
        let found = GoalongCLIExecutableResolver.resolve(
            argv0: "goalong", path: "\(plain.deletingLastPathComponent().path):\(real.deletingLastPathComponent().path)", currentDirectory: root.path)
        XCTAssertEqual(found?.path, real.path)
    }

    /// R10/R11 O18: PATH absent means the default search path (/usr/bin:/bin, as execvp), not the working directory.
    func testMissingPathDoesNotSearchTheWorkingDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(root.appendingPathComponent("goalong-r12a-only-here"))
        XCTAssertNil(GoalongCLIExecutableResolver.resolve(
            argv0: "goalong-r12a-only-here", path: nil, currentDirectory: root.path))
    }

    /// An empty PATH entry still means the working directory (POSIX), when PATH is set.
    func testEmptyPathEntryMeansTheWorkingDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("goalong")
        try makeExecutable(local)
        XCTAssertEqual(GoalongCLIExecutableResolver.resolve(
            argv0: "goalong", path: "", currentDirectory: root.path)?.path, local.path)
        XCTAssertEqual(GoalongCLIExecutableResolver.resolve(
            argv0: "goalong", path: "/nonexistent-r12a:", currentDirectory: root.path)?.path, local.path)
    }

    /// R12a tour 2, O18 point 3: the kernel path wins over a misleading argv[0] and PATH.
    func testKernelPathWinsOverArgv0AndPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("App.app/Contents/MacOS/Goalong History")
        try makeExecutable(real)
        let decoy = root.appendingPathComponent("bin/goalong")
        try makeExecutable(decoy)
        let found = GoalongCLIExecutableResolver.resolve(
            kernelPath: real.path, argv0: "goalong", path: decoy.deletingLastPathComponent().path, currentDirectory: root.path)
        XCTAssertEqual(found?.path, real.path)
    }

    /// An unusable kernel path (missing file) falls back to argv[0]/PATH.
    func testUnusableKernelPathFallsBackToArgv0() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let decoy = root.appendingPathComponent("bin/goalong")
        try makeExecutable(decoy)
        XCTAssertEqual(GoalongCLIExecutableResolver.resolve(
            kernelPath: root.appendingPathComponent("missing").path, argv0: "goalong",
            path: decoy.deletingLastPathComponent().path, currentDirectory: root.path)?.path, decoy.path)
        XCTAssertEqual(GoalongCLIExecutableResolver.resolve(
            kernelPath: nil, argv0: "goalong",
            path: decoy.deletingLastPathComponent().path, currentDirectory: root.path)?.path, decoy.path)
    }

    /// The real kernel call returns the running test binary, a regular file.
    func testKernelExecutablePathIsTheRunningBinary() throws {
        let path = try XCTUnwrap(GoalongCLIExecutableResolver.kernelExecutablePath())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        XCTAssertTrue(path.hasPrefix("/"))
    }
}
