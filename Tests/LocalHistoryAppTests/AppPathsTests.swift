#if os(macOS)
    import AgentActivity
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class AppPathsTests: XCTestCase {
        func testAgentActivityV2MigrationRemovesOnlyLegacyVaultAndLeavesBarrier() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(
                at: legacy.appendingPathComponent("signals", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: legacy.appendingPathComponent("blobs/aa", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: v2.appendingPathComponent("signals", isDirectory: true), withIntermediateDirectories: true)

            let configuration = Data(
                """
                {"schemaVersion":2,"watchedFolders":[],"scanIntervalSeconds":8,"fullDiscoveryIntervalSeconds":900,"maximumFileBytes":268435456,"maximumIndexEntries":10000,"captureFullContents":true,"keepEveryVersion":true}
                """.utf8
            )
            let indexEncoder = JSONEncoder()
            indexEncoder.dateEncodingStrategy = .iso8601
            indexEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let index = try indexEncoder.encode(
                AgentActivityIndex(updatedAt: Date(timeIntervalSince1970: 1_787_472_100))
            )
            let legacyCodexSignal = signalJSON(provider: "codex", eventName: "SessionStart")
            let preservedCodexSignal = signalJSON(provider: "codex", eventName: "FileChanged")
            let claudeSignal = signalJSON(provider: "claudeCode", eventName: "Stop")
            let forbiddenTranscript = Data("transcript-body-must-not-survive".utf8)

            try configuration.write(to: legacy.appendingPathComponent("configuration.json"))
            try index.write(to: legacy.appendingPathComponent("index.json"))
            try legacyCodexSignal.write(to: legacy.appendingPathComponent("signals/codex.json"))
            try claudeSignal.write(to: legacy.appendingPathComponent("signals/claudeCode.json"))
            try forbiddenTranscript.write(to: legacy.appendingPathComponent("signals/transcript.json"))
            try Data(
                """
                {"schemaVersion":1,"provider":"custom","eventName":"event","signaledAt":"2026-08-23T20:00:00Z","processIdentifier":123,"discardedPayloadBytes":456,"payload":"transcript-body-must-not-survive"}
                """.utf8
            ).write(to: legacy.appendingPathComponent("signals/custom.json"))
            try forbiddenTranscript.write(to: legacy.appendingPathComponent("blobs/aa/transcript"))
            try Data("legacy-state".utf8).write(to: legacy.appendingPathComponent("state.json"))
            try preservedCodexSignal.write(to: v2.appendingPathComponent("signals/codex.json"))

            let siblingBytes: [String: Data] = [
                "events": Data("event-bytes".utf8),
                "memories": Data("memory-bytes".utf8),
                "seals": Data("seal-bytes".utf8),
                "apple-screen-time": Data("screen-time-bytes".utf8),
            ]
            for (directoryName, bytes) in siblingBytes {
                let directory = temporaryRoot.appendingPathComponent(directoryName, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent("sentinel.bin"))
            }

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            let migratedConfigurationData = try Data(
                contentsOf: v2.appendingPathComponent("configuration.json")
            )
            let configurationDecoder = JSONDecoder()
            configurationDecoder.dateDecodingStrategy = .iso8601
            let migratedConfiguration = try configurationDecoder.decode(
                AgentActivityConfiguration.self,
                from: migratedConfigurationData
            )
            XCTAssertEqual(migratedConfiguration, AgentActivityConfiguration.default)
            XCTAssertNil(migratedConfigurationData.range(of: Data("captureFullContents".utf8)))
            XCTAssertNil(migratedConfigurationData.range(of: Data("keepEveryVersion".utf8)))
            XCTAssertEqual(try Data(contentsOf: v2.appendingPathComponent("index.json")), index)
            XCTAssertEqual(
                try Data(contentsOf: v2.appendingPathComponent("signals/codex.json")),
                preservedCodexSignal,
                "Existing v2 signals must win over legacy signals"
            )
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: v2.appendingPathComponent("signals/claudeCode.json").path
                ),
                "Legacy signal event names are free-form hints and must be regenerated"
            )

            var legacyIsDirectory = ObjCBool(false)
            XCTAssertTrue(fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory))
            XCTAssertFalse(legacyIsDirectory.boolValue)
            let legacyPermissions = try XCTUnwrap(
                fileManager.attributesOfItem(atPath: legacy.path)[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(legacyPermissions.intValue & 0o777, 0o600)
            XCTAssertThrowsError(
                try fileManager.createDirectory(
                    at: legacy.appendingPathComponent("blobs", isDirectory: true),
                    withIntermediateDirectories: true
                ),
                "The regular-file barrier must stop a legacy build before it recreates blobs"
            )
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: temporaryRoot.appendingPathComponent(".agent-activity-legacy-quarantine-v2").path
                )
            )

            let v2Items = try recursiveRelativePaths(in: v2, fileManager: fileManager)
            XCTAssertEqual(
                v2Items,
                ["configuration.json", "index.json", "signals", "signals/codex.json"]
            )
            XCTAssertFalse(v2Items.contains { $0.contains("blob") || $0.contains("state") })

            for (directoryName, expectedBytes) in siblingBytes {
                let file = temporaryRoot.appendingPathComponent("\(directoryName)/sentinel.bin")
                XCTAssertEqual(try Data(contentsOf: file), expectedBytes)
            }

            let firstSentinelBytes = try Data(contentsOf: legacy)
            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )
            XCTAssertEqual(try Data(contentsOf: legacy), firstSentinelBytes)
            XCTAssertEqual(
                try Data(contentsOf: v2.appendingPathComponent("configuration.json")),
                migratedConfigurationData
            )
            XCTAssertEqual(try Data(contentsOf: v2.appendingPathComponent("index.json")), index)
            XCTAssertEqual(try Data(contentsOf: v2.appendingPathComponent("signals/codex.json")), preservedCodexSignal)
            for (directoryName, expectedBytes) in siblingBytes {
                let file = temporaryRoot.appendingPathComponent("\(directoryName)/sentinel.bin")
                XCTAssertEqual(try Data(contentsOf: file), expectedBytes)
            }
        }

        func testRetiredFixedQuarantineIsRemovedOnlyAfterSafeV2AndBarrierAreVerified() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsRetiredQuarantineTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            let seeded = try seedSafeV2AndBarrier(in: temporaryRoot, fileManager: fileManager)

            let quarantine = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2",
                isDirectory: true
            )
            for directory in ["blobs/aa", "manifests", "materialized", "hook-inbox"] {
                try fileManager.createDirectory(
                    at: quarantine.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            try Data("retired transcript body".utf8).write(
                to: quarantine.appendingPathComponent("blobs/aa/source.blob")
            )
            try Data("legacy configuration".utf8).write(
                to: quarantine.appendingPathComponent("configuration.json")
            )
            try Data("legacy index".utf8).write(
                to: quarantine.appendingPathComponent("index.json")
            )
            try Data("legacy backup".utf8).write(
                to: quarantine.appendingPathComponent(
                    "configuration.pre-scan-hotfix-2026-08-21T0916.json"
                )
            )

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            XCTAssertFalse(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertEqual(try Data(contentsOf: seeded.configurationURL), seeded.configuration)
            XCTAssertEqual(try Data(contentsOf: seeded.indexURL), seeded.index)
            XCTAssertEqual(
                try Data(contentsOf: seeded.barrier),
                Data(
                    "Goalong History Agent Activity v2 safety barrier. Legacy storage is disabled.\n".utf8
                )
            )
        }

        func testPreparedAgentActivityStoreRepairsOwnerOnlyDirectoryAndFileModes() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsOwnerOnlyAgentStore-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            let seeded = try seedSafeV2AndBarrier(in: temporaryRoot, fileManager: fileManager)
            let v2 = seeded.configurationURL.deletingLastPathComponent()
            let signals = v2.appendingPathComponent("signals", isDirectory: true)
            let signal = signals.appendingPathComponent("codex.json")
            try signalJSON(provider: "codex", eventName: "SessionStart").write(to: signal)
            try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: v2.path)
            try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: signals.path)
            for file in [seeded.configurationURL, seeded.indexURL, signal] {
                try fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
            }

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            XCTAssertEqual(try permissions(v2), 0o700)
            XCTAssertEqual(try permissions(signals), 0o700)
            XCTAssertEqual(try permissions(seeded.configurationURL), 0o600)
            XCTAssertEqual(try permissions(seeded.indexURL), 0o600)
            XCTAssertEqual(try permissions(signal), 0o600)
        }

        func testApplicationStorageRejectsSymlinkedChatGPTComponentAndRepairsDirectoryModes() throws {
            let fileManager = FileManager.default
            let unsafeRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnsafeChatGPT-\(UUID().uuidString)",
                isDirectory: true
            )
            let external = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnsafeChatGPTExternal-\(UUID().uuidString)",
                isDirectory: true
            )
            defer {
                try? fileManager.removeItem(at: unsafeRoot)
                try? fileManager.removeItem(at: external)
            }
            try fileManager.createDirectory(at: unsafeRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(
                at: unsafeRoot.appendingPathComponent("chatgpt"),
                withDestinationURL: external
            )

            XCTAssertThrowsError(
                try AppPaths.prepareApplicationStorage(
                    applicationSupportDirectory: unsafeRoot,
                    fileManager: fileManager,
                    agentActivityPreparation: { _, _ in }
                )
            )
            XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: external.path).isEmpty)

            let safeRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsSecureDirectories-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: safeRoot) }
            try fileManager.createDirectory(
                at: safeRoot.appendingPathComponent("chatgpt"),
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: safeRoot.path)
            try fileManager.setAttributes(
                [.posixPermissions: 0o777],
                ofItemAtPath: safeRoot.appendingPathComponent("chatgpt").path
            )

            try AppPaths.prepareApplicationStorage(
                applicationSupportDirectory: safeRoot,
                fileManager: fileManager,
                agentActivityPreparation: { _, _ in }
            )

            XCTAssertEqual(try permissions(safeRoot), 0o700)
            for relativePath in [
                "events", "seals", "receipts", "shares", "semantic", "memories",
                "apple-screen-time", "chatgpt", "chatgpt/history", "chatgpt/recaps",
                "chatgpt/runs", "chatgpt/codex-home",
            ] {
                XCTAssertEqual(try permissions(safeRoot.appendingPathComponent(relativePath)), 0o700)
            }
        }

        func testRecognizableUUIDLegacyVaultIsRemovedAfterVerifiedBarrierAndV2Store() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsDynamicQuarantineTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            _ = try seedSafeV2AndBarrier(in: temporaryRoot, fileManager: fileManager)

            let quarantine = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2-\(UUID().uuidString)",
                isDirectory: true
            )
            for directory in ["blobs/aa", "manifests", "materialized"] {
                try fileManager.createDirectory(
                    at: quarantine.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            try Data("retired transcript body".utf8).write(
                to: quarantine.appendingPathComponent("blobs/aa/source.blob")
            )
            try Data("legacy configuration".utf8).write(
                to: quarantine.appendingPathComponent("configuration.json")
            )
            try Data("legacy index".utf8).write(
                to: quarantine.appendingPathComponent("index.json")
            )

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            XCTAssertFalse(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertFalse(
                try fileManager.contentsOfDirectory(atPath: temporaryRoot.path).contains {
                    $0.hasPrefix(".agent-activity-legacy-quarantine-v2-")
                }
            )
        }

        func testUnknownUUIDQuarantineIsPreservedAndBlocksAllQuarantineDeletion() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnknownDynamicQuarantineTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            _ = try seedSafeV2AndBarrier(in: temporaryRoot, fileManager: fileManager)

            let recognizable = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: recognizable.appendingPathComponent("blobs", isDirectory: true),
                withIntermediateDirectories: true
            )
            let unknown = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: unknown, withIntermediateDirectories: true)
            try Data("not a recognized legacy vault".utf8).write(
                to: unknown.appendingPathComponent("notes.txt")
            )

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unrecognized Agent Activity legacy quarantine"))
            }

            XCTAssertTrue(fileManager.fileExists(atPath: recognizable.path))
            XCTAssertTrue(fileManager.fileExists(atPath: unknown.path))
        }

        func testQuarantineReplacementRacePreservesReplacementAndSiblingStores() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsQuarantineRaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            _ = try seedSafeV2AndBarrier(in: temporaryRoot, fileManager: fileManager)

            let quarantine = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2-\(UUID().uuidString)",
                isDirectory: true
            )
            let parkedQuarantine = temporaryRoot.appendingPathComponent(
                ".parked-owned-quarantine-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: quarantine.appendingPathComponent("blobs", isDirectory: true),
                withIntermediateDirectories: true
            )
            let retiredBytes = Data("retired-transcript-copy".utf8)
            try retiredBytes.write(to: quarantine.appendingPathComponent("blobs/source.blob"))

            let protected = try seedProtectedSiblingStores(
                in: temporaryRoot,
                fileManager: fileManager
            )
            let protectedEvents = try XCTUnwrap(protected["events"])
            let events = temporaryRoot.appendingPathComponent("events", isDirectory: true)
            var raced = false
            AppPaths.setOwnedRemovalTestHook { candidate in
                guard candidate == quarantine, !raced else { return }
                raced = true
                try fileManager.moveItem(at: candidate, to: parkedQuarantine)
                try fileManager.moveItem(at: events, to: candidate)
            }
            defer { AppPaths.setOwnedRemovalTestHook(nil) }

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            )

            XCTAssertTrue(raced)
            XCTAssertEqual(
                try Data(contentsOf: quarantine.appendingPathComponent("marker.bin")),
                protectedEvents
            )
            XCTAssertEqual(
                try Data(contentsOf: parkedQuarantine.appendingPathComponent("blobs/source.blob")),
                retiredBytes
            )
            try fileManager.moveItem(at: quarantine, to: events)
            try assertProtectedSiblingStores(
                protected,
                in: temporaryRoot,
                fileManager: fileManager
            )
        }

        func testMigrationTemporaryReplacementRacePreservesReplacementAndSiblingStores() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsMigrationTemporaryRaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createDirectory(
                at: legacy.appendingPathComponent("blobs", isDirectory: true),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(AgentActivityConfiguration.default).write(
                to: legacy.appendingPathComponent("configuration.json")
            )
            try encoder.encode(AgentActivityIndex()).write(
                to: legacy.appendingPathComponent("index.json")
            )
            let protected = try seedProtectedSiblingStores(
                in: temporaryRoot,
                fileManager: fileManager
            )
            let protectedEvents = try XCTUnwrap(protected["events"])
            let events = temporaryRoot.appendingPathComponent("events", isDirectory: true)
            var replacement: URL?
            AppPaths.setOwnedRemovalTestHook { candidate in
                guard replacement == nil,
                    candidate.lastPathComponent.hasPrefix(".configuration.json.migration-")
                else { return }
                try fileManager.moveItem(at: events, to: candidate)
                replacement = candidate
            }
            defer { AppPaths.setOwnedRemovalTestHook(nil) }

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            let replacementURL = try XCTUnwrap(replacement)
            XCTAssertEqual(
                try Data(contentsOf: replacementURL.appendingPathComponent("marker.bin")),
                protectedEvents
            )
            try fileManager.moveItem(at: replacementURL, to: events)
            try assertProtectedSiblingStores(
                protected,
                in: temporaryRoot,
                fileManager: fileManager
            )
        }

        func testSentinelCandidateReplacementRacePreservesReplacementAndSiblingStores() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsSentinelTemporaryRaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createDirectory(
                at: legacy.appendingPathComponent("blobs", isDirectory: true),
                withIntermediateDirectories: true
            )
            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(
                at: v2.appendingPathComponent("signals", isDirectory: true),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(AgentActivityConfiguration.default).write(
                to: v2.appendingPathComponent("configuration.json")
            )
            try encoder.encode(AgentActivityIndex()).write(
                to: v2.appendingPathComponent("index.json")
            )
            let protected = try seedProtectedSiblingStores(
                in: temporaryRoot,
                fileManager: fileManager
            )
            let protectedMemories = try XCTUnwrap(protected["memories"])
            let memories = temporaryRoot.appendingPathComponent("memories", isDirectory: true)
            var replacement: URL?
            AppPaths.setOwnedRemovalTestHook { candidate in
                guard replacement == nil,
                    candidate.lastPathComponent.hasPrefix(".agent-activity-v2-sentinel-")
                else { return }
                try fileManager.moveItem(at: memories, to: candidate)
                replacement = candidate
            }
            defer { AppPaths.setOwnedRemovalTestHook(nil) }

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            let replacementURL = try XCTUnwrap(replacement)
            XCTAssertEqual(
                try Data(contentsOf: replacementURL.appendingPathComponent("marker.bin")),
                protectedMemories
            )
            try fileManager.moveItem(at: replacementURL, to: memories)
            try assertProtectedSiblingStores(
                protected,
                in: temporaryRoot,
                fileManager: fileManager
            )
        }

        func testLegacyIndexFreeTextIsSanitizedAndMigratedIndexIsAcceptedByStore() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsIndexSanitizationTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createDirectory(
                at: legacy.appendingPathComponent("blobs", isDirectory: true),
                withIntermediateDirectories: true
            )

            let transcriptInjection = "verbatim transcript text must never migrate"
            let signalProviderSentinel = "PRIVATE-TRANSCRIPT-SIGNAL-KEY-MUST-NOT-MIGRATE"
            let handledAt = Date(timeIntervalSince1970: 1_787_472_100)
            let reference = AgentSourceReference(
                kind: .file,
                path: temporaryRoot.appendingPathComponent("original/session.jsonl").path
            )
            let entry = AgentSourceIndexEntry(
                id: "legacy-id",
                stableConversationID: "provider-controlled-session-id",
                watchedFolderID: "codex-folder",
                watchedFolderName: "Codex local history",
                provider: .codex,
                reference: reference,
                relativePath: "original/session.jsonl",
                sourceCreatedAt: Date(timeIntervalSince1970: 1_787_472_000),
                sourceModifiedAt: Date(timeIntervalSince1970: 1_787_472_100),
                firstIndexedAt: Date(timeIntervalSince1970: 1_787_472_100),
                lastObservedAt: Date(timeIntervalSince1970: 1_787_472_100),
                byteCount: 42,
                sha256: String(repeating: "a", count: 64),
                availability: .available,
                statusDetail: transcriptInjection
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(AgentActivityConfiguration.default).write(
                to: legacy.appendingPathComponent("configuration.json")
            )
            let encodedIndex = try encoder.encode(
                AgentActivityIndex(
                    entries: [entry],
                    lastHandledSignalByProvider: [AgentProvider.codex.rawValue: handledAt],
                    updatedAt: handledAt
                )
            )
            var rawIndex = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encodedIndex) as? [String: Any]
            )
            var rawEntries = try XCTUnwrap(rawIndex["entries"] as? [[String: Any]])
            rawEntries[0]["statusDetail"] = transcriptInjection
            rawEntries[0]["relativePath"] = transcriptInjection
            var rawReference = try XCTUnwrap(rawEntries[0]["reference"] as? [String: Any])
            rawReference["locator"] = transcriptInjection
            rawEntries[0]["reference"] = rawReference
            rawIndex["entries"] = rawEntries
            var rawSignalDates = try XCTUnwrap(
                rawIndex["lastHandledSignalByProvider"] as? [String: Any]
            )
            rawSignalDates[signalProviderSentinel] = try XCTUnwrap(
                rawSignalDates[AgentProvider.codex.rawValue]
            )
            rawIndex["lastHandledSignalByProvider"] = rawSignalDates
            let injectedIndex = try JSONSerialization.data(withJSONObject: rawIndex, options: [.sortedKeys])
            XCTAssertNotNil(injectedIndex.range(of: Data(transcriptInjection.utf8)))
            XCTAssertNotNil(injectedIndex.range(of: Data(signalProviderSentinel.utf8)))
            try injectedIndex.write(to: legacy.appendingPathComponent("index.json"))
            try Data(transcriptInjection.utf8).write(
                to: legacy.appendingPathComponent("blobs/transcript")
            )

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            let migratedData = try Data(contentsOf: v2.appendingPathComponent("index.json"))
            XCTAssertNil(migratedData.range(of: Data(transcriptInjection.utf8)))
            XCTAssertNil(migratedData.range(of: Data(signalProviderSentinel.utf8)))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let migrated = try decoder.decode(AgentActivityIndex.self, from: migratedData)
            XCTAssertEqual(migrated.entries.count, 1)
            XCTAssertEqual(
                migrated.lastHandledSignalByProvider,
                [AgentProvider.codex.rawValue: handledAt]
            )
            XCTAssertNil(migrated.entries.first?.statusDetail)
            XCTAssertEqual(migrated.entries.first?.reference, reference)
            XCTAssertEqual(migrated.entries.first?.relativePath, "session.jsonl")
            XCTAssertTrue(
                try AgentActivityStore(rootDirectory: v2).indexIsValid(maximumEntries: 50_000)
            )
        }

        func testLegacyIndexSourceIdentityRequiresCompleteValidTuple() throws {
            let fileManager = FileManager.default
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

            for invalidField in ["sourceInode", "sourceChangedNanoseconds"] {
                let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                    "AppPathsPartialIdentity-\(invalidField)-\(UUID().uuidString)",
                    isDirectory: true
                )
                defer { try? fileManager.removeItem(at: temporaryRoot) }
                let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
                try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
                try encoder.encode(AgentActivityConfiguration.default).write(
                    to: legacy.appendingPathComponent("configuration.json")
                )
                let entry = sourceIdentityFixtureEntry(root: temporaryRoot)
                let encoded = try encoder.encode(AgentActivityIndex(entries: [entry]))
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                )
                var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
                if invalidField == "sourceInode" {
                    entries[0].removeValue(forKey: invalidField)
                } else {
                    entries[0][invalidField] = 1_000_000_000
                }
                object["entries"] = entries
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
                    to: legacy.appendingPathComponent("index.json")
                )

                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )

                let migratedIndex = temporaryRoot.appendingPathComponent(
                    "agent-activity-v2/index.json"
                )
                XCTAssertFalse(
                    fileManager.fileExists(atPath: migratedIndex.path),
                    "An incomplete or invalid source identity tuple must never migrate."
                )
            }

            let validRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsCompleteIdentity-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: validRoot) }
            let validLegacy = validRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createDirectory(at: validLegacy, withIntermediateDirectories: true)
            try encoder.encode(AgentActivityConfiguration.default).write(
                to: validLegacy.appendingPathComponent("configuration.json")
            )
            let validEntry = sourceIdentityFixtureEntry(root: validRoot)
            try encoder.encode(AgentActivityIndex(entries: [validEntry])).write(
                to: validLegacy.appendingPathComponent("index.json")
            )

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: validRoot,
                fileManager: fileManager
            )

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let migrated = try decoder.decode(
                AgentActivityIndex.self,
                from: Data(
                    contentsOf: validRoot.appendingPathComponent("agent-activity-v2/index.json")
                )
            )
            let migratedEntry = try XCTUnwrap(migrated.entries.first)
            XCTAssertEqual(migratedEntry.sourceDevice, validEntry.sourceDevice)
            XCTAssertEqual(migratedEntry.sourceInode, validEntry.sourceInode)
            XCTAssertEqual(migratedEntry.sourceChangedSeconds, validEntry.sourceChangedSeconds)
            XCTAssertEqual(
                migratedEntry.sourceChangedNanoseconds,
                validEntry.sourceChangedNanoseconds
            )
        }

        func testAgentActivityMigrationPreservesOpenCodeContainerIdentityAndRootStatus() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsOpenCodeContainerMigration-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(AgentActivityConfiguration.default).write(
                to: legacy.appendingPathComponent("configuration.json")
            )
            let observedAt = Date(timeIntervalSince1970: 1_787_472_100)
            let database = temporaryRoot.appendingPathComponent(".local/share/opencode/opencode.db")
            let entry = AgentSourceIndexEntry(
                id: "opencode-entry",
                stableConversationID: "opencode-session",
                watchedFolderID: "opencode-folder",
                watchedFolderName: "OpenCode",
                provider: .openCode,
                reference: AgentSourceReference(
                    kind: .sqliteConversation,
                    path: database.path,
                    locator: "opencode-session"
                ),
                relativePath: "opencode.db",
                sourceCreatedAt: observedAt.addingTimeInterval(-100),
                sourceModifiedAt: observedAt.addingTimeInterval(-10),
                firstIndexedAt: observedAt,
                lastObservedAt: observedAt,
                byteCount: 512,
                sha256: String(repeating: "b", count: 64),
                sourceDevice: 12,
                sourceInode: 34,
                sourceChangedSeconds: 1_787_472_099,
                sourceChangedNanoseconds: 123_456_789,
                sourceContainerByteCount: 4_096,
                sourceContainerModifiedSeconds: 1_787_472_098,
                sourceContainerModifiedNanoseconds: 987_654_321
            )
            let expectedRootStatus = AgentFolderRootStatus(
                availability: .inaccessible,
                changedAt: observedAt
            )
            let index = AgentActivityIndex(
                entries: [entry],
                rootStatusByFolder: [entry.watchedFolderID: expectedRootStatus],
                updatedAt: observedAt
            )
            try encoder.encode(index).write(to: legacy.appendingPathComponent("index.json"))

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            let migratedURL = temporaryRoot.appendingPathComponent("agent-activity-v2/index.json")
            let migratedBytes = try Data(contentsOf: migratedURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let migrated = try decoder.decode(AgentActivityIndex.self, from: migratedBytes)
            let migratedEntry = try XCTUnwrap(migrated.entries.first)
            XCTAssertEqual(migratedEntry.sourceContainerByteCount, 4_096)
            XCTAssertEqual(migratedEntry.sourceContainerModifiedSeconds, 1_787_472_098)
            XCTAssertEqual(migratedEntry.sourceContainerModifiedNanoseconds, 987_654_321)
            XCTAssertEqual(migrated.rootStatusByFolder[entry.watchedFolderID], expectedRootStatus)
            XCTAssertTrue(
                try AgentActivityStore(rootDirectory: migratedURL.deletingLastPathComponent())
                    .indexIsValid(maximumEntries: 50_000)
            )

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )
            XCTAssertEqual(try Data(contentsOf: migratedURL), migratedBytes)
        }

        func testPreparedOldV2IndexWithoutRootStatusIsNormalizedOnce() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsOldV2RootStatusNormalization-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            let seeded = try seedSafeV2AndBarrier(in: temporaryRoot, fileManager: fileManager)
            var oldObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: seeded.index) as? [String: Any]
            )
            oldObject.removeValue(forKey: "rootStatusByFolder")
            let oldBytes = try JSONSerialization.data(withJSONObject: oldObject, options: [.sortedKeys])
            try oldBytes.write(to: seeded.indexURL)

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            let normalizedBytes = try Data(contentsOf: seeded.indexURL)
            let normalizedObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: normalizedBytes) as? [String: Any]
            )
            XCTAssertNotNil(normalizedObject["rootStatusByFolder"] as? [String: Any])
            XCTAssertNotEqual(normalizedBytes, oldBytes)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            XCTAssertTrue(
                try decoder.decode(AgentActivityIndex.self, from: normalizedBytes)
                    .rootStatusByFolder.isEmpty
            )

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )
            XCTAssertEqual(try Data(contentsOf: seeded.indexURL), normalizedBytes)
        }

        func testLegacyIndexContainerIdentityRequiresCompleteValidTuple() throws {
            let fileManager = FileManager.default
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for invalidField in [
                "sourceContainerByteCount", "sourceContainerModifiedNanoseconds",
            ] {
                let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                    "AppPathsPartialContainerIdentity-\(invalidField)-\(UUID().uuidString)",
                    isDirectory: true
                )
                defer { try? fileManager.removeItem(at: temporaryRoot) }
                let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
                try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
                try encoder.encode(AgentActivityConfiguration.default).write(
                    to: legacy.appendingPathComponent("configuration.json")
                )
                var entry = sourceIdentityFixtureEntry(root: temporaryRoot)
                entry.sourceContainerByteCount = 4_096
                entry.sourceContainerModifiedSeconds = 1_787_472_098
                entry.sourceContainerModifiedNanoseconds = 987_654_321
                let encoded = try encoder.encode(AgentActivityIndex(entries: [entry]))
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                )
                var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
                if invalidField == "sourceContainerByteCount" {
                    entries[0].removeValue(forKey: invalidField)
                } else {
                    entries[0][invalidField] = 1_000_000_000
                }
                object["entries"] = entries
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
                    to: legacy.appendingPathComponent("index.json")
                )

                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )

                XCTAssertFalse(
                    fileManager.fileExists(
                        atPath: temporaryRoot.appendingPathComponent("agent-activity-v2/index.json").path
                    ),
                    "An incomplete or invalid source container identity tuple must never migrate."
                )
            }
        }

        func testRetiredFixedQuarantineWithLinkedOrUnexpectedContentsIsPreserved() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnsafeRetiredQuarantineTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            _ = try seedSafeV2AndBarrier(in: temporaryRoot, fileManager: fileManager)

            let quarantine = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: quarantine.appendingPathComponent("manifests", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("legacy configuration".utf8).write(
                to: quarantine.appendingPathComponent("configuration.json")
            )
            try Data("legacy index".utf8).write(
                to: quarantine.appendingPathComponent("index.json")
            )
            let external = temporaryRoot.appendingPathComponent("external.txt")
            try Data("must survive".utf8).write(to: external)
            try fileManager.createSymbolicLink(
                at: quarantine.appendingPathComponent("blobs"),
                withDestinationURL: external
            )

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            )

            XCTAssertTrue(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertEqual(try Data(contentsOf: external), Data("must survive".utf8))
        }

        func testMigrationRejectsOversizedConfigurationAndInvalidIndexInsteadOfCopyingThem() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsInvalidMetadataTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 1 * 1_024 * 1_024 + 1).write(
                to: legacy.appendingPathComponent("configuration.json")
            )
            try Data(
                #"{"schemaVersion":2,"entries":[],"transcript":"must-not-migrate"}"#.utf8
            ).write(to: legacy.appendingPathComponent("index.json"))

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            XCTAssertFalse(fileManager.fileExists(atPath: v2.appendingPathComponent("configuration.json").path))
            XCTAssertFalse(fileManager.fileExists(atPath: v2.appendingPathComponent("index.json").path))
            var legacyIsDirectory = ObjCBool(true)
            XCTAssertTrue(fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory))
            XCTAssertFalse(legacyIsDirectory.boolValue)
        }

        func testValidLegacyMetadataRepairsCorruptV2InsteadOfLettingItWin() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsCorruptV2Tests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: v2, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let configuration = AgentActivityConfiguration(
                scanIntervalSeconds: 12,
                fullDiscoveryIntervalSeconds: 1_200,
                maximumFileBytes: 32 * 1_024 * 1_024,
                maximumIndexEntries: 2_000
            )
            let index = AgentActivityIndex(updatedAt: Date(timeIntervalSince1970: 1_787_472_100))
            let legacyConfiguration = try encoder.encode(configuration)
            let validConfiguration = try encoder.encode(configuration.validated())
            let validIndex = try encoder.encode(index)
            try legacyConfiguration.write(to: legacy.appendingPathComponent("configuration.json"))
            try validIndex.write(to: legacy.appendingPathComponent("index.json"))

            let corruptMarker = Data("CORRUPT-V2-MUST-NOT-WIN".utf8)
            try corruptMarker.write(to: v2.appendingPathComponent("configuration.json"))
            try corruptMarker.write(to: v2.appendingPathComponent("index.json"))

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            XCTAssertEqual(
                try Data(contentsOf: v2.appendingPathComponent("configuration.json")),
                validConfiguration
            )
            XCTAssertEqual(try Data(contentsOf: v2.appendingPathComponent("index.json")), validIndex)
            XCTAssertNil(
                try Data(contentsOf: v2.appendingPathComponent("configuration.json"))
                    .range(of: corruptMarker)
            )
            XCTAssertNil(
                try Data(contentsOf: v2.appendingPathComponent("index.json"))
                    .range(of: corruptMarker)
            )
            XCTAssertTrue(try AgentActivityStore(rootDirectory: v2).configurationIsValid())
            XCTAssertTrue(try AgentActivityStore(rootDirectory: v2).indexIsValid(maximumEntries: 2_000))
            XCTAssertTrue(try isRegularFile(legacy, fileManager: fileManager))
            XCTAssertFalse(
                try fileManager.contentsOfDirectory(atPath: temporaryRoot.path).contains {
                    $0.contains("invalid-v2-")
                        || $0.hasPrefix(".agent-activity-legacy-quarantine-v2-")
                }
            )
        }

        func testCorruptV2WithoutValidLegacyIsDiscardedAndStoreStartsFailClosed() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsCorruptOnlyTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: v2, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: v2.appendingPathComponent("configuration.json"))
            try Data("not-json".utf8).write(to: v2.appendingPathComponent("index.json"))

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            XCTAssertFalse(fileManager.fileExists(atPath: v2.appendingPathComponent("configuration.json").path))
            XCTAssertFalse(fileManager.fileExists(atPath: v2.appendingPathComponent("index.json").path))
            let store = try AgentActivityStore(rootDirectory: v2)
            XCTAssertTrue(store.configurationIsValid())
            XCTAssertTrue(store.indexIsValid(maximumEntries: 10_000))
            XCTAssertTrue(try isRegularFile(legacy, fileManager: fileManager))
        }

        func testAgentActivityPreparationFailureCreatesOtherStoresAndBarrierButThrows() throws {
            enum InjectedFailure: Error { case migration }

            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsFailureIsolationTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            XCTAssertThrowsError(
                try AppPaths.prepareApplicationStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager,
                    agentActivityPreparation: { _, _ in throw InjectedFailure.migration }
                )
            )

            for relativePath in [
                "events", "seals", "receipts", "shares", "semantic", "memories",
                "apple-screen-time", "chatgpt/history", "chatgpt/recaps", "chatgpt/runs",
                "chatgpt/codex-home",
            ] {
                var isDirectory = ObjCBool(false)
                XCTAssertTrue(
                    fileManager.fileExists(
                        atPath: temporaryRoot.appendingPathComponent(relativePath).path,
                        isDirectory: &isDirectory
                    ),
                    relativePath
                )
                XCTAssertTrue(isDirectory.boolValue, relativePath)
            }

            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: false)
            XCTAssertNoThrow(try AgentActivityStore(rootDirectory: v2))
            XCTAssertTrue(try isRegularFile(legacy, fileManager: fileManager))
            XCTAssertThrowsError(
                try fileManager.createDirectory(
                    at: legacy.appendingPathComponent("blobs", isDirectory: true),
                    withIntermediateDirectories: true
                )
            )
        }

        func testAgentActivityContainmentFailureIsReportedAndLeavesLegacyVaultUntouched() throws {
            enum InjectedFailure: Error { case migration }

            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsContainmentFailureTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(
                at: legacy.appendingPathComponent("blobs", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(at: v2, withIntermediateDirectories: true)
            try Data("not-a-directory".utf8).write(to: v2.appendingPathComponent("signals"))

            XCTAssertThrowsError(
                try AppPaths.prepareApplicationStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager,
                    agentActivityPreparation: { _, _ in throw InjectedFailure.migration }
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("containment failed"))
            }

            var legacyIsDirectory = ObjCBool(false)
            XCTAssertTrue(fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory))
            XCTAssertTrue(legacyIsDirectory.boolValue)
            XCTAssertTrue(fileManager.fileExists(atPath: legacy.appendingPathComponent("blobs").path))
            for relativePath in ["events", "memories", "seals", "apple-screen-time"] {
                var isDirectory = ObjCBool(false)
                XCTAssertTrue(
                    fileManager.fileExists(
                        atPath: temporaryRoot.appendingPathComponent(relativePath).path,
                        isDirectory: &isDirectory
                    )
                )
                XCTAssertTrue(isDirectory.boolValue)
            }
        }

        func testExistingVerifiedBarrierIsPreservedAndTightenedToOwnerOnly() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsBarrierTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

            let barrier = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: false)
            let originalBytes = Data(
                "Goalong History Agent Activity v2 safety barrier. Legacy storage is disabled.\n".utf8
            )
            XCTAssertTrue(
                fileManager.createFile(
                    atPath: barrier.path,
                    contents: originalBytes,
                    attributes: [.posixPermissions: 0o666]
                )
            )
            try fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: barrier.path)

            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )
            try AppPaths.prepareAgentActivityStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            XCTAssertEqual(try Data(contentsOf: barrier), originalBytes)
            let permissions = try XCTUnwrap(
                fileManager.attributesOfItem(atPath: barrier.path)[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }

        func testPreparationDoesNotFollowLegacySymlinkOrDeleteUnownedQuarantines() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsSymlinkTests-\(UUID().uuidString)",
                isDirectory: true
            )
            let externalTarget = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsExternalTarget-\(UUID().uuidString)",
                isDirectory: true
            )
            defer {
                try? fileManager.removeItem(at: temporaryRoot)
                try? fileManager.removeItem(at: externalTarget)
            }
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: externalTarget, withIntermediateDirectories: true)

            let externalBytes = Data("must-remain-outside-migration".utf8)
            try externalBytes.write(to: externalTarget.appendingPathComponent("configuration.json"))
            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createSymbolicLink(at: legacy, withDestinationURL: externalTarget)

            let quarantine = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2",
                isDirectory: true
            )
            try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let quarantineBytes = Data("unowned-quarantine-must-survive".utf8)
            try quarantineBytes.write(to: quarantine.appendingPathComponent("blob"))
            let lookalikeQuarantine = temporaryRoot.appendingPathComponent(
                ".agent-activity-legacy-quarantine-v2-unowned",
                isDirectory: true
            )
            try fileManager.createDirectory(at: lookalikeQuarantine, withIntermediateDirectories: true)
            try quarantineBytes.write(to: lookalikeQuarantine.appendingPathComponent("blob"))
            let unownedSentinelCandidate = temporaryRoot.appendingPathComponent(
                ".agent-activity-v2-sentinel-unowned",
                isDirectory: false
            )
            try quarantineBytes.write(to: unownedSentinelCandidate)

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unrecognized Agent Activity legacy quarantine"))
            }

            XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("blob")), quarantineBytes)
            XCTAssertEqual(
                try Data(contentsOf: lookalikeQuarantine.appendingPathComponent("blob")),
                quarantineBytes
            )
            XCTAssertEqual(try Data(contentsOf: unownedSentinelCandidate), quarantineBytes)
            var legacyIsDirectory = ObjCBool(false)
            XCTAssertTrue(fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory))
            XCTAssertFalse(legacyIsDirectory.boolValue)
            XCTAssertEqual(
                try Data(contentsOf: externalTarget.appendingPathComponent("configuration.json")),
                externalBytes
            )
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: temporaryRoot.appendingPathComponent("agent-activity-v2/configuration.json").path
                ),
                "A legacy symlink must never be followed for migration"
            )
        }

        func testActiveLegacyDirectoryWithUnknownContentIsPreservedFailClosed() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnknownActiveLegacyTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let legacy = temporaryRoot.appendingPathComponent("agent-activity", isDirectory: true)
            try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
            let unknownBytes = Data("user-owned-ambiguous-content-must-survive".utf8)
            try unknownBytes.write(to: legacy.appendingPathComponent("notes.txt"))

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unrecognized Agent Activity"))
            }

            let barrier = temporaryRoot.appendingPathComponent("agent-activity")
            XCTAssertEqual(
                try Data(contentsOf: barrier),
                Data(
                    "Goalong History Agent Activity v2 safety barrier. Legacy storage is disabled.\n".utf8
                )
            )
            let preservedQuarantines = try fileManager.contentsOfDirectory(
                at: temporaryRoot,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".agent-activity-legacy-quarantine-v2-") }
            XCTAssertEqual(preservedQuarantines.count, 1)
            XCTAssertEqual(
                try Data(contentsOf: try XCTUnwrap(preservedQuarantines.first).appendingPathComponent("notes.txt")),
                unknownBytes
            )

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            )
            XCTAssertEqual(
                try Data(contentsOf: try XCTUnwrap(preservedQuarantines.first).appendingPathComponent("notes.txt")),
                unknownBytes
            )
        }

        func testProcessPreparationGateRunsOnceAndRetriesOnlyAfterFailure() throws {
            enum InjectedFailure: Error { case firstAttempt }

            let gate = AppPaths.ProcessPreparationGate()
            var attemptCount = 0
            XCTAssertThrowsError(
                try gate.perform {
                    attemptCount += 1
                    throw InjectedFailure.firstAttempt
                }
            )

            try gate.perform { attemptCount += 1 }
            try gate.perform {
                XCTFail("A successful process preparation must be reused")
            }
            XCTAssertEqual(attemptCount, 2)
        }

        func testLightweightHookPreparationDoesNotDecodeOrRewriteMetadata() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsLightHookTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(at: v2, withIntermediateDirectories: true)
            let configuration = Data("deliberately-not-decoded-configuration".utf8)
            let index = Data("deliberately-not-decoded-index".utf8)
            let configurationURL = v2.appendingPathComponent("configuration.json")
            let indexURL = v2.appendingPathComponent("index.json")
            try configuration.write(to: configurationURL)
            try index.write(to: indexURL)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: indexURL.path
            )
            let indexAttributesBefore = try fileManager.attributesOfItem(atPath: indexURL.path)

            let prepared = try AppPaths.prepareAgentActivityHookStorage(
                applicationSupportDirectory: temporaryRoot,
                fileManager: fileManager
            )

            XCTAssertEqual(prepared, v2.standardizedFileURL)
            XCTAssertEqual(try Data(contentsOf: configurationURL), configuration)
            XCTAssertEqual(try Data(contentsOf: indexURL), index)
            let indexAttributesAfter = try fileManager.attributesOfItem(atPath: indexURL.path)
            XCTAssertEqual(
                indexAttributesAfter[.systemFileNumber] as? NSNumber,
                indexAttributesBefore[.systemFileNumber] as? NSNumber
            )
            XCTAssertEqual(
                indexAttributesAfter[.modificationDate] as? Date,
                indexAttributesBefore[.modificationDate] as? Date
            )

            let barrier = temporaryRoot.appendingPathComponent("agent-activity")
            XCTAssertEqual(
                try Data(contentsOf: barrier),
                Data(
                    "Goalong History Agent Activity v2 safety barrier. Legacy storage is disabled.\n".utf8
                )
            )
            var signalsIsDirectory = ObjCBool(false)
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: v2.appendingPathComponent("signals").path,
                    isDirectory: &signalsIsDirectory
                )
            )
            XCTAssertTrue(signalsIsDirectory.boolValue)
            for unrelatedStore in ["events", "semantic", "memories", "seals", "apple-screen-time"] {
                XCTAssertFalse(
                    fileManager.fileExists(
                        atPath: temporaryRoot.appendingPathComponent(unrelatedStore).path
                    ),
                    "A hook must not prepare unrelated stores"
                )
            }
        }

        func testLightweightHookPreparationRejectsLegacyVaultWithoutMigratingIt() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnsafeHookVaultTests-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporaryRoot) }

            let legacyBlob = temporaryRoot.appendingPathComponent(
                "agent-activity/blobs/fixture/transcript",
                isDirectory: false
            )
            try fileManager.createDirectory(
                at: legacyBlob.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let originalBytes = Data("legacy-source-must-remain-untouched".utf8)
            try originalBytes.write(to: legacyBlob)

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityHookStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("verified barrier"))
            }
            XCTAssertEqual(try Data(contentsOf: legacyBlob), originalBytes)
            var legacyIsDirectory = ObjCBool(false)
            XCTAssertTrue(fileManager.fileExists(atPath: legacyBlob.path, isDirectory: &legacyIsDirectory))
            XCTAssertFalse(legacyIsDirectory.boolValue)
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: temporaryRoot.appendingPathComponent("agent-activity-v2").path
                )
            )
        }

        func testLightweightHookPreparationRejectsSymlinkedSignalsAndForbiddenVaultNames() throws {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnsafeHookSignalsTests-\(UUID().uuidString)",
                isDirectory: true
            )
            let external = fileManager.temporaryDirectory.appendingPathComponent(
                "AppPathsUnsafeHookExternal-\(UUID().uuidString)",
                isDirectory: true
            )
            defer {
                try? fileManager.removeItem(at: temporaryRoot)
                try? fileManager.removeItem(at: external)
            }
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
            let externalMarker = external.appendingPathComponent("must-remain-empty")
            let v2 = temporaryRoot.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(at: v2, withIntermediateDirectories: true)
            try Data(
                "Goalong History Agent Activity v2 safety barrier. Legacy storage is disabled.\n".utf8
            ).write(to: temporaryRoot.appendingPathComponent("agent-activity"))
            try fileManager.createSymbolicLink(
                at: v2.appendingPathComponent("signals"),
                withDestinationURL: external
            )

            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityHookStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            )
            XCTAssertFalse(fileManager.fileExists(atPath: externalMarker.path))

            try fileManager.removeItem(at: v2.appendingPathComponent("signals"))
            try fileManager.createDirectory(
                at: v2.appendingPathComponent("blobs"),
                withIntermediateDirectories: true
            )
            XCTAssertThrowsError(
                try AppPaths.prepareAgentActivityHookStorage(
                    applicationSupportDirectory: temporaryRoot,
                    fileManager: fileManager
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("hook storage is unsafe"))
            }
            XCTAssertTrue(fileManager.fileExists(atPath: v2.appendingPathComponent("blobs").path))
        }

        private func sourceIdentityFixtureEntry(root: URL) -> AgentSourceIndexEntry {
            let source = root.appendingPathComponent("original/session.jsonl")
            return AgentSourceIndexEntry(
                id: "legacy-entry",
                stableConversationID: "provider-session",
                watchedFolderID: "legacy-folder",
                watchedFolderName: "Codex",
                provider: .codex,
                reference: AgentSourceReference(kind: .file, path: source.path),
                relativePath: "original/session.jsonl",
                sourceCreatedAt: Date(timeIntervalSince1970: 1_787_472_000),
                sourceModifiedAt: Date(timeIntervalSince1970: 1_787_472_100),
                firstIndexedAt: Date(timeIntervalSince1970: 1_787_472_100),
                lastObservedAt: Date(timeIntervalSince1970: 1_787_472_100),
                byteCount: 42,
                sha256: String(repeating: "a", count: 64),
                sourceDevice: 12,
                sourceInode: 34,
                sourceChangedSeconds: 1_787_472_099,
                sourceChangedNanoseconds: 123_456_789,
                availability: .available
            )
        }

        private func recursiveRelativePaths(in root: URL, fileManager: FileManager) throws -> [String] {
            guard let enumerator = fileManager.enumerator(atPath: root.path) else {
                return []
            }
            return enumerator.compactMap { $0 as? String }.sorted()
        }

        private func seedProtectedSiblingStores(
            in root: URL,
            fileManager: FileManager
        ) throws -> [String: Data] {
            let protected = [
                "events": Data("events-must-survive".utf8),
                "memories": Data("memories-must-survive".utf8),
            ]
            for (name, bytes) in protected {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent("marker.bin"))
            }
            return protected
        }

        private func assertProtectedSiblingStores(
            _ protected: [String: Data],
            in root: URL,
            fileManager _: FileManager
        ) throws {
            for (name, bytes) in protected {
                XCTAssertEqual(
                    try Data(contentsOf: root.appendingPathComponent("\(name)/marker.bin")),
                    bytes,
                    name
                )
            }
        }

        private func isRegularFile(_ url: URL, fileManager: FileManager) throws -> Bool {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType == .typeRegular
        }

        private func permissions(_ url: URL) throws -> Int {
            let value = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber
            )
            return value.intValue & 0o777
        }

        private func signalJSON(provider: String, eventName: String) -> Data {
            Data(
                """
                {"schemaVersion":1,"provider":"\(provider)","eventName":"\(eventName)","signaledAt":"2026-08-23T20:00:00Z","processIdentifier":123,"discardedPayloadBytes":456}
                """.utf8
            )
        }

        private func seedSafeV2AndBarrier(
            in root: URL,
            fileManager: FileManager
        ) throws -> (
            barrier: URL,
            configurationURL: URL,
            configuration: Data,
            indexURL: URL,
            index: Data
        ) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let barrier = root.appendingPathComponent("agent-activity", isDirectory: false)
            try Data(
                "Goalong History Agent Activity v2 safety barrier. Legacy storage is disabled.\n".utf8
            ).write(to: barrier)
            let v2 = root.appendingPathComponent("agent-activity-v2", isDirectory: true)
            try fileManager.createDirectory(
                at: v2.appendingPathComponent("signals", isDirectory: true),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let configuration = try encoder.encode(AgentActivityConfiguration.default)
            let index = try encoder.encode(
                AgentActivityIndex(updatedAt: Date(timeIntervalSince1970: 1_787_472_100))
            )
            let configurationURL = v2.appendingPathComponent("configuration.json")
            let indexURL = v2.appendingPathComponent("index.json")
            try configuration.write(to: configurationURL)
            try index.write(to: indexURL)
            return (barrier, configurationURL, configuration, indexURL, index)
        }
    }
#endif
