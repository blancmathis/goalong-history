#if os(macOS)
    import Darwin
    import Foundation
    import XCTest

    @testable import LocalHistoryApp

    final class GoalongCLIInstallationTests: XCTestCase {
        func testExactExecutableSymlinkIsReady() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.createSymbolicLink(
                atPath: fixture.link.path,
                withDestinationPath: fixture.executable.path
            )

            let report = GoalongCLIInstallation.inspect(
                linkURL: fixture.link,
                expectedExecutableURL: fixture.executable
            )

            XCTAssertEqual(report.state, .ready)
            XCTAssertEqual(report.resolvedTargetPath, fixture.executable.path)
        }

        func testMissingLinkIsReportedClearly() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let report = GoalongCLIInstallation.inspect(
                linkURL: fixture.link,
                expectedExecutableURL: fixture.executable
            )

            XCTAssertEqual(report.state, .missing)
            XCTAssertNil(report.resolvedTargetPath)
        }

        func testUnrelatedExecutableAndRegularFileAreConflicts() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let unrelated = fixture.root.appendingPathComponent("Other", isDirectory: false)
            try Data("other".utf8).write(to: unrelated)
            XCTAssertEqual(Darwin.chmod(unrelated.path, 0o700), 0)
            try FileManager.default.createSymbolicLink(
                atPath: fixture.link.path,
                withDestinationPath: unrelated.path
            )

            XCTAssertEqual(
                GoalongCLIInstallation.inspect(
                    linkURL: fixture.link,
                    expectedExecutableURL: fixture.executable
                ).state,
                .conflict
            )

            try FileManager.default.removeItem(at: fixture.link)
            try Data("do not replace".utf8).write(to: fixture.link)
            XCTAssertEqual(
                GoalongCLIInstallation.inspect(
                    linkURL: fixture.link,
                    expectedExecutableURL: fixture.executable
                ).state,
                .conflict
            )
        }

        func testGoalongDevNeverReportsTheInstalledCommandAsAConflict() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            // ~/.local/bin/goalong points to the installed Goalong, not to the running Goalong Dev.
            let installed = fixture.root.appendingPathComponent("Installed", isDirectory: false)
            try Data("installed".utf8).write(to: installed)
            XCTAssertEqual(Darwin.chmod(installed.path, 0o700), 0)
            try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: installed.path)

            let report = GoalongCLIInstallation.inspect(
                linkURL: fixture.link,
                expectedExecutableURL: fixture.executable,
                isDevelopment: true
            )

            XCTAssertEqual(report.state, .development)
            XCTAssertEqual(report.resolvedTargetPath, installed.standardizedFileURL.resolvingSymlinksInPath().path)
            XCTAssertEqual(
                report.developmentCLIPath,
                fixture.executable.deletingLastPathComponent().appendingPathComponent("goalong").path
            )
            XCTAssertTrue(report.detail.contains("Goalong installé"))
            XCTAssertTrue(report.detail.contains("Ne réinstallez pas"))
            // The link is only read, never rewritten.
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path), installed.path)

            try FileManager.default.removeItem(at: fixture.link)
            let missing = GoalongCLIInstallation.inspect(
                linkURL: fixture.link,
                expectedExecutableURL: fixture.executable,
                isDevelopment: true
            )
            XCTAssertEqual(missing.state, .development)
            XCTAssertNil(missing.resolvedTargetPath)
        }

        private func makeFixture() throws -> (root: URL, executable: URL, link: URL) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("goalong-cli-installation-\(UUID().uuidString)", isDirectory: true)
            let app = root.appendingPathComponent("App", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = app.appendingPathComponent("Goalong History", isDirectory: false)
            try Data("fixture".utf8).write(to: executable)
            XCTAssertEqual(Darwin.chmod(executable.path, 0o700), 0)
            return (
                root,
                executable,
                bin.appendingPathComponent("goalong", isDirectory: false)
            )
        }
    }
#endif
