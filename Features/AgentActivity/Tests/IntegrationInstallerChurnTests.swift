import Darwin
import Foundation
import XCTest

@testable import AgentActivity

final class IntegrationInstallerChurnTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testInstallReplacesExcessiveGoalongHooksWithBoundedHintsAndPreservesThirdPartyHooks() throws {
        let home = try makeTemporaryDirectory("bounded-hooks")
        let executable = home.appendingPathComponent("Goalong History")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)

        try writeJSON(
            [
                "keep": "codex-setting",
                "hooks": [
                    "UserPromptSubmit": [
                        nestedHook("echo codex-third-party"),
                        nestedHook("/old/goalong --agent-hook-ingest codex UserPromptSubmit"),
                    ],
                    "PreToolUse": [nestedHook("/old/goalong --agent-hook-ingest codex PreToolUse")],
                    "PostCompact": [nestedHook("/old/goalong --agent-hook-ingest codex PostCompact")],
                    "Stop": [
                        [
                            "matcher": "third-party",
                            "hooks": [
                                ["type": "command", "command": "echo codex-stop-third-party"],
                                ["type": "command", "command": "/old/goalong --agent-hook-ingest codex Stop"],
                            ],
                        ]
                    ],
                ],
            ], to: installer.configurationURL(for: .codexHooks))

        try writeJSON(
            [
                "keep": "claude-setting",
                "hooks": [
                    "Notification": [
                        nestedHook("echo claude-third-party"),
                        nestedHook("/old/goalong --agent-hook-ingest claudeCode Notification"),
                    ],
                    "PostToolUse": [nestedHook("/old/goalong --agent-hook-ingest claudeCode PostToolUse")],
                    "FileChanged": [nestedHook("/old/goalong --agent-hook-ingest claudeCode FileChanged")],
                    "PostCompact": [nestedHook("/old/goalong --agent-hook-ingest claudeCode PostCompact")],
                ],
            ], to: installer.configurationURL(for: .claudeCodeHooks))

        try writeJSON(
            [
                "version": 1,
                "keep": "cursor-setting",
                "hooks": [
                    "workspaceOpen": [
                        ["command": "echo cursor-third-party"],
                        ["command": "/old/goalong --agent-hook-ingest cursor workspaceOpen"],
                    ],
                    "afterFileEdit": [
                        ["command": "echo cursor-edit-third-party"],
                        ["command": "/old/goalong --agent-hook-ingest cursor afterFileEdit"],
                    ],
                    "postToolUse": [["command": "/old/goalong --agent-hook-ingest cursor postToolUse"]],
                ],
            ], to: installer.configurationURL(for: .cursorHooks))

        for kind in [
            AgentIntegrationKind.codexHooks,
            .claudeCodeHooks,
            .cursorHooks,
        ] {
            try installer.install(kind)
            try installer.install(kind)
            XCTAssertEqual(
                try regularBackupCount(for: installer.configurationURL(for: kind)),
                1,
                "An unchanged reinstall must not create another backup"
            )
        }

        let codex = try readJSON(installer.configurationURL(for: .codexHooks))
        XCTAssertEqual(codex["keep"] as? String, "codex-setting")
        let codexHooks = try XCTUnwrap(codex["hooks"] as? [String: Any])
        XCTAssertEqual(
            goalongHookCounts(codexHooks),
            ["PreCompact": 1, "Stop": 1, "SessionEnd": 1]
        )
        XCTAssertTrue(containsCommand(codexHooks, "echo codex-third-party"))
        XCTAssertTrue(containsCommand(codexHooks, "echo codex-stop-third-party"))
        XCTAssertFalse(containsCommand(codexHooks, "/old/goalong"))
        XCTAssertNil(codexHooks["PreToolUse"])
        XCTAssertNil(codexHooks["PostCompact"])
        XCTAssertNil(codexHooks["PostToolUse"])

        let claude = try readJSON(installer.configurationURL(for: .claudeCodeHooks))
        XCTAssertEqual(claude["keep"] as? String, "claude-setting")
        let claudeHooks = try XCTUnwrap(claude["hooks"] as? [String: Any])
        XCTAssertEqual(
            goalongHookCounts(claudeHooks),
            ["PreCompact": 1, "Stop": 1, "SessionEnd": 1]
        )
        XCTAssertTrue(containsCommand(claudeHooks, "echo claude-third-party"))
        XCTAssertFalse(containsCommand(claudeHooks, "/old/goalong"))
        XCTAssertNil(claudeHooks["FileChanged"])
        XCTAssertNil(claudeHooks["PostCompact"])
        XCTAssertNil(claudeHooks["PostToolUse"])

        let cursor = try readJSON(installer.configurationURL(for: .cursorHooks))
        XCTAssertEqual(cursor["keep"] as? String, "cursor-setting")
        let cursorHooks = try XCTUnwrap(cursor["hooks"] as? [String: Any])
        XCTAssertEqual(
            goalongHookCounts(cursorHooks),
            ["preCompact": 1, "stop": 1, "sessionEnd": 1]
        )
        XCTAssertTrue(containsCommand(cursorHooks, "echo cursor-third-party"))
        XCTAssertTrue(containsCommand(cursorHooks, "echo cursor-edit-third-party"))
        XCTAssertFalse(containsCommand(cursorHooks, "/old/goalong"))
        XCTAssertNil(cursorHooks["postToolUse"])
    }

    func testOpenCodePluginFiltersAndCoalescesHintsWithoutAwaitingOrSendingPayloads() throws {
        let home = try makeTemporaryDirectory("opencode-coalescing")
        let executable = home.appendingPathComponent("Goalong History")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)
        let pluginURL = installer.configurationURL(for: .openCodePlugin)
        try FileManager.default.createDirectory(
            at: pluginURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            """
            // goalong-history-agent-hook-v1
            // Legacy managed plugin: every event serialized its payload and awaited a child.
            const legacy = async (event, payload) => {
              JSON.stringify(payload)
              const child = Bun.spawn({ cmd: [event] })
              await child.exited
            }
            """.utf8
        ).write(to: pluginURL)

        try installer.install(.openCodePlugin)
        try installer.install(.openCodePlugin)
        XCTAssertEqual(
            try regularBackupCount(for: pluginURL),
            1,
            "An unchanged generated plugin must not create backup churn"
        )
        let source = try String(
            contentsOf: pluginURL,
            encoding: .utf8
        )

        for event in ["session.idle", "session.compacted", "session.deleted"] {
            XCTAssertEqual(occurrences(of: "\"\(event)\"", in: source), 1)
        }
        for noisyEvent in [
            "message.updated", "session.updated", "session.created", "file.edited",
            "file.watcher.updated", "command.executed",
        ] {
            XCTAssertFalse(source.contains(noisyEvent))
        }

        XCTAssertEqual(occurrences(of: "Bun.spawn", in: source), 1)
        XCTAssertTrue(source.contains("GOALONG_DEBOUNCE_MS = 1000"))
        XCTAssertTrue(source.contains("GOALONG_CHILD_TIMEOUT_MS = 3000"))
        XCTAssertTrue(source.contains("if (childInFlight) return"))
        XCTAssertTrue(source.contains("clearTimeout(debounceTimer)"))
        XCTAssertTrue(source.contains("setTimeout(flushGoalongHistorySignal"))
        XCTAssertTrue(source.contains("child.kill()"))
        XCTAssertTrue(source.contains("clearTimeout(childTimeout)"))
        XCTAssertTrue(source.contains("Promise.resolve(child.exited)"))
        XCTAssertTrue(source.contains("childInFlight = false"))
        XCTAssertTrue(source.contains(#"stdin: "ignore""#))

        XCTAssertFalse(source.contains("await child.exited"))
        XCTAssertFalse(source.contains("event: async"))
        XCTAssertFalse(source.contains("await scheduleGoalongHistorySignal"))
        XCTAssertFalse(source.contains("JSON.stringify"))
        XCTAssertFalse(source.contains("child.stdin"))
        XCTAssertFalse(source.contains(#"stdin: "pipe""#))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("payload"))
        XCTAssertFalse(source.contains("setInterval"))
        XCTAssertFalse(source.contains("while ("))
    }

    func testOversizedConfigurationsAreRejectedBeforeParsingOrBackup() throws {
        let home = try makeTemporaryDirectory("oversized")
        let executable = home.appendingPathComponent("Goalong History")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)

        for kind in [AgentIntegrationKind.codexHooks, .openCodePlugin] {
            let url = installer.configurationURL(for: kind)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let oversized = Data(
                repeating: 0x78,
                count: Int(AgentIntegrationInstaller.maximumConfigurationBytes) + 1
            )
            try oversized.write(to: url)

            XCTAssertFalse(installer.status(for: kind).isInstalled)
            XCTAssertThrowsError(try installer.install(kind)) { error in
                guard
                    case AgentIntegrationInstallerError.configurationTooLarge(
                        let
                            rejectedURL,
                        let
                            actualBytes,
                        let
                            maximumBytes
                    ) = error
                else {
                    return XCTFail("Expected a bounded-read rejection, got \(error)")
                }
                XCTAssertEqual(rejectedURL.standardizedFileURL, url.standardizedFileURL)
                XCTAssertEqual(actualBytes, Int64(oversized.count))
                XCTAssertEqual(maximumBytes, AgentIntegrationInstaller.maximumConfigurationBytes)
            }
            XCTAssertEqual(try regularBackupCount(for: url), 0)
            XCTAssertEqual(try fileSize(url), Int64(oversized.count))
        }
    }

    func testConfigurationSymlinksAreNeverFollowedOrModified() throws {
        let home = try makeTemporaryDirectory("symlink")
        let executable = home.appendingPathComponent("Goalong History")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)
        let target = home.appendingPathComponent("do-not-touch.json")
        let sentinel = Data(
            """
            {"hooks":{},"marker":"goalong-history-agent-hook-v1 --agent-hook-ingest"}
            """.utf8
        )
        try sentinel.write(to: target)

        for kind in [AgentIntegrationKind.claudeCodeHooks, .openCodePlugin] {
            let url = installer.configurationURL(for: kind)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

            XCTAssertFalse(installer.status(for: kind).isInstalled)
            XCTAssertThrowsError(try installer.install(kind)) { error in
                guard case AgentIntegrationInstallerError.unsafeConfiguration(let rejectedURL) = error
                else {
                    return XCTFail("Expected a symlink rejection, got \(error)")
                }
                XCTAssertEqual(rejectedURL.standardizedFileURL, url.standardizedFileURL)
            }
            XCTAssertEqual(try Data(contentsOf: target), sentinel)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
            XCTAssertEqual(try regularBackupCount(for: url), 0)
        }
    }

    func testBackupRotationKeepsThreePrivateBackupsAndIgnoresBackupSymlinks() throws {
        let home = try makeTemporaryDirectory("backup-rotation")
        let executable = home.appendingPathComponent("Goalong History")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)
        let configurationURL = installer.configurationURL(for: .codexHooks)
        let parent = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let sentinel = home.appendingPathComponent("backup-symlink-target")
        let sentinelData = Data("private target".utf8)
        try sentinelData.write(to: sentinel)
        let symlink = parent.appendingPathComponent(
            configurationURL.lastPathComponent + ".goalong-backup-0000000000000-AAAAAAAA"
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sentinel)

        for revision in 0..<8 {
            try writeJSON(
                ["revision": revision, "hooks": [String: Any]()],
                to: configurationURL
            )
            try installer.install(.codexHooks)
            XCTAssertLessThanOrEqual(
                try regularBackupCount(for: configurationURL),
                AgentIntegrationInstaller.maximumManagedBackupsPerConfiguration
            )
        }

        let namesBeforeIdempotentInstall = try regularBackupNames(for: configurationURL)
        XCTAssertEqual(
            namesBeforeIdempotentInstall.count,
            AgentIntegrationInstaller.maximumManagedBackupsPerConfiguration
        )
        try installer.install(.codexHooks)
        XCTAssertEqual(try regularBackupNames(for: configurationURL), namesBeforeIdempotentInstall)

        for backup in try regularBackupURLs(for: configurationURL) {
            var status = stat()
            XCTAssertEqual(backup.path.withCString { lstat($0, &status) }, 0)
            XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
            XCTAssertLessThanOrEqual(
                status.st_size,
                AgentIntegrationInstaller.maximumConfigurationBytes
            )
        }
        XCTAssertEqual(
            try permissions(of: configurationURL),
            mode_t(0o600),
            "The active provider configuration must stay private"
        )
        XCTAssertEqual(
            try permissions(of: parent),
            mode_t(0o700),
            "The provider configuration directory must stay private"
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), sentinel.path)
    }

    func testUnreadableAndNonRegularConfigurationsAreRejectedWithoutCreatingBackups() throws {
        let home = try makeTemporaryDirectory("unsafe-configurations")
        let executable = home.appendingPathComponent("Goalong History")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)

        let unreadableURL = installer.configurationURL(for: .cursorHooks)
        try FileManager.default.createDirectory(
            at: unreadableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"hooks":{}}"#.utf8).write(to: unreadableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadableURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadableURL.path
            )
        }

        XCTAssertFalse(installer.status(for: .cursorHooks).isInstalled)
        XCTAssertThrowsError(try installer.install(.cursorHooks)) { error in
            guard case AgentIntegrationInstallerError.configurationUnavailable(let rejectedURL) = error
            else {
                return XCTFail("Expected an unreadable configuration rejection, got \(error)")
            }
            XCTAssertEqual(rejectedURL.standardizedFileURL, unreadableURL.standardizedFileURL)
        }
        XCTAssertEqual(try regularBackupCount(for: unreadableURL), 0)

        let directoryURL = installer.configurationURL(for: .codexHooks)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        XCTAssertFalse(installer.status(for: .codexHooks).isInstalled)
        XCTAssertThrowsError(try installer.install(.codexHooks)) { error in
            guard case AgentIntegrationInstallerError.unsafeConfiguration(let rejectedURL) = error
            else {
                return XCTFail("Expected a non-regular configuration rejection, got \(error)")
            }
            XCTAssertEqual(rejectedURL.standardizedFileURL, directoryURL.standardizedFileURL)
        }
        XCTAssertEqual(try regularBackupCount(for: directoryURL), 0)
    }

    func testOpenCodeUninstallIsIdempotentAndKeepsPrivateBoundedBackups() throws {
        let home = try makeTemporaryDirectory("idempotent-uninstall")
        let executable = home.appendingPathComponent("Goalong History")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)
        let pluginURL = installer.configurationURL(for: .openCodePlugin)

        try installer.install(.openCodePlugin)
        try installer.uninstall(.openCodePlugin)
        try installer.uninstall(.openCodePlugin)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        let backups = try regularBackupURLs(for: pluginURL)
        XCTAssertLessThanOrEqual(
            backups.count,
            AgentIntegrationInstaller.maximumManagedBackupsPerConfiguration
        )
        XCTAssertEqual(backups.count, 1)
        for backup in backups {
            XCTAssertEqual(try permissions(of: backup), mode_t(0o600))
            XCTAssertLessThanOrEqual(
                try fileSize(backup),
                AgentIntegrationInstaller.maximumConfigurationBytes
            )
        }
    }

    private func nestedHook(_ command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command]]]
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func goalongHookCounts(_ hooks: [String: Any]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (event, value) in hooks {
            guard let definitions = value as? [[String: Any]] else { continue }
            let count = definitions.reduce(into: 0) { count, definition in
                if let command = definition["command"] as? String,
                    command.contains("--agent-hook-ingest")
                {
                    count += 1
                }
                if let nested = definition["hooks"] as? [[String: Any]] {
                    count += nested.filter { recursivelyContains($0, "--agent-hook-ingest") }.count
                }
            }
            if count > 0 { result[event] = count }
        }
        return result
    }

    private func containsCommand(_ hooks: [String: Any], _ fragment: String) -> Bool {
        recursivelyContains(hooks, fragment)
    }

    private func recursivelyContains(_ value: Any, _ fragment: String) -> Bool {
        if let string = value as? String { return string.contains(fragment) }
        if let values = value as? [Any] {
            return values.contains { recursivelyContains($0, fragment) }
        }
        if let values = value as? [String: Any] {
            return values.values.contains { recursivelyContains($0, fragment) }
        }
        return false
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private func regularBackupCount(for configurationURL: URL) throws -> Int {
        try regularBackupURLs(for: configurationURL).count
    }

    private func regularBackupNames(for configurationURL: URL) throws -> [String] {
        try regularBackupURLs(for: configurationURL).map(\.lastPathComponent).sorted()
    }

    private func regularBackupURLs(for configurationURL: URL) throws -> [URL] {
        let prefix = configurationURL.lastPathComponent + ".goalong-backup-"
        return try FileManager.default.contentsOfDirectory(
            at: configurationURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { url in
            guard url.lastPathComponent.hasPrefix(prefix) else { return false }
            var status = stat()
            return url.path.withCString { lstat($0, &status) } == 0
                && status.st_mode & S_IFMT == S_IFREG
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int64(status.st_size)
    }

    private func permissions(of url: URL) throws -> mode_t {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return status.st_mode & mode_t(0o777)
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationInstallerChurnTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
