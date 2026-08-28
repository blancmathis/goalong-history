import Foundation
import SQLite3
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

    func testCodexClaudeAndOpenCodeAreDiscoveredAndReadFromOriginalStorage() throws {
        let fixture = try makeProviderFixture()
        let originalSourceBytes = try fixture.sourceFiles.map { try Data(contentsOf: $0) }
        let storeRoot = try makeTemporaryDirectory("provider-store")
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let configuration = AgentActivityConfiguration(watchedFolders: fixture.folders)

        let result = AgentActivityScanner(store: store).scan(
            configuration: configuration,
            forceFullDiscovery: true
        )

        XCTAssertEqual(result.changedSourceCount, 3)
        XCTAssertEqual(Set(result.captures.map(\.provider)), Set([.codex, .claudeCode, .openCode]))
        XCTAssertEqual(store.indexEntryCount(), 3)
        for record in result.captures {
            XCTAssertEqual(record.availability, .available)
            XCTAssertGreaterThan(record.summary.messageCount, 0)
            XCTAssertTrue(record.sourcePath.hasPrefix(fixture.home.path))
            XCTAssertFalse(record.sourcePath.hasPrefix(storeRoot.path))
        }

        let openCode = try XCTUnwrap(result.captures.first { $0.provider == .openCode })
        XCTAssertEqual(openCode.index.reference.kind, .sqliteConversation)
        let opaqueLocator = try XCTUnwrap(openCode.index.reference.locator)
        XCTAssertTrue(AgentStableConversationIdentifier.isPersisted(opaqueLocator))
        XCTAssertEqual(opaqueLocator, openCode.index.stableConversationID)
        XCTAssertEqual(openCode.summary.sessionID, opaqueLocator)
        XCTAssertFalse(opaqueLocator.contains("opencode-fixture"))
        XCTAssertEqual(try fixture.sourceFiles.map { try Data(contentsOf: $0) }, originalSourceBytes)
    }

    func testCodexConversationUsesUserFacingNameWithoutPersistingIt() throws {
        let codexRoot = try makeTemporaryDirectory("codex-title-source")
        let sessions = codexRoot.appendingPathComponent("sessions/2026/08/28", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionID = "10000000-0000-4000-8000-000000000123"
        let source = sessions.appendingPathComponent(
            "rollout-2026-08-28T20-00-00-\(sessionID).jsonl"
        )
        let fallbackPrompt = "FALLBACK-PROMPT-MUST-NOT-BE-PERSISTED"
        try Data(codexTranscript(sessionID: sessionID, messages: [fallbackPrompt]).utf8)
            .write(to: source)

        let userFacingName = "Clarifier le vrai titre Codex"
        let catalog = codexRoot.appendingPathComponent("state_5.sqlite")
        try createCodexThreadCatalog(
            at: catalog,
            sessionID: sessionID,
            title: fallbackPrompt,
            name: userFacingName
        )
        let sourceBefore = try Data(contentsOf: source)
        let catalogBefore = try Data(contentsOf: catalog)
        XCTAssertEqual(
            try CodexThreadTitleConnection(path: catalog.path).title(threadID: sessionID),
            userFacingName
        )

        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("codex-title-store")
        )
        let folder = AgentWatchedFolder(
            displayName: "Codex",
            path: codexRoot.path,
            provider: .codex
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true
        )

        let capture = try XCTUnwrap(result.captures.first)
        XCTAssertEqual(capture.summary.title, userFacingName)
        store.discardTransientSummaries()
        let rehydrated = try store.directRead(
            entryID: capture.id,
            maximumBytes: AgentActivityConfiguration().maximumFileBytes,
            expectedReference: capture.index.reference
        )
        XCTAssertEqual(rehydrated.summary.title, userFacingName)
        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: catalog), catalogBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.path + "-shm"))
        let persistedIndex = try String(contentsOf: store.indexFile, encoding: .utf8)
        XCTAssertFalse(persistedIndex.contains(userFacingName))
        XCTAssertFalse(persistedIndex.contains(fallbackPrompt))
    }

    func testCodexConversationWithoutCatalogNeverShowsRolloutFilename() throws {
        let codexRoot = try makeTemporaryDirectory("codex-title-fallback-source")
        let sessions = codexRoot.appendingPathComponent("sessions/2026/08/28", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionID = "10000000-0000-4000-8000-000000000124"
        let source = sessions.appendingPathComponent(
            "rollout-2026-08-28T20-01-00-\(sessionID).jsonl"
        )
        let prompt = "Résumer proprement cette conversation"
        try Data(codexTranscript(sessionID: sessionID, messages: [prompt]).utf8).write(to: source)

        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("codex-title-fallback-store")
        )
        let folder = AgentWatchedFolder(
            displayName: "Codex",
            path: codexRoot.path,
            provider: .codex
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true
        )

        let capture = try XCTUnwrap(result.captures.first)
        XCTAssertEqual(capture.summary.title, prompt)
        XCTAssertFalse(capture.summary.title?.hasPrefix("rollout-") == true)
        XCTAssertFalse(try String(contentsOf: store.indexFile, encoding: .utf8).contains(prompt))
    }

    func testOptInRealCodexCatalogReadsCurrentOriginalTitle() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let catalogPath = environment["GOALONG_REAL_CODEX_CATALOG"],
            let threadID = environment["GOALONG_REAL_CODEX_THREAD_ID"]
        else {
            throw XCTSkip("Set the real Codex catalog path and thread ID for a read-only integration check.")
        }
        let title = try XCTUnwrap(
            try CodexThreadTitleConnection(path: catalogPath).title(threadID: threadID)
        )
        XCTAssertFalse(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(title.lowercased().hasPrefix("rollout-"))
    }

    func testTranscriptAndHookContentsAreNeverCopiedIntoGoalongStorage() throws {
        let fixture = try makeProviderFixture()
        let applicationSupportRoot = try makeTemporaryDirectory("no-copy-application-support")
        let preservedStores = try [
            "events", "memories", "seals", "apple-screen-time", "receipts", "semantic",
        ].map { name in
            let directory = applicationSupportRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("preserved.marker")
            let contents = Data("PRESERVE-\(name)-STORE".utf8)
            try contents.write(to: marker)
            return (marker, contents)
        }
        let storeRoot =
            applicationSupportRoot
            .appendingPathComponent("agent-activity-v2", isDirectory: true)
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let configuration = AgentActivityConfiguration(watchedFolders: fixture.folders)
        let scanner = AgentActivityScanner(store: store)
        let analysisDay = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")
        )
        let initial = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analysisDay: analysisDay
        )
        XCTAssertEqual(Set(initial.captures.map(\.provider)), Set([.codex, .claudeCode, .openCode]))

        let indexBeforeRehydration = try Data(contentsOf: store.indexFile)
        let writesBeforeRehydration = store.indexWriteCountForTesting()
        store.discardTransientSummaries()
        let directlyRehydrated = try store.entries().map { entry in
            let record = try store.directRead(
                entryID: entry.id,
                maximumBytes: configuration.maximumFileBytes,
                expectedReference: entry.reference,
                observedAt: analysisDay
            )
            XCTAssertEqual(record.index.reference, entry.reference)
            XCTAssertEqual(record.sha256, entry.sha256)
            XCTAssertTrue(record.isAnalyzed)
            XCTAssertGreaterThan(record.summary.messageCount, 0)
            XCTAssertTrue(record.sourcePath.hasPrefix(fixture.home.path))
            XCTAssertFalse(record.sourcePath.hasPrefix(applicationSupportRoot.path))
            return record
        }
        XCTAssertEqual(
            Set<AgentProvider>(directlyRehydrated.map(\.provider)),
            Set<AgentProvider>([.codex, .claudeCode, .openCode])
        )
        XCTAssertEqual(store.indexWriteCountForTesting(), writesBeforeRehydration)
        XCTAssertEqual(try Data(contentsOf: store.indexFile), indexBeforeRehydration)

        let secretHookText = "HOOK-BODY-MUST-NOT-BE-STORED"
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .codex,
            eventName: "UserPromptSubmit",
            discardedPayloadBytes: Int64(secretHookText.utf8.count),
            processIdentifier: 42
        )

        for sentinel in fixture.sentinels + [secretHookText] {
            XCTAssertTrue(
                try regularFiles(
                    containing: Data(sentinel.utf8),
                    beneath: applicationSupportRoot
                ).isEmpty,
                "Goalong support storage copied transcript content: \(sentinel)"
            )
        }
        for (sentinel, expectedSource) in zip(fixture.sentinels, fixture.sourceFiles) {
            XCTAssertEqual(
                try regularFiles(containing: Data(sentinel.utf8), beneath: fixture.home),
                [expectedSource.standardizedFileURL]
            )
        }
        for (marker, expectedContents) in preservedStores {
            XCTAssertEqual(try Data(contentsOf: marker), expectedContents)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("blobs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("manifests").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("materialized").path))

        let indexObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.indexFile)) as? [String: Any]
        )
        let indexJSON = String(decoding: try JSONSerialization.data(withJSONObject: indexObject), as: UTF8.self)
        XCTAssertFalse(indexJSON.contains("summary"))
        XCTAssertFalse(indexJSON.contains("excerpt"))
        XCTAssertFalse(indexJSON.contains("commands"))
        XCTAssertFalse(indexJSON.contains("messages"))
    }

    func testProviderConversationIdentifierIsPersistedOnlyAsAnOpaqueDigest() throws {
        let sourceRoot = try makeTemporaryDirectory("opaque-id-source")
        let transcript = sourceRoot.appendingPathComponent("conversation.jsonl")
        let arbitraryIdentifier = "PROMPT-LIKE-IDENTIFIER-MUST-NOT-ENTER-THE-INDEX"
        try Data(
            #"{"session_id":"\#(arbitraryIdentifier)","role":"user","content":"fixture"}"#.utf8
        ).write(to: transcript)

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("opaque-id-store"))
        let folder = AgentWatchedFolder(
            id: "opaque-id",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true
        )

        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertTrue(AgentStableConversationIdentifier.isPersisted(entry.stableConversationID))
        XCTAssertEqual(entry.stableConversationID.utf8.count, "sid3-sha256-".utf8.count + 64)
        XCTAssertFalse(try String(contentsOf: store.indexFile).contains(arbitraryIdentifier))
    }

    func testSourceModificationReplacesIndexEntryWithoutDuplication() throws {
        let sourceRoot = try makeTemporaryDirectory("modified-source")
        let sessionDirectory = sourceRoot.appendingPathComponent("sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("rollout-fixture.jsonl")
        try Data(codexTranscript(sessionID: "stable-codex", messages: ["FIRST-VISIBLE-MESSAGE"]).utf8)
            .write(to: transcript)

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("modified-store"))
        let folder = AgentWatchedFolder(displayName: "Codex", path: sourceRoot.path, provider: .codex)
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let scanner = AgentActivityScanner(store: store)
        let firstDate = Date()
        let first = scanner.scan(configuration: configuration, forceFullDiscovery: true, at: firstDate)
        let firstRecord = try XCTUnwrap(first.captures.first)

        try Data(
            codexTranscript(
                sessionID: "stable-codex",
                messages: ["FIRST-VISIBLE-MESSAGE", "SECOND-VISIBLE-MESSAGE"]
            ).utf8
        ).write(to: transcript, options: [.atomic])
        try FileManager.default.setAttributes(
            [.modificationDate: firstDate.addingTimeInterval(5)],
            ofItemAtPath: transcript.path
        )

        let refreshed = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: false,
            at: firstDate.addingTimeInterval(10)
        )
        XCTAssertEqual(refreshed.scannedSourceCount, 1)
        XCTAssertEqual(refreshed.changedSourceCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 1)
        let secondRecord = try XCTUnwrap(refreshed.captures.first)

        let periodic = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: false,
            at: firstDate.addingTimeInterval(910)
        )
        XCTAssertEqual(periodic.scannedSourceCount, 0)
        XCTAssertEqual(periodic.changedSourceCount, 0)
        XCTAssertTrue(periodic.captures.isEmpty)
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertEqual(firstRecord.id, secondRecord.id)
        XCTAssertNotEqual(firstRecord.sha256, secondRecord.sha256)
        XCTAssertEqual(secondRecord.summary.userMessageCount, 2)
        XCTAssertFalse(try String(contentsOf: store.indexFile, encoding: .utf8).contains("SECOND-VISIBLE-MESSAGE"))
    }

    func testDeletedAndInaccessibleSourcesHaveClearStates() throws {
        let source = try makeTemporaryDirectory("availability-source")
        let deleted = source.appendingPathComponent("deleted-session.jsonl")
        let inaccessible = source.appendingPathComponent("inaccessible-session.jsonl")
        try Data(#"{"session_id":"deleted","role":"user","content":"delete me"}"#.utf8).write(to: deleted)
        try Data(#"{"session_id":"locked","role":"user","content":"lock me"}"#.utf8).write(to: inaccessible)

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("availability-store"))
        let folder = AgentWatchedFolder(displayName: "Custom", path: source.path, provider: .custom)
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let scanner = AgentActivityScanner(store: store)
        _ = scanner.scan(configuration: configuration, forceFullDiscovery: true)

        try FileManager.default.removeItem(at: deleted)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inaccessible.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inaccessible.path) }

        let result = scanner.scan(configuration: configuration, forceFullDiscovery: false)
        XCTAssertEqual(result.statusChangeCount, 2)
        let entries = store.entries(folderID: folder.id)
        XCTAssertEqual(entries.first { $0.reference.path == deleted.path }?.availability, .missing)
        XCTAssertEqual(entries.first { $0.reference.path == inaccessible.path }?.availability, .inaccessible)
        XCTAssertTrue(entries.allSatisfy { !($0.statusDetail ?? "").isEmpty })
    }

    func testIndexIsBoundedLightweightAndSecondScanIsIncremental() throws {
        let source = try makeTemporaryDirectory("bounded-source")
        let body = String(repeating: "TRANSCRIPT-BODY-NOT-IN-INDEX-", count: 180)
        for index in 0..<130 {
            let text = #"{"session_id":"session-\#(index)","role":"user","content":"\#(body)-\#(index)"}"#
            try Data(text.utf8).write(to: source.appendingPathComponent("session-\(index).jsonl"))
        }

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("bounded-store"))
        let folder = AgentWatchedFolder(displayName: "Custom", path: source.path, provider: .custom)
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            fullDiscoveryIntervalSeconds: 900,
            maximumIndexEntries: 100
        )
        let scanner = AgentActivityScanner(store: store)
        let firstDate = Date()
        let first = scanner.scan(configuration: configuration, forceFullDiscovery: true, at: firstDate)
        let firstIndexBytes = store.indexBytes()

        XCTAssertEqual(first.fullDiscoveryCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 100)
        XCTAssertLessThan(firstIndexBytes, 256 * 1_024)
        XCTAssertLessThan(store.storageBytes(), 300 * 1_024)
        XCTAssertFalse(
            try String(contentsOf: store.indexFile, encoding: .utf8).contains("TRANSCRIPT-BODY-NOT-IN-INDEX"))
        XCTAssertTrue(store.indexIsValid(maximumEntries: 100))

        let second = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: false,
            at: firstDate.addingTimeInterval(10)
        )
        XCTAssertEqual(second.fullDiscoveryCount, 0)
        XCTAssertEqual(second.scannedSourceCount, 0)
        XCTAssertEqual(second.changedSourceCount, 0)
        XCTAssertEqual(store.indexEntryCount(), 100)
        XCTAssertEqual(store.indexBytes(), firstIndexBytes)

        let reloaded = try AgentActivityStore(rootDirectory: store.rootDirectory)
        let afterRestart = AgentActivityScanner(store: reloaded).scan(
            configuration: configuration,
            forceFullDiscovery: false,
            analysisDay: firstDate.addingTimeInterval(-24 * 60 * 60),
            at: firstDate.addingTimeInterval(20)
        )
        XCTAssertEqual(afterRestart.fullDiscoveryCount, 0)
        XCTAssertEqual(afterRestart.scannedSourceCount, 0)
        XCTAssertEqual(reloaded.indexEntryCount(), 100)
    }

    func testScheduledFullReconciliationIsRareWhileWarmScansStayIncremental() throws {
        let sourceRoot = try makeTemporaryDirectory("daily-reconciliation-source")
        let firstSource = sourceRoot.appendingPathComponent("first.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"first\"}\n".utf8).write(to: firstSource)
        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("daily-reconciliation-store")
        )
        let folder = AgentWatchedFolder(
            id: "daily-reconciliation",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            fullDiscoveryIntervalSeconds: 15 * 60
        )
        let scanner = AgentActivityScanner(store: store)
        let initialDate = Date(timeIntervalSince1970: 1_787_472_000)
        XCTAssertEqual(
            scanner.scan(
                configuration: configuration,
                forceFullDiscovery: true,
                at: initialDate
            ).fullDiscoveryCount,
            1
        )
        let laterSource = sourceRoot.appendingPathComponent("later.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"later\"}\n".utf8).write(to: laterSource)

        let afterFifteenMinutes = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(15 * 60)
        )
        XCTAssertEqual(afterFifteenMinutes.fullDiscoveryCount, 0)
        XCTAssertEqual(store.indexEntryCount(), 1)

        let beforeDailyReconciliation = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(24 * 60 * 60 - 1)
        )
        XCTAssertEqual(beforeDailyReconciliation.fullDiscoveryCount, 0)
        XCTAssertEqual(store.indexEntryCount(), 1)

        let dailyReconciliation = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(dailyReconciliation.fullDiscoveryCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 2)
    }

    func testConfigurationMigrationDropsLegacyVaultControlsAndManagedHookFolders() throws {
        let root = try makeTemporaryDirectory("legacy-config")
        let source = try makeTemporaryDirectory("legacy-source")
        let legacy = """
            {
              "schemaVersion": 1,
              "scanIntervalSeconds": 8,
              "maximumFileBytes": 268435456,
              "captureFullContents": true,
              "keepEveryVersion": true,
              "maximumDeltaDepth": 20,
              "watchedFolders": [
                {"id":"source","displayName":"Codex","path":"\(source.path)","provider":"codex","isEnabled":true,"includeSubdirectories":true,"captureMode":"transcriptsAndLogs","isManaged":false,"addedAt":"1970-01-01T00:00:00Z"},
                {"id":"hook","displayName":"Legacy hook inbox","path":"\(root.path)/hook-inbox/codex","provider":"codex","isEnabled":true,"includeSubdirectories":true,"captureMode":"everyFile","isManaged":true,"addedAt":"1970-01-01T00:00:00Z"}
              ]
            }
            """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("configuration.json"))
        let store = try AgentActivityStore(rootDirectory: root)
        let loaded = store.loadConfiguration()
        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(
            loaded.watchedFolders.map(\.id),
            [AgentFolderIdentifier.persisted(provider: .codex, path: source.path)]
        )
        _ = try store.saveConfiguration(loaded)
        let saved = try String(contentsOf: store.configurationFile, encoding: .utf8)
        XCTAssertFalse(saved.contains("captureFullContents"))
        XCTAssertFalse(saved.contains("keepEveryVersion"))
        XCTAssertFalse(saved.contains("maximumDeltaDepth"))
        XCTAssertFalse(saved.contains("hook-inbox"))
    }

    func testDefaultDiscoveryAddsOnlyFoldersThatExist() throws {
        let home = try makeTemporaryDirectory("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let folders = AgentDefaultSourceDiscovery.discover(homeDirectory: home)
        XCTAssertEqual(Set(folders.map(\.provider)), Set([.codex, .claudeCode]))
        XCTAssertTrue(folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testIntegrationInstallerPreservesExistingHooksAndOpenCodeSendsNoPayload() throws {
        let home = try makeTemporaryDirectory("integration-home")
        let executable = home.appendingPathComponent("Goalong History")
        _ = FileManager.default.createFile(
            atPath: executable.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o700]
        )
        let cursorConfig = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(
            at: cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"hooks":{"afterFileEdit":[{"command":"echo existing"}]}}"#.utf8)
            .write(to: cursorConfig)

        let installer = AgentIntegrationInstaller(executableURL: executable, homeDirectory: home)
        try installer.install(.cursorHooks)
        let cursor = try String(contentsOf: cursorConfig, encoding: .utf8)
        XCTAssertTrue(cursor.contains("echo existing"))
        XCTAssertTrue(cursor.contains("--agent-hook-ingest"))
        try installer.uninstall(.cursorHooks)
        XCTAssertTrue(try String(contentsOf: cursorConfig, encoding: .utf8).contains("echo existing"))

        try installer.install(.openCodePlugin)
        let plugin = try String(contentsOf: installer.configurationURL(for: .openCodePlugin), encoding: .utf8)
        XCTAssertTrue(plugin.contains("--agent-hook-ingest"))
        XCTAssertTrue(plugin.contains(#"stdin: "ignore""#))
        XCTAssertFalse(plugin.contains("JSON.stringify"))
        XCTAssertFalse(plugin.contains("child.stdin.write"))
    }

    private func makeProviderFixture() throws -> (
        home: URL,
        folders: [AgentWatchedFolder],
        sentinels: [String],
        sourceFiles: [URL]
    ) {
        let home = try makeTemporaryDirectory("provider-home")
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let codexSessions = codexRoot.appendingPathComponent("sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        let codexSentinel = "CODEX-ORIGINAL-CONTENT-SENTINEL"
        let codexFile = codexSessions.appendingPathComponent("rollout-fixture.jsonl")
        try Data(codexTranscript(sessionID: "codex-fixture", messages: [codexSentinel]).utf8)
            .write(to: codexFile)

        let claudeRoot = home.appendingPathComponent(".claude", isDirectory: true)
        let claudeProject = claudeRoot.appendingPathComponent("projects/test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        let claudeSentinel = "CLAUDE-ORIGINAL-CONTENT-SENTINEL"
        let claudeFile = claudeProject.appendingPathComponent("claude-fixture.jsonl")
        let claude =
            #"{"sessionId":"claude-fixture","timestamp":"2026-08-23T09:00:00Z","type":"user","message":{"role":"user","content":"\#(claudeSentinel)"}}"#
        try Data(claude.utf8).write(to: claudeFile)

        let openCodeRoot = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeRoot, withIntermediateDirectories: true)
        let openCodeSentinel = "OPENCODE-ORIGINAL-CONTENT-SENTINEL"
        let openCodeFile = openCodeRoot.appendingPathComponent("opencode.db")
        try createOpenCodeDatabase(
            at: openCodeFile,
            sessionID: "opencode-fixture",
            content: openCodeSentinel
        )

        return (
            home,
            [
                AgentWatchedFolder(id: "codex-folder", displayName: "Codex", path: codexRoot.path, provider: .codex),
                AgentWatchedFolder(
                    id: "claude-folder", displayName: "Claude", path: claudeRoot.path, provider: .claudeCode),
                AgentWatchedFolder(
                    id: "opencode-folder", displayName: "OpenCode", path: openCodeRoot.path, provider: .openCode),
            ],
            [codexSentinel, claudeSentinel, openCodeSentinel],
            [codexFile, claudeFile, openCodeFile]
        )
    }

    private func codexTranscript(sessionID: String, messages: [String]) -> String {
        var lines = [
            #"{"type":"session_meta","timestamp":"2026-08-23T08:00:00Z","payload":{"id":"\#(sessionID)","session_id":"\#(sessionID)","timestamp":"2026-08-23T08:00:00Z"}}"#
        ]
        for (index, message) in messages.enumerated() {
            lines.append(
                #"{"type":"response_item","timestamp":"2026-08-23T08:00:0\#(index + 1)Z","payload":{"role":"user","content":"\#(message)"}}"#
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func createOpenCodeDatabase(at url: URL, sessionID: String, content: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let escapedContent = content.replacingOccurrences(of: "'", with: "''")
        let statements = [
            "CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER)",
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)",
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)",
            "INSERT INTO session VALUES ('\(sessionID)', 'project', NULL, 'fixture', '/tmp/opencode-project', 'OpenCode fixture', '1', 1787472000000, 1787472060000)",
            "INSERT INTO message VALUES ('message-1', '\(sessionID)', 1787472000000, 1787472060000, '{\"role\":\"user\",\"time\":{\"created\":1787472000000}}')",
            "INSERT INTO part VALUES ('part-1', 'message-1', '\(sessionID)', 1787472000000, 1787472060000, '{\"type\":\"text\",\"text\":\"\(escapedContent)\"}')",
        ]
        for statement in statements {
            var error: UnsafeMutablePointer<Int8>?
            let result = sqlite3_exec(database, statement, nil, nil, &error)
            let message = error.map { String(cString: $0) }
            if let error { sqlite3_free(error) }
            XCTAssertEqual(result, SQLITE_OK, message ?? statement)
        }
    }

    private func createCodexThreadCatalog(
        at url: URL,
        sessionID: String,
        title: String,
        name: String?
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let create = "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, name TEXT)"
        XCTAssertEqual(sqlite3_exec(database, create, nil, nil, nil), SQLITE_OK)

        var statement: OpaquePointer?
        let insert = "INSERT INTO threads (id, title, name) VALUES (?, ?, ?)"
        XCTAssertEqual(sqlite3_prepare_v2(database, insert, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_bind_text(statement, 1, sessionID, -1, transient), SQLITE_OK)
        XCTAssertEqual(sqlite3_bind_text(statement, 2, title, -1, transient), SQLITE_OK)
        if let name {
            XCTAssertEqual(sqlite3_bind_text(statement, 3, name, -1, transient), SQLITE_OK)
        } else {
            XCTAssertEqual(sqlite3_bind_null(statement, 3), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func regularFiles(containing needle: Data, beneath root: URL) throws -> [URL] {
        let maximumVisitedItems = 1_024
        let maximumRegularFiles = 512
        let maximumFileBytes = 16 * 1_024 * 1_024
        let maximumTotalBytes = 32 * 1_024 * 1_024
        var enumerationError: Error?
        func traversalError(_ detail: String) -> NSError {
            NSError(
                domain: "AgentActivityTests.BoundedFileTraversal",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }

        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else {
            throw traversalError("Temporary Application Support root could not be enumerated")
        }

        var output: [URL] = []
        var visitedItemCount = 0
        var regularFileCount = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            visitedItemCount += 1
            guard visitedItemCount <= maximumVisitedItems else {
                throw traversalError("Temporary Application Support traversal exceeded its item bound")
            }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            regularFileCount += 1
            guard regularFileCount <= maximumRegularFiles else {
                throw traversalError("Temporary Application Support traversal exceeded its file bound")
            }
            guard let fileBytes = values.fileSize else {
                throw traversalError("Temporary Application Support file size was unavailable")
            }
            guard fileBytes >= 0, fileBytes <= maximumFileBytes else {
                throw traversalError("Temporary Application Support file exceeded its byte bound")
            }
            totalBytes += fileBytes
            guard totalBytes <= maximumTotalBytes else {
                throw traversalError("Temporary Application Support traversal exceeded its byte bound")
            }
            if try Data(contentsOf: url).range(of: needle) != nil {
                output.append(url.standardizedFileURL)
            }
        }
        if let enumerationError { throw enumerationError }
        return output.sorted { $0.path < $1.path }
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentActivityTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
