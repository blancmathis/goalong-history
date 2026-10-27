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
            // The page already says « Commande absente » and the banner title says what to do:
            // the detail must not repeat that the link is missing.
            XCTAssertFalse(report.detail.contains("absent"))
        }

        // C14-01: the DMG and Sparkle never create the link. The page says so and gives the exact line,
        // built from the running app's path, and that line really creates a working link.
        func testMissingLinkGivesTheExactTerminalCommandThatCreatesIt() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let link = fixture.root.appendingPathComponent("new bin/goalong", isDirectory: false)

            let report = GoalongCLIInstallation.inspect(linkURL: link, expectedExecutableURL: fixture.executable)

            XCTAssertEqual(report.state, .missing)
            XCTAssertTrue(report.detail.contains("(DMG)"))
            XCTAssertTrue(report.detail.contains("Sparkle ne créent pas"))
            XCTAssertFalse(report.detail.contains("recrée"))
            let command = try XCTUnwrap(report.linkCommand)
            XCTAssertEqual(
                command,
                "mkdir -p '\(link.deletingLastPathComponent().path)' && ln -s '\(fixture.executable.path)' '\(link.path)'")
            XCTAssertEqual(GoalongCLIInstallation.shellQuoted("it's"), "'it'\\''s'")

            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", command]
            try shell.run()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, 0)
            XCTAssertEqual(
                GoalongCLIInstallation.inspect(linkURL: link, expectedExecutableURL: fixture.executable).state, .ready)
            XCTAssertNil(
                GoalongCLIInstallation.inspect(linkURL: link, expectedExecutableURL: fixture.executable).linkCommand)
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

        // C14-01: « Installer la commande » creates the folder and the link, with no administrator rights.
        func testInstallCreatesTheFolderAndALinkToThisApp() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let link = fixture.root.appendingPathComponent("home/.local/bin/goalong", isDirectory: false)
            XCTAssertTrue(GoalongCLIInstallation.inspect(linkURL: link, expectedExecutableURL: fixture.executable, isDevelopment: false).canInstall)

            let outcome = GoalongCLIInstallation.install(linkURL: link, executableURL: fixture.executable, directoryOnPath: { _ in true })

            XCTAssertTrue(outcome.succeeded, outcome.message)
            XCTAssertTrue(outcome.message.hasPrefix("Commande installée"))
            XCTAssertTrue(outcome.message.contains("goalong status"))
            let report = GoalongCLIInstallation.inspect(linkURL: link, expectedExecutableURL: fixture.executable, isDevelopment: false)
            XCTAssertEqual(report.state, .ready)
            XCTAssertFalse(report.canInstall)
            let again = GoalongCLIInstallation.install(linkURL: link, executableURL: fixture.executable, directoryOnPath: { _ in true })
            XCTAssertTrue(again.succeeded); XCTAssertTrue(again.message.contains("déjà installée"))
        }

        func testInstallNeverReplacesAForeignFileOrLink() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try Data("mine".utf8).write(to: fixture.link)
            let file = GoalongCLIInstallation.install(linkURL: fixture.link, executableURL: fixture.executable, directoryOnPath: { _ in true })
            XCTAssertFalse(file.succeeded); XCTAssertTrue(file.message.contains("ne le remplace jamais"))
            XCTAssertEqual(try Data(contentsOf: fixture.link), Data("mine".utf8))
            XCTAssertFalse(GoalongCLIInstallation.inspect(linkURL: fixture.link, expectedExecutableURL: fixture.executable, isDevelopment: false).canInstall)

            try FileManager.default.removeItem(at: fixture.link)
            try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: "/usr/local/bin/other-goalong")
            let foreign = GoalongCLIInstallation.install(linkURL: fixture.link, executableURL: fixture.executable, directoryOnPath: { _ in true })
            XCTAssertFalse(foreign.succeeded); XCTAssertTrue(foreign.message.contains("autre programme"))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path), "/usr/local/bin/other-goalong")
            XCTAssertFalse(GoalongCLIInstallation.inspect(linkURL: fixture.link, expectedExecutableURL: fixture.executable, isDevelopment: false).canInstall)
        }

        func testInstallRepairsALinkToAnOldOrDeletedGoalongApp() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let old = fixture.root.appendingPathComponent("Old/Goalong History.app/Contents/MacOS/Goalong History").path
            try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: old)
            let before = GoalongCLIInstallation.inspect(linkURL: fixture.link, expectedExecutableURL: fixture.executable, isDevelopment: false)
            XCTAssertEqual(before.state, .conflict); XCTAssertTrue(before.canInstall)

            let outcome = GoalongCLIInstallation.install(linkURL: fixture.link, executableURL: fixture.executable, directoryOnPath: { _ in true })

            XCTAssertTrue(outcome.succeeded, outcome.message); XCTAssertTrue(outcome.message.hasPrefix("Commande réparée"))
            XCTAssertEqual(GoalongCLIInstallation.inspect(linkURL: fixture.link, expectedExecutableURL: fixture.executable, isDevelopment: false).state, .ready)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.link.deletingLastPathComponent().path)
            XCTAssertEqual(leftovers, ["goalong"])
        }

        func testInstallSaysWhenTheFolderIsNotOnThePath() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let outcome = GoalongCLIInstallation.install(linkURL: fixture.link, executableURL: fixture.executable, directoryOnPath: { _ in false })
            XCTAssertTrue(outcome.succeeded)
            XCTAssertTrue(outcome.message.contains("n’est pas dans le PATH"))
            XCTAssertTrue(outcome.message.contains("export PATH=\"$HOME/.local/bin:$PATH\""))
        }

        func testInstallRefusesABinFolderThatIsAFile() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let blocker = fixture.root.appendingPathComponent("blocker", isDirectory: false)
            try Data("x".utf8).write(to: blocker)
            let outcome = GoalongCLIInstallation.install(linkURL: blocker.appendingPathComponent("goalong"), executableURL: fixture.executable,
                                                         directoryOnPath: { _ in true })
            XCTAssertFalse(outcome.succeeded); XCTAssertTrue(outcome.message.contains("n’a pas été installée"))
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
