#if os(macOS)
    import AgentActivity
    import Combine
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class AgentActivityDiscoveryConsentTests: XCTestCase {
        func testBlankConfigurationDiscoversDefaultSourceDisabledAndPerformsNoDirectRead() throws {
            let fixture = try makeFixture("blank-consent")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let sourceRoot = fixture.container.appendingPathComponent("Home/.codex", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let source = sourceRoot.appendingPathComponent("session.jsonl", isDirectory: false)
            let transcript = "BLANK_CONFIG_TRANSCRIPT_MUST_NOT_BE_READ"
            try Data(transcript.utf8).write(to: source)
            let discovered = defaultFolder(path: sourceRoot, provider: .codex)

            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [discovered] in [discovered] },
                onCaptured: { _ in XCTFail("A disabled discovered source must not be read") }
            )
            XCTAssertEqual(runtime.configuration.watchedFolders.count, 1)
            XCTAssertFalse(runtime.configuration.watchedFolders[0].isEnabled)

            let store = try AgentActivityStore(rootDirectory: fixture.metadata)
            let entry = makeEntry(reference: AgentSourceReference(kind: .file, path: source.path), folder: discovered)
            _ = try store.upsert(AgentCaptureRecord(index: entry, isAnalyzed: false), maximumEntries: 100)
            XCTAssertThrowsError(try runtime.directRead(entryID: entry.id))
            runtime.start()
            runtime.stop()
            XCTAssertNil(try Data(contentsOf: store.indexFile).range(of: Data(transcript.utf8)))
        }

        func testUpgradeKeepsExistingAuthorizedSourceActiveAndAddsNewProviderDisabled() throws {
            let fixture = try makeFixture("upgrade-new-provider")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let codexRoot = fixture.container.appendingPathComponent("Home/.codex", isDirectory: true)
            let claudeRoot = fixture.container.appendingPathComponent("Home/.claude", isDirectory: true)
            try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
            let codex = defaultFolder(path: codexRoot, provider: .codex)
            let claude = defaultFolder(path: claudeRoot, provider: .claudeCode)
            let store = try AgentActivityStore(rootDirectory: fixture.metadata)
            _ = try store.saveConfiguration(AgentActivityConfiguration(watchedFolders: [codex]))

            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [codex, claude] in [codex, claude] },
                onCaptured: { _ in }
            )
            let folders = Dictionary(
                uniqueKeysWithValues: runtime.configuration.watchedFolders.map {
                    ($0.provider, $0)
                })
            XCTAssertTrue(try XCTUnwrap(folders[.codex]).isEnabled)
            XCTAssertFalse(try XCTUnwrap(folders[.claudeCode]).isEnabled)
            runtime.stop()
        }

        func testRemovedDefaultSourceStaysSuppressedAcrossRuntimeReconstructionUntilExplicitReadd() throws {
            let fixture = try makeFixture("removed-reconstruction")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let source = fixture.container.appendingPathComponent("Home/.codex", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let discovered = defaultFolder(path: source, provider: .codex)
            let discovery = { [discovered] in [discovered] }

            var first: AgentActivityRuntime? = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: discovery,
                onCaptured: { _ in }
            )
            XCTAssertEqual(first?.configuration.watchedFolders.map(\.id), [discovered.id])
            XCTAssertFalse(first?.configuration.watchedFolders[0].isEnabled ?? true)
            first?.removeFolder(id: discovered.id)
            first?.stop()
            first = nil

            let persistedAfterRemoval = try AgentActivityStore(rootDirectory: fixture.metadata).loadConfiguration()
            XCTAssertTrue(persistedAfterRemoval.watchedFolders.isEmpty)
            XCTAssertTrue(persistedAfterRemoval.discoveryTombstones.contains { $0.sourceID == discovered.id })

            var reconstructed: AgentActivityRuntime? = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: discovery,
                onCaptured: { _ in }
            )
            XCTAssertTrue(reconstructed?.configuration.watchedFolders.isEmpty == true)
            XCTAssertTrue(
                reconstructed?.configuration.discoveryTombstones.contains {
                    $0.sourceID == discovered.id
                } == true)

            reconstructed?.addFolder(source, provider: .codex)
            reconstructed?.stop()
            reconstructed = nil

            let afterExplicitReadd = try AgentActivityStore(rootDirectory: fixture.metadata).loadConfiguration()
            XCTAssertEqual(afterExplicitReadd.watchedFolders.count, 1)
            XCTAssertTrue(afterExplicitReadd.watchedFolders[0].isEnabled)
            XCTAssertFalse(afterExplicitReadd.discoveryTombstones.contains { $0.sourceID == discovered.id })

            let finalRuntime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: discovery,
                onCaptured: { _ in }
            )
            XCTAssertEqual(finalRuntime.configuration.watchedFolders.count, 1)
            XCTAssertTrue(finalRuntime.configuration.discoveryTombstones.isEmpty)
            finalRuntime.stop()
        }

        func testDisabledDefaultSourceRemainsDisabledAfterRelaunchAndExplicitEnableClearsTombstone() throws {
            let fixture = try makeFixture("disabled-reconstruction")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let source = fixture.container.appendingPathComponent("Home/.claude", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let discovered = defaultFolder(path: source, provider: .claudeCode)
            let discovery = { [discovered] in [discovered] }

            var first: AgentActivityRuntime? = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: discovery,
                onCaptured: { _ in }
            )
            first?.setFolderEnabled(false, id: discovered.id)
            first?.stop()
            first = nil

            let reconstructed = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: discovery,
                onCaptured: { _ in }
            )
            XCTAssertEqual(reconstructed.configuration.watchedFolders.count, 1)
            XCTAssertFalse(reconstructed.configuration.watchedFolders[0].isEnabled)
            XCTAssertTrue(
                reconstructed.configuration.discoveryTombstones.contains {
                    $0.sourceID == discovered.id
                })

            reconstructed.setFolderEnabled(true, id: discovered.id)
            reconstructed.stop()
            let enabled = try AgentActivityStore(rootDirectory: fixture.metadata).loadConfiguration()
            XCTAssertTrue(enabled.watchedFolders[0].isEnabled)
            XCTAssertTrue(enabled.discoveryTombstones.isEmpty)
        }

        func testExplicitCommonSourceDetectionReallowsSuppressedSource() throws {
            let fixture = try makeFixture("detect-reallow")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let source = fixture.container.appendingPathComponent("Home/.codex", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let discovered = defaultFolder(path: source, provider: .codex)
            let discovery = { [discovered] in [discovered] }
            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: discovery,
                onCaptured: { _ in }
            )
            runtime.removeFolder(id: discovered.id)
            runtime.detectCommonSources()
            runtime.stop()

            XCTAssertEqual(runtime.configuration.watchedFolders.map(\.id), [discovered.id])
            XCTAssertTrue(runtime.configuration.discoveryTombstones.isEmpty)
        }

        func testDiscoveryRejectsFinalAndAncestorSymlinksBeneathHome() throws {
            let fixture = try makeFixture("symlink-boundary")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let home = fixture.container.appendingPathComponent("Home", isDirectory: true)
            let outside = fixture.container.appendingPathComponent("Outside", isDirectory: true)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".codex", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outside.appendingPathComponent(".claude", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: home.appendingPathComponent(".claude", isDirectory: true),
                withDestinationURL: outside.appendingPathComponent(".claude", isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: outside.appendingPathComponent(
                    "Library/Application Support/Cursor/User/workspaceStorage",
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: home.appendingPathComponent("Library", isDirectory: true),
                withDestinationURL: outside.appendingPathComponent("Library", isDirectory: true)
            )

            let providers = Set(AgentDefaultSourceDiscovery.discover(homeDirectory: home).map(\.provider))
            XCTAssertEqual(providers, [.codex])
        }

        func testMergeDeduplicatesPhysicalAliasesAndPreservesCaseSensitivePaths() throws {
            let fixture = try makeFixture("physical-dedup")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let upper = fixture.container.appendingPathComponent("HistoryCase", isDirectory: true)
            try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
            let lower = upper.deletingLastPathComponent().appendingPathComponent("historycase", isDirectory: true)
            let caseSensitive = try XCTUnwrap(
                upper.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                    .volumeSupportsCaseSensitiveNames
            )

            let configured = AgentWatchedFolder(
                id: "configured",
                displayName: "Configured",
                path: upper.path,
                provider: .codex
            )
            let discovered = AgentWatchedFolder(
                id: "discovered",
                displayName: "Discovered",
                path: lower.path,
                provider: .codex
            )
            let merged = AgentDefaultSourceDiscovery.merging(
                configuration: AgentActivityConfiguration(watchedFolders: [configured]),
                discovered: [discovered]
            )
            XCTAssertEqual(merged.watchedFolders.count, caseSensitive ? 2 : 1)
            XCTAssertEqual(merged.watchedFolders.first?.id, configured.id)
            if caseSensitive {
                XCTAssertNotEqual(
                    AgentDefaultSourceDiscovery.stableID(provider: .codex, path: upper.path),
                    AgentDefaultSourceDiscovery.stableID(provider: .codex, path: lower.path)
                )
            }
        }

        func testCaseDistinctTombstoneDoesNotSuppressAnotherSource() throws {
            let fixture = try makeFixture("case-consent")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let upper = fixture.container.appendingPathComponent("HistoryCase", isDirectory: true)
            let lower = fixture.container.appendingPathComponent("historycase", isDirectory: true)
            try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
            let caseSensitive = try XCTUnwrap(
                upper.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                    .volumeSupportsCaseSensitiveNames
            )
            guard caseSensitive else { throw XCTSkip("The fixture volume is case-insensitive") }
            try FileManager.default.createDirectory(at: lower, withIntermediateDirectories: true)
            let first = defaultFolder(path: upper, provider: .codex)
            let second = defaultFolder(path: lower, provider: .codex)
            let configuration = AgentActivityConfiguration(
                discoveryTombstones: [AgentDiscoveryTombstone(sourceID: first.id)]
            )
            let merged = AgentDefaultSourceDiscovery.merging(
                configuration: configuration,
                discovered: [first, second]
            )
            XCTAssertEqual(merged.watchedFolders.map(\.id), [second.id])
        }

        func testTombstonesAndConfigurationAreBoundedAndContainNoFreeFormPayload() throws {
            let fixture = try makeFixture("bounded-config")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let marker = "TRANSCRIPT_BODY_MUST_NOT_PERSIST"
            let folders = (0..<700).map { index in
                AgentWatchedFolder(
                    id: "folder-\(index)",
                    displayName: "Source \(index)",
                    path: fixture.container.appendingPathComponent("source-\(index)").path,
                    provider: .codex
                )
            }
            var tombstones = (0..<700).map { index in
                AgentDiscoveryTombstone(
                    sourceID: AgentDefaultSourceDiscovery.stableID(
                        provider: .codex,
                        path: fixture.container.appendingPathComponent("default-\(index)").path
                    ),
                    suppressedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }
            tombstones.append(AgentDiscoveryTombstone(sourceID: marker))
            let validated = AgentActivityConfiguration(
                watchedFolders: folders,
                discoveryTombstones: tombstones
            ).validated()
            XCTAssertEqual(validated.watchedFolders.count, AgentActivityConfiguration.maximumWatchedFolders)
            XCTAssertEqual(
                validated.discoveryTombstones.count,
                AgentActivityConfiguration.maximumDiscoveryTombstones
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(validated)
            XCTAssertLessThan(data.count, 256 * 1_024)
            XCTAssertNil(data.range(of: Data(marker.utf8)))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let persistedTombstones = try XCTUnwrap(object["discoveryTombstones"] as? [[String: Any]])
            XCTAssertTrue(persistedTombstones.allSatisfy { Set($0.keys) == ["sourceID", "suppressedAt"] })
        }

        func testRuntimeRejectsTamperedIndexReferenceOutsideActiveWatchedFolder() throws {
            let fixture = try makeFixture("direct-read-authority")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let watchedRoot = fixture.container.appendingPathComponent("Watched", isDirectory: true)
            try FileManager.default.createDirectory(at: watchedRoot, withIntermediateDirectories: true)
            let secret = fixture.container.appendingPathComponent("secret.jsonl", isDirectory: false)
            let secretBody = "TOP_SECRET_TRANSCRIPT_BODY"
            try Data(secretBody.utf8).write(to: secret)

            let folder = AgentWatchedFolder(
                id: "watched-codex",
                displayName: "Codex",
                path: watchedRoot.path,
                provider: .codex
            )
            let store = try AgentActivityStore(rootDirectory: fixture.metadata)
            _ = try store.saveConfiguration(AgentActivityConfiguration(watchedFolders: [folder]))
            let reference = AgentSourceReference(kind: .file, path: secret.path)
            let entry = AgentSourceIndexEntry(
                id: "ignored",
                stableConversationID: "forged-outside-source",
                watchedFolderID: folder.id,
                watchedFolderName: folder.displayName,
                provider: folder.provider,
                reference: reference,
                relativePath: secret.lastPathComponent,
                sourceCreatedAt: nil,
                sourceModifiedAt: nil,
                firstIndexedAt: Date(timeIntervalSince1970: 1),
                lastObservedAt: Date(timeIntervalSince1970: 1),
                byteCount: Int64(secretBody.utf8.count),
                sha256: String(repeating: "0", count: 64)
            )
            _ = try store.upsert(AgentCaptureRecord(index: entry, isAnalyzed: false), maximumEntries: 100)

            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [] },
                onCaptured: { _ in }
            )
            XCTAssertThrowsError(try runtime.directRead(entryID: entry.id)) { error in
                XCTAssertTrue(error is AgentActivityRuntimeAccessError)
            }
            runtime.stop()

            let metadataBytes = try Data(contentsOf: store.indexFile)
            XCTAssertNil(metadataBytes.range(of: Data(secretBody.utf8)))
        }

        func testRuntimeRejectsContainedReferenceWhenFolderIsDisabledOrTombstoned() throws {
            for state in ["disabled", "tombstoned"] {
                let fixture = try makeFixture("direct-read-\(state)")
                defer { try? FileManager.default.removeItem(at: fixture.container) }
                let watchedRoot = fixture.container.appendingPathComponent("Watched", isDirectory: true)
                try FileManager.default.createDirectory(at: watchedRoot, withIntermediateDirectories: true)
                let source = watchedRoot.appendingPathComponent("session.jsonl", isDirectory: false)
                let transcript = "\(state.uppercased())_TRANSCRIPT_MUST_NOT_BE_RETURNED"
                try Data(transcript.utf8).write(to: source)
                var folder = defaultFolder(path: watchedRoot, provider: .codex)
                folder.isEnabled = state != "disabled"
                let tombstones =
                    state == "tombstoned"
                    ? [AgentDiscoveryTombstone(sourceID: folder.id)]
                    : []
                let store = try AgentActivityStore(rootDirectory: fixture.metadata)
                _ = try store.saveConfiguration(
                    AgentActivityConfiguration(
                        watchedFolders: [folder],
                        discoveryTombstones: tombstones
                    )
                )
                let entry = makeEntry(
                    reference: AgentSourceReference(kind: .file, path: source.path),
                    folder: folder
                )
                _ = try store.upsert(AgentCaptureRecord(index: entry, isAnalyzed: false), maximumEntries: 100)

                let runtime = try AgentActivityRuntime(
                    rootDirectory: fixture.metadata,
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    sourceDiscovery: { [] },
                    onCaptured: { _ in }
                )
                XCTAssertThrowsError(try runtime.directRead(entryID: entry.id), state)
                runtime.stop()
                XCTAssertNil(try Data(contentsOf: store.indexFile).range(of: Data(transcript.utf8)))
            }
        }

        func testPollingUsesThirtySecondFloorWithoutChangingConfiguredValue() {
            XCTAssertEqual(AgentActivityRuntime.effectivePollingInterval(configuredInterval: 8), 30)
            XCTAssertEqual(AgentActivityRuntime.effectivePollingInterval(configuredInterval: 20), 30)
            XCTAssertEqual(AgentActivityRuntime.effectivePollingInterval(configuredInterval: 45), 45)
            XCTAssertEqual(AgentActivityConfiguration.default.scanIntervalSeconds, 30)
        }

        func testHiddenWarmScanSkipsDerivedOverviewAndIndexValidation() throws {
            let fixture = try makeFixture("hidden-warm-scan")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [] },
                onCaptured: { _ in }
            )
            defer { runtime.stop() }

            runtime.scanNow()
            runtime.waitForPendingScansForTesting()
            XCTAssertEqual(runtime.derivedStateRefreshCountForTesting, 0)

            runtime.dashboardDidBecomeVisible()
            runtime.scanNow()
            runtime.waitForPendingScansForTesting()
            XCTAssertEqual(runtime.derivedStateRefreshCountForTesting, 1)

            runtime.dashboardDidBecomeHidden()
            runtime.scanNow()
            runtime.waitForPendingScansForTesting()
            XCTAssertEqual(runtime.derivedStateRefreshCountForTesting, 1)
        }

        func testExplicitSelectedDayAnalysisAutomaticallyCompletesEveryBoundedBatch() throws {
            let fixture = try makeFixture("analysis-catch-up")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let sourceRoot = fixture.container.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let sourceCount = 300
            let transcriptMarker = "RUNTIME_CATCH_UP_TRANSCRIPT_MUST_STAY_AT_SOURCE"
            for index in 0..<sourceCount {
                let body =
                    "{\"role\":\"user\",\"content\":\"\(transcriptMarker)-\(index)\"}\n"
                try Data(body.utf8).write(
                    to: sourceRoot.appendingPathComponent(String(format: "session-%04d.jsonl", index))
                )
            }
            let watchedFolder = AgentWatchedFolder(
                id: "runtime-analysis-source",
                displayName: "Runtime analysis fixture",
                path: sourceRoot.path,
                provider: .custom,
                captureMode: .everyFile
            )
            let configuration = AgentActivityConfiguration(
                watchedFolders: [watchedFolder],
                maximumIndexEntries: sourceCount
            )
            let seedStore = try AgentActivityStore(rootDirectory: fixture.metadata)
            _ = try seedStore.saveConfiguration(configuration)

            let capturedLock = NSLock()
            var capturedEntryIDs: Set<String> = []
            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [] },
                onCaptured: { records in
                    capturedLock.lock()
                    capturedEntryIDs.formUnion(records.map(\.index.id))
                    capturedLock.unlock()
                }
            )
            defer { runtime.stop() }

            runtime.scanNow(forceFullDiscovery: true, analyzeSelectedDay: true)
            runtime.waitForPendingScansForTesting()

            capturedLock.lock()
            let capturedCount = capturedEntryIDs.count
            capturedLock.unlock()
            XCTAssertEqual(capturedCount, sourceCount)
            let persistedStore = try AgentActivityStore(rootDirectory: fixture.metadata)
            XCTAssertEqual(persistedStore.indexEntryCount(), sourceCount)
            XCTAssertEqual(Set(persistedStore.entries().map(\.id)).count, sourceCount)
            XCTAssertNil(
                try Data(contentsOf: persistedStore.indexFile)
                    .range(of: Data(transcriptMarker.utf8))
            )
        }

        func testSelectedDayPublishesOnlyCompleteTitledConversationSnapshots() throws {
            let fixture = try makeFixture("atomic-titled-overview")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let sourceRoot = fixture.container.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let selectedDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
            let sourceCount = 70
            for index in 0..<sourceCount {
                let source = sourceRoot.appendingPathComponent(String(format: "conversation-%03d.jsonl", index))
                try Data("{\"role\":\"user\",\"content\":\"Prompt \(index)\"}\n".utf8).write(to: source)
                try FileManager.default.setAttributes(
                    [.modificationDate: selectedDay.addingTimeInterval(3_600 + Double(index))],
                    ofItemAtPath: source.path
                )
            }
            let folder = AgentWatchedFolder(
                id: "atomic-titled-overview-source",
                displayName: "Atomic title fixture",
                path: sourceRoot.path,
                provider: .custom,
                captureMode: .everyFile
            )
            let store = try AgentActivityStore(rootDirectory: fixture.metadata)
            _ = try store.saveConfiguration(
                AgentActivityConfiguration(watchedFolders: [folder], maximumIndexEntries: sourceCount)
            )
            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [] },
                onCaptured: { _ in }
            )
            defer { runtime.stop() }

            var published: [AgentActivityOverview] = []
            let subscription = runtime.$overview.dropFirst().sink { overview in
                guard overview.day == selectedDay, !overview.captures.isEmpty else { return }
                published.append(overview)
            }
            runtime.selectDay(selectedDay)
            runtime.waitForPendingScansForTesting()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            subscription.cancel()

            XCTAssertFalse(published.isEmpty)
            XCTAssertTrue(
                published.allSatisfy { overview in
                    overview.captures.count == sourceCount
                        && overview.captures.allSatisfy {
                            $0.summary.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        }
                }
            )
        }

        func testSignalWatcherTriggersImmediateCoalescedScanWithoutWaitingForPollInterval() throws {
            let fixture = try makeFixture("signal-watcher")
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let runtime = try AgentActivityRuntime(
                rootDirectory: fixture.metadata,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [] },
                onCaptured: { _ in }
            )
            let initialScan = expectation(description: "initial scan")
            let signalScan = expectation(description: "signal scan")
            signalScan.assertForOverFulfill = false
            var publicationCount = 0
            let subscription = runtime.$lastScanResult.dropFirst().sink { _ in
                publicationCount += 1
                if publicationCount == 1 {
                    initialScan.fulfill()
                } else {
                    signalScan.fulfill()
                }
            }

            runtime.start()
            wait(for: [initialScan], timeout: 2)
            _ = try AgentHookSignalWriter.write(
                rootDirectory: fixture.metadata,
                provider: .codex,
                eventName: "FileChanged",
                discardedPayloadBytes: 0,
                processIdentifier: 1
            )
            wait(for: [signalScan], timeout: 2)
            subscription.cancel()
            runtime.stop()
        }

        private func makeFixture(_ name: String) throws -> (container: URL, metadata: URL) {
            let container = FileManager.default.temporaryDirectory.appendingPathComponent(
                "AgentActivityDiscoveryConsentTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            return (container, container.appendingPathComponent("agent-activity-v2", isDirectory: true))
        }

        private func defaultFolder(path: URL, provider: AgentProvider) -> AgentWatchedFolder {
            AgentWatchedFolder(
                id: AgentDefaultSourceDiscovery.stableID(provider: provider, path: path.path),
                displayName: provider.displayName,
                path: path.path,
                provider: provider
            )
        }

        private func makeEntry(
            reference: AgentSourceReference,
            folder: AgentWatchedFolder
        ) -> AgentSourceIndexEntry {
            AgentSourceIndexEntry(
                id: "ignored",
                stableConversationID: "fixture-\(UUID().uuidString)",
                watchedFolderID: folder.id,
                watchedFolderName: folder.displayName,
                provider: folder.provider,
                reference: reference,
                relativePath: URL(fileURLWithPath: reference.path).lastPathComponent,
                sourceCreatedAt: nil,
                sourceModifiedAt: nil,
                firstIndexedAt: Date(timeIntervalSince1970: 1),
                lastObservedAt: Date(timeIntervalSince1970: 1),
                byteCount: 1,
                sha256: String(repeating: "0", count: 64)
            )
        }
    }
#endif
