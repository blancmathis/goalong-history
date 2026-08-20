import Foundation
import XCTest

@testable import AgentActivity

final class AgentActivityTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testParserExtractsConversationAndToolMetadata() throws {
        let text = """
            {"session_id":"session-42","timestamp":"2026-08-19T10:00:00Z","role":"user","content":"Fix the authentication race","cwd":"/tmp/project","model":"gpt-5.6"}
            {"timestamp":"2026-08-19T10:00:02Z","role":"assistant","content":"I will inspect the repository."}
            {"timestamp":"2026-08-19T10:00:04Z","type":"tool_use","tool_name":"shell","command":"swift test","file_path":"Sources/Auth.swift"}
            {"timestamp":"2026-08-19T10:00:08Z","type":"tool_result","status":"failed","error":"one test failed"}
            """
        let summary = AgentTranscriptParser.parse(
            data: Data(text.utf8),
            fileURL: URL(fileURLWithPath: "/tmp/session.jsonl"),
            provider: .codex
        )

        XCTAssertEqual(summary.format, .jsonLines)
        XCTAssertEqual(summary.sessionID, "session-42")
        XCTAssertEqual(summary.messageCount, 2)
        XCTAssertEqual(summary.userMessageCount, 1)
        XCTAssertEqual(summary.assistantMessageCount, 1)
        XCTAssertGreaterThanOrEqual(summary.toolCallCount, 1)
        XCTAssertGreaterThanOrEqual(summary.errorCount, 1)
        XCTAssertTrue(summary.models.contains("gpt-5.6"))
        XCTAssertTrue(summary.tools.contains("shell"))
        XCTAssertTrue(summary.touchedFiles.contains("Sources/Auth.swift"))
        XCTAssertTrue(summary.commands.contains("swift test"))
    }

    func testConfigurationValidationDropsEmptyAndDuplicatePaths() throws {
        let source = try makeTemporaryDirectory("configuration-source")
        let first = AgentWatchedFolder(
            displayName: "First",
            path: source.path,
            provider: .codex
        )
        let duplicate = AgentWatchedFolder(
            displayName: "Duplicate",
            path: source.appendingPathComponent("..").appendingPathComponent(source.lastPathComponent).path,
            provider: .claudeCode
        )
        let empty = AgentWatchedFolder(
            displayName: "Empty",
            path: "   ",
            provider: .custom
        )

        let validated = AgentActivityConfiguration(
            watchedFolders: [empty, first, duplicate],
            scanIntervalSeconds: 1,
            maximumFileBytes: 1,
            maximumDeltaDepth: 500
        ).validated()

        XCTAssertEqual(validated.watchedFolders.count, 1)
        XCTAssertEqual(validated.watchedFolders.first?.id, first.id)
        XCTAssertEqual(validated.scanIntervalSeconds, 3)
        XCTAssertEqual(validated.maximumFileBytes, 64 * 1_024)
        XCTAssertEqual(validated.maximumDeltaDepth, 100)
    }

    func testStorePreservesAppendOnlyVersionsAsDeltasAndReconstructsThem() throws {
        let root = try makeTemporaryDirectory("store")
        let source = try makeTemporaryDirectory("source")
        let transcript = source.appendingPathComponent("history.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"First\"}\n".utf8).write(to: transcript)

        let store = try AgentActivityStore(rootDirectory: root)
        let folder = AgentWatchedFolder(
            displayName: "Test Codex",
            path: source.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])

        let first = try XCTUnwrap(
            store.capture(
                fileURL: transcript,
                relativePath: "history.jsonl",
                folder: folder,
                configuration: configuration
            ))
        XCTAssertEqual(first.storageKind, .full)
        XCTAssertTrue(store.verifies(captureID: first.id))

        let finalText = """
            {"role":"user","content":"First"}
            {"role":"assistant","content":"Second"}

            """
        try Data(finalText.utf8).write(to: transcript)
        let second = try XCTUnwrap(
            store.capture(
                fileURL: transcript,
                relativePath: "history.jsonl",
                folder: folder,
                configuration: configuration
            ))

        XCTAssertEqual(second.storageKind, .appendDelta)
        XCTAssertEqual(second.baseCaptureID, first.id)
        XCTAssertLessThan(second.storedByteCount, second.byteCount)
        XCTAssertEqual(try store.reconstructedData(for: second.id), Data(finalText.utf8))
        XCTAssertTrue(store.verifies(captureID: second.id))
        XCTAssertTrue(store.manifestChainIsValid())
    }

    func testOverviewCountsConversationGrowthOnceAcrossVersions() throws {
        let root = try makeTemporaryDirectory("overview-store")
        let source = try makeTemporaryDirectory("overview-source")
        let transcript = source.appendingPathComponent("session.jsonl")
        let folder = AgentWatchedFolder(
            displayName: "Codex",
            path: source.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(rootDirectory: root)

        try Data("{\"role\":\"user\",\"content\":\"First\"}\n".utf8).write(to: transcript)
        XCTAssertNotNil(
            try store.capture(
                fileURL: transcript,
                relativePath: "session.jsonl",
                folder: folder,
                configuration: configuration
            ))

        let expandedTranscript =
            "{\"role\":\"user\",\"content\":\"First\"}\n"
            + "{\"role\":\"assistant\",\"content\":\"Second\"}\n"
        try Data(expandedTranscript.utf8).write(to: transcript)
        XCTAssertNotNil(
            try store.capture(
                fileURL: transcript,
                relativePath: "session.jsonl",
                folder: folder,
                configuration: configuration
            ))

        let overview = store.overview(for: Date())
        XCTAssertEqual(overview.messageCount, 2)
        XCTAssertEqual(overview.sessionCount, 1)
    }

    func testManifestValidationDetectsEditedCaptureMetadata() throws {
        let root = try makeTemporaryDirectory("manifest-store")
        let source = try makeTemporaryDirectory("manifest-source")
        let transcript = source.appendingPathComponent("history.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"Hello\"}\n".utf8).write(to: transcript)

        let folder = AgentWatchedFolder(
            displayName: "Original name",
            path: source.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(rootDirectory: root)
        XCTAssertNotNil(
            try store.capture(
                fileURL: transcript,
                relativePath: "history.jsonl",
                folder: folder,
                configuration: configuration
            ))
        XCTAssertTrue(store.manifestChainIsValid())

        let manifestDirectory = root.appendingPathComponent("manifests", isDirectory: true)
        let manifest = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: manifestDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let line = try String(contentsOf: manifest, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .first
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(AgentCaptureRecord.self, from: Data(String(try XCTUnwrap(line)).utf8))
        record.watchedFolderName = "Edited after capture"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var edited = try encoder.encode(record)
        edited.append(0x0A)
        try edited.write(to: manifest, options: [.atomic])

        let reloaded = try AgentActivityStore(rootDirectory: root)
        XCTAssertFalse(reloaded.manifestChainIsValid())
    }

    func testManifestValidationDetectsMalformedManifestLine() throws {
        let root = try makeTemporaryDirectory("malformed-manifest-store")
        let source = try makeTemporaryDirectory("malformed-manifest-source")
        let transcript = source.appendingPathComponent("history.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"Hello\"}\n".utf8).write(to: transcript)

        let folder = AgentWatchedFolder(
            displayName: "Codex",
            path: source.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(rootDirectory: root)
        XCTAssertNotNil(
            try store.capture(
                fileURL: transcript,
                relativePath: "history.jsonl",
                folder: folder,
                configuration: configuration
            ))

        let manifest = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("manifests", isDirectory: true),
                includingPropertiesForKeys: nil
            ).first
        )
        let handle = try FileHandle(forWritingTo: manifest)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not-json}\n".utf8))
        try handle.close()

        let reloaded = try AgentActivityStore(rootDirectory: root)
        XCTAssertFalse(reloaded.manifestChainIsValid())
    }

    func testManifestValidationDetectsDeletedTail() throws {
        let root = try makeTemporaryDirectory("deleted-tail-store")
        let source = try makeTemporaryDirectory("deleted-tail-source")
        let transcript = source.appendingPathComponent("history.jsonl")
        let folder = AgentWatchedFolder(
            displayName: "Codex",
            path: source.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(rootDirectory: root)

        try Data("{\"role\":\"user\",\"content\":\"First\"}\n".utf8).write(to: transcript)
        XCTAssertNotNil(
            try store.capture(
                fileURL: transcript,
                relativePath: "history.jsonl",
                folder: folder,
                configuration: configuration
            ))
        let expanded =
            "{\"role\":\"user\",\"content\":\"First\"}\n"
            + "{\"role\":\"assistant\",\"content\":\"Second\"}\n"
        try Data(expanded.utf8).write(to: transcript)
        XCTAssertNotNil(
            try store.capture(
                fileURL: transcript,
                relativePath: "history.jsonl",
                folder: folder,
                configuration: configuration
            ))
        XCTAssertTrue(store.manifestChainIsValid())

        let manifest = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("manifests", isDirectory: true),
                includingPropertiesForKeys: nil
            ).first
        )
        let lines = try String(contentsOf: manifest, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 2)
        try Data((String(lines[0]) + "\n").utf8).write(to: manifest, options: [.atomic])

        let reloaded = try AgentActivityStore(rootDirectory: root)
        XCTAssertFalse(reloaded.manifestChainIsValid())
        XCTAssertNotNil(
            try reloaded.capture(
                fileURL: transcript,
                relativePath: "history.jsonl",
                folder: folder,
                configuration: configuration
            ))
        let reloadedAgain = try AgentActivityStore(rootDirectory: root)
        XCTAssertFalse(reloadedAgain.manifestChainIsValid())
    }

    func testScannerCapturesTranscriptsButNeverCredentialFiles() throws {
        let root = try makeTemporaryDirectory("scanner-store")
        let source = try makeTemporaryDirectory("scanner-source")
        try Data("{\"role\":\"user\",\"content\":\"Hello\"}\n".utf8)
            .write(to: source.appendingPathComponent("history.jsonl"))
        try Data("{\"token\":\"secret\"}".utf8)
            .write(to: source.appendingPathComponent("auth.json"))
        try Data("PRIVATE KEY".utf8)
            .write(to: source.appendingPathComponent("identity.pem"))
        try Data("API_TOKEN=secret".utf8)
            .write(to: source.appendingPathComponent(".env.development"))

        let store = try AgentActivityStore(rootDirectory: root)
        let folder = AgentWatchedFolder(
            displayName: "Agent",
            path: source.path,
            provider: .custom
        )
        let scanner = AgentActivityScanner(store: store)
        let result = scanner.scan(configuration: AgentActivityConfiguration(watchedFolders: [folder]))

        XCTAssertEqual(result.newCaptureCount, 1)
        XCTAssertEqual(result.captures.first?.relativePath, "history.jsonl")
    }

    func testHookInboxPreservesRawPayloadAndParserReadsNestedEvent() throws {
        let root = try makeTemporaryDirectory("hook")
        let payload = Data(#"{"session_id":"abc","role":"user","content":"Run all tests"}"#.utf8)
        let event = try AgentHookInboxWriter.write(
            rootDirectory: root,
            provider: .claudeCode,
            eventName: "UserPromptSubmit",
            payload: payload,
            processIdentifier: 42
        )
        let envelopeData = try Data(contentsOf: event)
        let summary = AgentTranscriptParser.parse(data: envelopeData, fileURL: event, provider: .claudeCode)

        XCTAssertEqual(summary.format, .hookEvent)
        XCTAssertEqual(summary.sessionID, "abc")
        XCTAssertEqual(summary.userMessageCount, 1)
        XCTAssertEqual(summary.excerpt, "Run all tests")
    }

    func testDefaultDiscoveryAddsOnlyFoldersThatExist() throws {
        let home = try makeTemporaryDirectory("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )

        let folders = AgentDefaultSourceDiscovery.discover(homeDirectory: home)
        XCTAssertEqual(Set(folders.map(\.provider)), Set([.codex, .claudeCode]))
        XCTAssertTrue(folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testIntegrationInstallerPreservesExistingHooksAndCanRemoveOnlyGoalongHooks() throws {
        let home = try makeTemporaryDirectory("integration-home")
        let executable = home.appendingPathComponent("LocalHistory")
        _ = FileManager.default.createFile(
            atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o700])

        let cursorConfig = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(
            at: cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = #"{"version":1,"hooks":{"afterFileEdit":[{"command":"echo existing"}]}}"#
        try Data(existing.utf8).write(to: cursorConfig)

        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)
        try installer.install(.cursorHooks)
        XCTAssertTrue(installer.status(for: .cursorHooks).isInstalled)
        let installed = try String(contentsOf: cursorConfig, encoding: .utf8)
        XCTAssertTrue(installed.contains("echo existing"))
        XCTAssertTrue(installed.contains("--agent-hook-ingest"))
        XCTAssertTrue(installed.contains("sessionEnd"))
        XCTAssertTrue(installed.contains("beforeMCPExecution"))
        XCTAssertTrue(installed.contains("afterMCPExecution"))
        XCTAssertTrue(installed.contains("beforeTabFileRead"))
        XCTAssertTrue(installed.contains("afterTabFileEdit"))

        let movedExecutable = home.appendingPathComponent("Moved/LocalHistory")
        try FileManager.default.createDirectory(
            at: movedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: movedExecutable.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o700]
        )
        let movedInstaller = AgentIntegrationInstaller(executableURL: movedExecutable, homeDirectory: home)
        try movedInstaller.install(.cursorHooks)
        let updated = try String(contentsOf: cursorConfig, encoding: .utf8)
        XCTAssertTrue(updated.contains("echo existing"))
        XCTAssertFalse(updated.contains(executable.path))
        XCTAssertTrue(updated.contains(movedExecutable.path))
        XCTAssertFalse(installer.status(for: .cursorHooks).isInstalled)
        XCTAssertTrue(movedInstaller.status(for: .cursorHooks).isInstalled)

        try movedInstaller.uninstall(.cursorHooks)
        XCTAssertFalse(movedInstaller.status(for: .cursorHooks).isInstalled)
        let removed = try String(contentsOf: cursorConfig, encoding: .utf8)
        XCTAssertTrue(removed.contains("echo existing"))

        try installer.install(.codexHooks)
        XCTAssertTrue(installer.status(for: .codexHooks).isInstalled)
        let codexConfiguration = try String(
            contentsOf: installer.configurationURL(for: .codexHooks),
            encoding: .utf8
        )
        XCTAssertTrue(codexConfiguration.contains("SessionStart"))
        XCTAssertTrue(codexConfiguration.contains("--agent-hook-ingest"))
        try installer.uninstall(.codexHooks)
        XCTAssertFalse(installer.status(for: .codexHooks).isInstalled)

        try installer.install(.claudeCodeHooks)
        XCTAssertTrue(installer.status(for: .claudeCodeHooks).isInstalled)
        let claudeConfiguration = try String(
            contentsOf: installer.configurationURL(for: .claudeCodeHooks),
            encoding: .utf8
        )
        XCTAssertTrue(claudeConfiguration.contains("UserPromptExpansion"))
        XCTAssertTrue(claudeConfiguration.contains("PostToolBatch"))
        XCTAssertTrue(claudeConfiguration.contains("MessageDisplay"))
        XCTAssertTrue(claudeConfiguration.contains("DirectoryAdded"))
        XCTAssertTrue(claudeConfiguration.contains("ElicitationResult"))
        try installer.uninstall(.claudeCodeHooks)
        XCTAssertFalse(installer.status(for: .claudeCodeHooks).isInstalled)

        try installer.install(.openCodePlugin)
        XCTAssertTrue(installer.status(for: .openCodePlugin).isInstalled)
        try installer.uninstall(.openCodePlugin)
        XCTAssertFalse(installer.status(for: .openCodePlugin).isInstalled)
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentActivityTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
