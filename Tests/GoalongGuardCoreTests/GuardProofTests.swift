import Darwin
import Foundation
import Security
import XCTest
@testable import GoalongGuardCore

/// L1L2-01: a perso lease proof must be a genuine, running, correctly signed process at exactly the proof path.
final class GuardProofTests: XCTestCase {
    private var root: URL!
    private var spawned: [Process] = []
    /// Pins the genuine test binary (ad hoc, so its cdhash stands in for "signed like this guard").
    private var genuine = ""

    override func setUpWithError() throws {
        root = GuardSystem.realPath(FileManager.default.temporaryDirectory)
            .appendingPathComponent("guard-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reference = try build("reference", seconds: 30)
        genuine = "cdhash H\"\(try cdhash(reference))\""
    }

    override func tearDownWithError() throws {
        for process in spawned where process.isRunning {
            kill(process.processIdentifier, SIGCONT); process.terminate(); process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// A tiny sleeper compiled here (a copied system binary is killed by macOS outside its folder).
    private func build(_ name: String, seconds: Int, identifier: String = "ai.goalong.proof-test") throws -> String {
        let source = root.appendingPathComponent("\(name).c")
        try "#include <unistd.h>\nint main(void) { sleep(\(seconds)); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent(name).path
        try run("/usr/bin/cc", ["-o", path, source.path])
        try run("/usr/bin/codesign", ["-f", "-s", "-", "-i", identifier, path])
        return path
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }

    private func cdhash(_ path: String) throws -> String {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(code), [], &info), errSecSuccess)
        let unique = try XCTUnwrap((info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The genuine binary, copied byte for byte to `name`.
    private func copyGenuine(_ name: String) throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.copyItem(atPath: root.appendingPathComponent("reference").path, toPath: path)
        return path
    }

    @discardableResult
    private func spawn(_ path: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["30"]
        try process.run()
        spawned.append(process)
        let deadline = Date().addingTimeInterval(3)
        while GuardProcesses.path(of: process.processIdentifier) == nil, Date() < deadline { usleep(10_000) }
        return process.processIdentifier
    }

    func testGenuineSignedProcessAtTheExactPathIsAProof() throws {
        let path = try copyGenuine("proof")
        let pid = try spawn(path)
        XCTAssertEqual(GuardProof.authenticPids(executable: path, requirement: genuine), [pid])
    }

    func testForgedSignatureIsNotAProof() throws {
        // Any user can drop and sign their own program at the stage path: valid code, wrong signer.
        let path = try build("forged", seconds: 31)
        try spawn(path)
        XCTAssertFalse(GuardProcesses.pids(executable: path).isEmpty, "the forged process runs at the path")
        XCTAssertEqual(GuardProof.authenticPids(executable: path, requirement: genuine), [])
    }

    func testSymlinkAtTheProofPathIsNotAProof() throws {
        let target = try copyGenuine("elsewhere")
        let link = root.appendingPathComponent("proof-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let pid = try spawn(link)
        XCTAssertEqual(GuardProcesses.path(of: pid), target, "genuine code, but it does not run from the proof path")
        XCTAssertEqual(GuardProof.authenticPids(executable: link, requirement: genuine), [])
    }

    func testStoppedProcessIsNotAProof() throws {
        let path = try copyGenuine("stopped")
        let pid = try spawn(path)
        kill(pid, SIGSTOP)
        let deadline = Date().addingTimeInterval(3)
        while !GuardProcesses.isStopped(pid), Date() < deadline { usleep(10_000) }
        XCTAssertEqual(GuardProof.authenticPids(executable: path, requirement: genuine), [])
        kill(pid, SIGCONT)
    }

    func testUnparsableRequirementProvesNothing() throws {
        let path = try copyGenuine("bad-req")
        try spawn(path)
        XCTAssertEqual(GuardProof.authenticPids(executable: path, requirement: "not a requirement ((("), [])
    }

    // F1: a binary of the same signer but another identifier (another product of the team, a long CLI) copied to
    // the proof path is not the relauncher. `always` stands in for the team clause (the test code is ad hoc).
    func testSameSignerWithAnotherIdentifierIsNotAProof() throws {
        let requirement = try XCTUnwrap(GuardProof.relauncherRequirement(signer: "always",
                                                                         guardIdentifier: "ai.goalong.proof-test.blocking-guard"))
        let other = try build("other-tool", seconds: 32, identifier: "ai.goalong.proof-test.menubar")
        try spawn(other)
        XCTAssertFalse(GuardProcesses.pids(executable: other).isEmpty, "the other tool runs at the path")
        XCTAssertEqual(GuardProof.authenticPids(executable: other, requirement: requirement), [])
        let relauncher = try build("relauncher", seconds: 33, identifier: "ai.goalong.proof-test.relauncher")
        let pid = try spawn(relauncher)
        XCTAssertEqual(GuardProof.authenticPids(executable: relauncher, requirement: requirement), [pid])
    }

    func testRelauncherRequirementFailsClosedOnAnUnexpectedGuardIdentifier() {
        XCTAssertNil(GuardProof.relauncherRequirement(signer: "always", guardIdentifier: "ai.goalong.localhistory"))
        XCTAssertNil(GuardProof.relauncherRequirement(signer: "always", guardIdentifier: ".blocking-guard"))
        XCTAssertNil(GuardProof.relauncherRequirement(signer: "always", guardIdentifier: "a\" or always or \"b.blocking-guard"))
        XCTAssertEqual(GuardProof.relauncherRequirement(signer: "always", guardIdentifier: "ai.goalong.localhistory.dev.blocking-guard"),
                       "(always) and identifier \"ai.goalong.localhistory.dev.relauncher\"")
    }
}
