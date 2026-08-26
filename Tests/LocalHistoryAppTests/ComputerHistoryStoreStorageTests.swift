#if os(macOS)
    import Dispatch
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class ComputerHistoryStoreStorageTests: XCTestCase {
        func testProductionRecentLoadBudgetsAccommodateMeasuredLegacyDay() {
            let limits = ComputerHistoryStore.RecentLoadLimits.production
            XCTAssertEqual(limits.maximumSingleFileBytes, 32 * 1_024 * 1_024)
            XCTAssertGreaterThan(limits.maximumSingleFileBytes, 28_568_752)
            XCTAssertEqual(limits.defaultCumulativeBytes, 64 * 1_024 * 1_024)
            XCTAssertEqual(limits.absoluteCumulativeBytes, 96 * 1_024 * 1_024)
            XCTAssertEqual(limits.maximumDirectoryEntries, 20_000)
            XCTAssertEqual(limits.maximumDirectoryEnumerationSeconds, 2)
        }

        func testLegacyTripleMarkdownIsCompactedWithoutLosingReadableMemory() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let repeatedEvidence = String(
                repeating: "Observed activity remains fully represented by structured evidence. ",
                count: 400
            )
            let memory = replacingMarkdown(
                makeMemory(day: day, title: "Storage fixture", summary: repeatedEvidence),
                with: "# Legacy unbounded projection\n\n" + repeatedEvidence
            )
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )

            let memoryDirectory = fixtureRoot.appendingPathComponent("computer-history", isDirectory: true)
            try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
            let JSONURL = memoryDirectory.appendingPathComponent("2026-08-20.computer-history.json")
            let localMarkdownURL = memoryDirectory.appendingPathComponent("2026-08-20.computer-history.md")
            let codexMarkdownURL = codexRoot.appendingPathComponent(
                "2026-08-20-goalong-computer-history.md"
            )

            let legacyEncoder = JSONEncoder()
            legacyEncoder.dateEncodingStrategy = .iso8601
            legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let legacyJSON = try legacyEncoder.encode(memory)
            let markdown = Data(memory.markdown.utf8)
            try legacyJSON.write(to: JSONURL, options: [.atomic])
            try markdown.write(to: localMarkdownURL, options: [.atomic])
            try markdown.write(to: codexMarkdownURL, options: [.atomic])
            let bytesBefore = legacyJSON.count + (2 * markdown.count)

            let legacyDecoder = JSONDecoder()
            legacyDecoder.dateDecodingStrategy = .iso8601
            let legacyRoundTrip = try legacyDecoder.decode(
                ComputerHistoryDayMemory.self,
                from: legacyJSON
            )

            let loaded = try XCTUnwrap(store.loadStored(for: day))
            XCTAssertEqual(loaded.markdown, ComputerHistoryMarkdownRenderer.render(legacyRoundTrip))
            XCTAssertNotEqual(loaded.markdown, legacyRoundTrip.markdown)
            XCTAssertFalse(FileManager.default.fileExists(atPath: localMarkdownURL.path))

            let compactJSON = try Data(contentsOf: JSONURL)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: compactJSON) as? [String: Any]
            )
            XCTAssertNil(object["markdown"])
            XCTAssertEqual(object["storageFormatVersion"] as? Int, 3)
            let compactMarkdown = Data(loaded.markdown.utf8)
            XCTAssertEqual(try Data(contentsOf: codexMarkdownURL), compactMarkdown)

            let bytesAfter = compactJSON.count + compactMarkdown.count
            XCTAssertLessThan(bytesAfter, (bytesBefore * 65) / 100)
            print(
                "ComputerHistoryStore fixture bytes before=\(bytesBefore) "
                    + "after=\(bytesAfter) saved=\(bytesBefore - bytesAfter)"
            )

            let fixedModificationDate = Date(timeIntervalSince1970: 1_600_000_000)
            for URL in [JSONURL, codexMarkdownURL] {
                try FileManager.default.setAttributes(
                    [.modificationDate: fixedModificationDate],
                    ofItemAtPath: URL.path
                )
            }

            let regenerated = replacingGeneratedAt(
                loaded,
                with: loaded.generatedAt.addingTimeInterval(60)
            )
            let rewritten = try store.write(regenerated, for: day)
            XCTAssertEqual(rewritten, loaded)
            for URL in [JSONURL, codexMarkdownURL] {
                let attributes = try FileManager.default.attributesOfItem(atPath: URL.path)
                let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
                XCTAssertEqual(
                    modificationDate.timeIntervalSince1970,
                    fixedModificationDate.timeIntervalSince1970,
                    accuracy: 0.001
                )
            }
        }

        func testVersionTwoCompactJSONUpgradesTheExistingUnboundedCodexMirror() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 21)
            let memory = makeMemory(
                day: day,
                title: "Version two fixture",
                summary: "Structured evidence remains authoritative."
            )
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(memory)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object.removeValue(forKey: "markdown")
            object["storageFormatVersion"] = 2
            let versionTwoJSON = try JSONSerialization.data(withJSONObject: object)
            let JSONURL = memoryDirectory.appendingPathComponent(
                "2026-08-21.computer-history.json"
            )
            try versionTwoJSON.write(to: JSONURL, options: [.atomic])

            let oldMirror = Data(
                String(repeating: "Old unbounded Codex evidence projection.\n", count: 20_000).utf8
            )
            let codexURL = codexRoot.appendingPathComponent(
                "2026-08-21-goalong-computer-history.md"
            )
            try oldMirror.write(to: codexURL, options: [.atomic])

            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )
            let loaded = try XCTUnwrap(store.loadStored(for: day))
            let compactMirror = try Data(contentsOf: codexURL)

            XCTAssertEqual(compactMirror, Data(loaded.markdown.utf8))
            XCTAssertLessThan(compactMirror.count, oldMirror.count / 20)
            let upgraded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: JSONURL))
                    as? [String: Any]
            )
            XCTAssertEqual(upgraded["storageFormatVersion"] as? Int, 3)
            XCTAssertNil(upgraded["markdown"])
        }

        func testLoadRecentCompactsLegacyUnboundedAnalysisAfterValidatedRead() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let legacy = makeUnboundedLegacyMemory(day: day, episodeCount: 700)
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let jsonURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            let localMarkdownURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.md"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let legacyBytes = try encoder.encode(legacy)
            try legacyBytes.write(to: jsonURL, options: [.atomic])
            try Data(legacy.markdown.utf8).write(to: localMarkdownURL, options: [.atomic])

            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )
            let recent = store.loadRecent(maximumDays: 1)

            XCTAssertTrue(recent.isComplete)
            let loaded = try XCTUnwrap(recent.memories.first)
            XCTAssertEqual(loaded.coverage.episodeCount, 700)
            XCTAssertEqual(loaded.coverage.linkedInteractionCount, 700)
            XCTAssertEqual(loaded.coverage.retainedEpisodeCount, loaded.episodes.count)
            XCTAssertEqual(
                loaded.coverage.retainedInteractionCount,
                loaded.episodes.reduce(0) { $0 + $1.interactions.count }
            )
            XCTAssertLessThanOrEqual(loaded.episodes.count, 256)
            XCTAssertFalse(FileManager.default.fileExists(atPath: localMarkdownURL.path))

            let compactBytes = try Data(contentsOf: jsonURL)
            let persisted = try XCTUnwrap(
                JSONSerialization.jsonObject(with: compactBytes) as? [String: Any]
            )
            XCTAssertEqual(persisted["storageFormatVersion"] as? Int, 3)
            XCTAssertLessThan(compactBytes.count, legacyBytes.count / 2)
            print(
                "ComputerHistoryStore legacy-analysis bytes before=\(legacyBytes.count) "
                    + "after=\(compactBytes.count) saved=\(legacyBytes.count - compactBytes.count)"
            )
        }

        func testLegacyReadMigrationIsSuppressedWhileDerivedHistoryClearIsSuspended() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let memory = makeMemory(
                day: day,
                title: "Barrier fixture",
                summary: "Readable legacy memory must not migrate during clear."
            )
            let barrier = DerivedHistoryWriteBarrier(
                label: "goalong-computer-history-migration-barrier-\(UUID().uuidString)"
            )
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in },
                derivedWriteBarrier: barrier
            )
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let JSONURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            let localMarkdownURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.md"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let legacyJSON = try encoder.encode(memory)
            try legacyJSON.write(to: JSONURL, options: [.atomic])
            try Data(memory.markdown.utf8).write(to: localMarkdownURL, options: [.atomic])

            let suspension = barrier.suspend()
            XCTAssertNotNil(store.loadStored(for: day))
            XCTAssertEqual(try Data(contentsOf: JSONURL), legacyJSON)
            XCTAssertTrue(FileManager.default.fileExists(atPath: localMarkdownURL.path))

            barrier.resume(suspension)
            XCTAssertNotNil(store.loadStored(for: day))
            XCTAssertFalse(FileManager.default.fileExists(atPath: localMarkdownURL.path))
            let upgraded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: JSONURL)) as? [String: Any]
            )
            XCTAssertEqual(upgraded["storageFormatVersion"] as? Int, 3)
        }

        func testLegacyMigrationRejectsSymlinkedMarkdownBeforeRewritingJSON() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fixtureRoot = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let codexRoot = container.appendingPathComponent("codex", isDirectory: true)
            let externalURL = container.appendingPathComponent("external.md")
            defer { try? FileManager.default.removeItem(at: container) }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let legacy = try legacyMemoryFixture(
                day: day,
                title: "Legacy with unsafe projection",
                summary: "The JSON must remain untouched when the legacy Markdown is a symlink."
            )
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let jsonURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            let localMarkdownURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.md"
            )
            try legacy.data.write(to: jsonURL, options: [.atomic])
            let externalBytes = Data("external projection must remain private".utf8)
            try externalBytes.write(to: externalURL)
            try FileManager.default.createSymbolicLink(
                at: localMarkdownURL,
                withDestinationURL: externalURL
            )
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )

            XCTAssertEqual(store.loadStored(for: day)?.title, legacy.memory.title)
            XCTAssertEqual(try Data(contentsOf: jsonURL), legacy.data)
            XCTAssertEqual(try Data(contentsOf: externalURL), externalBytes)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: localMarkdownURL.path),
                externalURL.path
            )
        }

        func testLegacyReadMigrationCannotOverwriteNewerConcurrentWrite() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let legacy = makeMemory(
                day: day,
                title: "Legacy A",
                summary: "The migration captured this older representation."
            )
            let newer = makeMemory(
                day: day,
                title: "Concurrent B",
                summary: "This newer write must remain authoritative."
            )
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let JSONURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            let legacyEncoder = JSONEncoder()
            legacyEncoder.dateEncodingStrategy = .iso8601
            legacyEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try legacyEncoder.encode(legacy).write(to: JSONURL, options: [.atomic])

            let staleReadCaptured = DispatchSemaphore(value: 0)
            let releaseStaleRead = DispatchSemaphore(value: 0)
            let migrationFinished = DispatchSemaphore(value: 0)
            let migrationResult = LockedValue<ComputerHistoryDayMemory?>(nil)
            let migratingStore = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in },
                persistedDataReadObserver: { url, _ in
                    if url.standardizedFileURL == JSONURL.standardizedFileURL {
                        staleReadCaptured.signal()
                        _ = releaseStaleRead.wait(timeout: .now() + 5)
                    }
                }
            )
            let writingStore = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )

            DispatchQueue.global(qos: .userInitiated).async {
                migrationResult.set(migratingStore.loadStored(for: day))
                migrationFinished.signal()
            }
            XCTAssertEqual(staleReadCaptured.wait(timeout: .now() + 5), .success)

            XCTAssertEqual(try writingStore.write(newer, for: day), newer)
            let newerBytes = try Data(contentsOf: JSONURL)
            releaseStaleRead.signal()
            XCTAssertEqual(migrationFinished.wait(timeout: .now() + 5), .success)

            XCTAssertNil(migrationResult.get())
            XCTAssertEqual(try Data(contentsOf: JSONURL), newerBytes)
            XCTAssertEqual(writingStore.loadStored(for: day), newer)
        }

        func testLegacyMigrationRevalidatesExpectedBytesImmediatelyBeforeRename() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let legacy = try legacyMemoryFixture(
                day: day,
                title: "Legacy A",
                summary: "The migration decoded this representation."
            )
            let replacement = try legacyMemoryFixture(
                day: day,
                title: "Replacement B",
                summary: "This replacement arrives after the migration temporary file is durable."
            )
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let jsonURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            let legacyMarkdownURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.md"
            )
            try legacy.data.write(to: jsonURL, options: [.atomic])
            try Data(legacy.memory.markdown.utf8).write(
                to: legacyMarkdownURL,
                options: [.atomic]
            )

            var replacedImmediatelyBeforeRename = false
            var replacementError: Error?
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in },
                beforeAtomicRename: { destination in
                    guard destination.standardizedFileURL == jsonURL.standardizedFileURL,
                        !replacedImmediatelyBeforeRename
                    else { return }
                    replacedImmediatelyBeforeRename = true
                    do {
                        try replacement.data.write(to: destination, options: [.atomic])
                    } catch {
                        replacementError = error
                    }
                }
            )

            XCTAssertEqual(store.loadStored(for: day)?.title, legacy.memory.title)
            XCTAssertTrue(replacedImmediatelyBeforeRename)
            XCTAssertNil(replacementError)
            XCTAssertEqual(try Data(contentsOf: jsonURL), replacement.data)
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarkdownURL.path))
        }

        func testLegacyMigrationRejectsReplacedTemporaryEntryBeforeRename() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let legacy = try legacyMemoryFixture(
                day: day,
                title: "Legacy destination",
                summary: "The migration must preserve these bytes when its temp is replaced."
            )
            let replacement = try legacyMemoryFixture(
                day: day,
                title: "Swapped temporary",
                summary: "These bytes must never be renamed over the legacy destination."
            )
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let JSONURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            let legacyMarkdownURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.md"
            )
            try legacy.data.write(to: JSONURL, options: [.atomic])
            try Data(legacy.memory.markdown.utf8).write(
                to: legacyMarkdownURL,
                options: [.atomic]
            )

            var temporaryWasReplaced = false
            var replacementError: Error?
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in },
                beforeAtomicRename: { destination in
                    guard destination.standardizedFileURL == JSONURL.standardizedFileURL,
                        !temporaryWasReplaced
                    else { return }
                    do {
                        let temporaryName = try XCTUnwrap(
                            FileManager.default.contentsOfDirectory(atPath: memoryDirectory.path)
                                .first { $0.hasPrefix(".") && $0.hasSuffix(".tmp") }
                        )
                        let temporaryURL = memoryDirectory.appendingPathComponent(temporaryName)
                        try FileManager.default.removeItem(at: temporaryURL)
                        try replacement.data.write(to: temporaryURL)
                        temporaryWasReplaced = true
                    } catch {
                        replacementError = error
                    }
                }
            )

            XCTAssertEqual(store.loadStored(for: day)?.title, legacy.memory.title)
            XCTAssertTrue(temporaryWasReplaced)
            XCTAssertNil(replacementError)
            XCTAssertEqual(try Data(contentsOf: JSONURL), legacy.data)
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarkdownURL.path))
        }

        func testLoadRecentSkipsCorruptNewestAndBackfillsValidOlderMemory() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )
            let firstDay = makeDay(year: 2026, month: 8, day: 18)
            let secondDay = makeDay(year: 2026, month: 8, day: 19)
            let firstMemory = makeMemory(
                day: firstDay,
                title: "First",
                summary: "First fixture day."
            )
            _ = try store.write(firstMemory, for: firstDay)
            XCTAssertEqual(store.loadStored(for: firstDay), firstMemory)
            _ = try store.write(
                makeMemory(day: secondDay, title: "Second", summary: "Second fixture day."),
                for: secondDay
            )

            // A corrupt newest file must not consume one of the two requested result slots.
            let corruptNewest = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("2026-08-20.computer-history.json")
            try Data("not-json".utf8).write(to: corruptNewest, options: [.atomic])

            let recent = store.loadRecent(maximumDays: 2)
            XCTAssertEqual(recent.memories.map(\.title), ["First", "Second"])
            XCTAssertFalse(recent.isComplete)
        }

        func testLoadRecentMarksOwnedSymlinkIncompleteAndReturnsSafeSubset() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let older = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 19),
                title: "Safe older memory",
                summary: "This regular owned file remains readable."
            )
            let externalNewer = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 20),
                title: "External newer memory",
                summary: "The owned symlink must never expose these bytes."
            )
            try writeMemoryFixture(older.data, dayKey: "2026-08-19", root: fixtureRoot)
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            let externalURL = fixtureRoot.appendingPathComponent("external-newer.json")
            try externalNewer.data.write(to: externalURL, options: [.atomic])
            let externalBytes = try Data(contentsOf: externalURL)
            let ownedSymlink = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            try FileManager.default.createSymbolicLink(
                at: ownedSymlink,
                withDestinationURL: externalURL
            )

            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )
            let recent = store.loadRecent(maximumDays: 1)

            XCTAssertEqual(recent.memories.map(\.title), [older.memory.title])
            XCTAssertFalse(recent.isComplete)
            XCTAssertTrue(recent.issues.contains { $0.contains("not a regular file") })
            XCTAssertEqual(try Data(contentsOf: externalURL), externalBytes)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: ownedSymlink.path),
                externalURL.path
            )
        }

        func testLoadStoredRefusesOwnedSymlinkWithoutMutatingExternalTarget() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let external = try legacyMemoryFixture(
                day: day,
                title: "External target",
                summary: "This file must remain outside Computer History reads and migration."
            )
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let externalURL = fixtureRoot.appendingPathComponent("external-memory.json")
            try external.data.write(to: externalURL, options: [.atomic])
            let externalBytes = try Data(contentsOf: externalURL)
            let ownedSymlink = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            try FileManager.default.createSymbolicLink(
                at: ownedSymlink,
                withDestinationURL: externalURL
            )
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )

            XCTAssertNil(store.loadStored(for: day))
            XCTAssertEqual(try Data(contentsOf: externalURL), externalBytes)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: ownedSymlink.path),
                externalURL.path
            )
        }

        func testLoadsRejectSymlinkedStorageAncestorWithoutReadingExternalMemory() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let externalRoot = container.appendingPathComponent("external", isDirectory: true)
            let linkedRoot = container.appendingPathComponent("linked-root", isDirectory: true)
            let codexRoot = container.appendingPathComponent("codex", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let external = try legacyMemoryFixture(
                day: day,
                title: "External ancestor target",
                summary: "A symlinked storage ancestor must not expose this memory."
            )
            let externalMemoryDirectory = externalRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: externalMemoryDirectory,
                withIntermediateDirectories: true
            )
            let externalMemoryURL = externalMemoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            try external.data.write(to: externalMemoryURL)
            let externalBytes = try Data(contentsOf: externalMemoryURL)
            try FileManager.default.createSymbolicLink(
                at: linkedRoot,
                withDestinationURL: externalRoot
            )
            var observedReadCount = 0
            let store = ComputerHistoryStore(
                rootDirectory: linkedRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in },
                persistedDataReadObserver: { _, _ in observedReadCount += 1 }
            )

            XCTAssertNil(store.loadStored(for: day))
            let recent = store.loadRecent(maximumDays: 1)
            XCTAssertTrue(recent.memories.isEmpty)
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(observedReadCount, 0)
            XCTAssertEqual(try Data(contentsOf: externalMemoryURL), externalBytes)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: linkedRoot.path),
                externalRoot.path
            )
        }

        func testLoadRecentEnforcesCumulativeBudgetAndBackfillsSmallerOlderMemory() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let oldest = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 18),
                title: "Oldest",
                summary: "small older memory"
            )
            let middle = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 19),
                title: "Middle",
                summary: String(repeating: "middle evidence ", count: 200)
            )
            let newest = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 20),
                title: "Newest",
                summary: "small newest memory"
            )
            try writeMemoryFixture(oldest.data, dayKey: "2026-08-18", root: fixtureRoot)
            try writeMemoryFixture(middle.data, dayKey: "2026-08-19", root: fixtureRoot)
            try writeMemoryFixture(newest.data, dayKey: "2026-08-20", root: fixtureRoot)

            let budget = newest.data.count + oldest.data.count
            XCTAssertGreaterThan(middle.data.count, oldest.data.count)
            var loadedNames: [String] = []
            var diagnostics: [String] = []
            let expectedByteCounts = [
                "2026-08-20.computer-history.json": newest.data.count,
                "2026-08-18.computer-history.json": oldest.data.count,
            ]
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: middle.data.count + 1,
                    defaultCumulativeBytes: budget,
                    absoluteCumulativeBytes: budget,
                    maximumDiagnosticMessages: 4
                ),
                diagnosticSink: { diagnostics.append($0) },
                persistedDataReadObserver: { url, data in
                    loadedNames.append(url.lastPathComponent)
                    XCTAssertEqual(
                        data.count,
                        expectedByteCounts[url.lastPathComponent] ?? -1
                    )
                }
            )

            let recent = store.loadRecent(maximumDays: 3)
            XCTAssertEqual(recent.memories.map(\.title), ["Oldest", "Newest"])
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(
                loadedNames,
                [
                    "2026-08-20.computer-history.json",
                    "2026-08-18.computer-history.json",
                ]
            )
            XCTAssertEqual(
                loadedNames.compactMap {
                    [
                        "2026-08-20.computer-history.json": newest.data.count,
                        "2026-08-18.computer-history.json": oldest.data.count,
                    ][$0]
                }.reduce(0, +),
                budget
            )
            XCTAssertTrue(diagnostics.contains { $0.contains("cumulative encoded-memory budget") })
        }

        func testLoadRecentSkipsOversizedDayAndBackfillsOlderMemoryWithoutReadingIt() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let older = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 19),
                title: "Older valid",
                summary: "small"
            )
            let oversized = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 20),
                title: "Oversized",
                summary: String(repeating: "large evidence ", count: 300)
            )
            try writeMemoryFixture(older.data, dayKey: "2026-08-19", root: fixtureRoot)
            try writeMemoryFixture(oversized.data, dayKey: "2026-08-20", root: fixtureRoot)

            let perFileLimit = older.data.count + 32
            XCTAssertGreaterThan(oversized.data.count, perFileLimit)
            var loadedNames: [String] = []
            var diagnostics: [String] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: perFileLimit,
                    defaultCumulativeBytes: oversized.data.count + older.data.count,
                    absoluteCumulativeBytes: oversized.data.count + older.data.count,
                    maximumDiagnosticMessages: 4
                ),
                diagnosticSink: { diagnostics.append($0) },
                persistedDataReadObserver: { url, _ in
                    loadedNames.append(url.lastPathComponent)
                }
            )

            let recent = store.loadRecent(maximumDays: 1)
            XCTAssertEqual(recent.memories.map(\.title), ["Older valid"])
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(loadedNames, ["2026-08-19.computer-history.json"])
            XCTAssertTrue(diagnostics.contains { $0.contains("daily limit") })
        }

        func testLoadRecentBoundsCorruptDiagnosticsAndStillBackfillsOlderMemory() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let older = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 17),
                title: "Backfilled",
                summary: "valid older memory"
            )
            try writeMemoryFixture(older.data, dayKey: "2026-08-17", root: fixtureRoot)
            for key in [
                "2026-08-18", "2026-08-19", "2026-08-20",
                "2026-08-21", "2026-08-22", "2026-08-23",
            ] {
                try writeMemoryFixture(Data("not-json".utf8), dayKey: key, root: fixtureRoot)
            }

            var diagnostics: [String] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: older.data.count + 1,
                    defaultCumulativeBytes: older.data.count + 100,
                    absoluteCumulativeBytes: older.data.count + 100,
                    maximumDiagnosticMessages: 2
                ),
                diagnosticSink: { diagnostics.append($0) }
            )

            let recent = store.loadRecent(maximumDays: 1)
            XCTAssertEqual(recent.memories.map(\.title), ["Backfilled"])
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(diagnostics.count, 2)
            XCTAssertTrue(diagnostics[0].contains("corrupt"))
            XCTAssertTrue(diagnostics[1].contains("suppressed 5 additional"))
        }

        func testLoadRecentFindsExactNewestDaysAcrossThousandsOfDirectoryEntries() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            for index in 0..<2_500 {
                XCTAssertTrue(
                    FileManager.default.createFile(
                        atPath: memoryDirectory
                            .appendingPathComponent("unrelated-\(index).txt")
                            .path,
                        contents: Data()
                    )
                )
            }

            let firstDay = makeDay(year: 2026, month: 7, day: 1)
            var expectedNewestTitles: [String] = []
            for offset in 0..<60 {
                let day = try XCTUnwrap(
                    Calendar.current.date(byAdding: .day, value: offset, to: firstDay)
                )
                let title = "Candidate \(offset)"
                let fixture = try legacyMemoryFixture(
                    day: day,
                    title: title,
                    summary: "Bounded top-K fixture."
                )
                try writeMemoryFixture(
                    fixture.data,
                    dayKey: dayKey(day),
                    root: fixtureRoot
                )
                if offset >= 30 { expectedNewestTitles.append(title) }
            }

            var loadedNames: [String] = []
            var diagnostics: [String] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: 1_024 * 1_024,
                    defaultCumulativeBytes: 4 * 1_024 * 1_024,
                    absoluteCumulativeBytes: 4 * 1_024 * 1_024,
                    maximumDiagnosticMessages: 4,
                    maximumDirectoryEntries: 3_000,
                    maximumDirectoryEnumerationSeconds: 10
                ),
                diagnosticSink: { diagnostics.append($0) },
                persistedDataReadObserver: { url, _ in
                    loadedNames.append(url.lastPathComponent)
                }
            )

            let recent = store.loadRecent(maximumDays: 30)
            XCTAssertEqual(recent.memories.map(\.title), expectedNewestTitles)
            XCTAssertTrue(recent.isComplete)
            XCTAssertEqual(loadedNames.count, 30)
            XCTAssertTrue(diagnostics.isEmpty)
        }

        func testLoadRecentRejectsConcurrentDirectoryMutationBeforeCompleting() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let olderDay = makeDay(year: 2026, month: 8, day: 20)
            let newerDay = makeDay(year: 2026, month: 8, day: 21)
            let older = try legacyMemoryFixture(
                day: olderDay,
                title: "Older snapshot",
                summary: "The listing must not complete across a concurrent write."
            )
            try writeMemoryFixture(older.data, dayKey: "2026-08-20", root: fixtureRoot)

            let readCaptured = DispatchSemaphore(value: 0)
            let releaseRead = DispatchSemaphore(value: 0)
            let loadFinished = DispatchSemaphore(value: 0)
            let loaded = LockedValue<ComputerHistoryRecentLoadResult?>(nil)
            var diagnostics: [String] = []
            let readingStore = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { diagnostics.append($0) },
                persistedDataReadObserver: { url, _ in
                    if url.lastPathComponent == "2026-08-20.computer-history.json" {
                        readCaptured.signal()
                        _ = releaseRead.wait(timeout: .now() + 5)
                    }
                }
            )
            let writingStore = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )

            DispatchQueue.global(qos: .userInitiated).async {
                loaded.set(readingStore.loadRecent(maximumDays: 1))
                loadFinished.signal()
            }
            XCTAssertEqual(readCaptured.wait(timeout: .now() + 5), .success)
            let newer = makeMemory(
                day: newerDay,
                title: "Concurrent newer snapshot",
                summary: "This write changes the exact newest-day set."
            )
            XCTAssertEqual(try writingStore.write(newer, for: newerDay), newer)
            releaseRead.signal()
            XCTAssertEqual(loadFinished.wait(timeout: .now() + 5), .success)

            let recent = try XCTUnwrap(loaded.get())
            XCTAssertTrue(recent.memories.isEmpty)
            XCTAssertFalse(recent.isComplete)
            XCTAssertTrue(diagnostics.contains { $0.contains("directory changed while memories were loaded") })
            XCTAssertEqual(writingStore.loadStored(for: newerDay), newer)
        }

        func testLoadRecentRejectsDetachedAndReplacedMemoryDirectory() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let original = try legacyMemoryFixture(
                day: day,
                title: "Pinned A",
                summary: "The reader may observe only this pinned payload."
            )
            let replacement = try legacyMemoryFixture(
                day: day,
                title: "Replacement B",
                summary: "The replacement directory must remain untouched."
            )
            try writeMemoryFixture(original.data, dayKey: "2026-08-20", root: fixtureRoot)
            let memoryDirectory = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            let detachedDirectory = fixtureRoot.appendingPathComponent(
                "computer-history-detached",
                isDirectory: true
            )
            let readCaptured = DispatchSemaphore(value: 0)
            let releaseRead = DispatchSemaphore(value: 0)
            let loadFinished = DispatchSemaphore(value: 0)
            let loaded = LockedValue<ComputerHistoryRecentLoadResult?>(nil)
            let observedPayloads = LockedValue<[Data]>([])
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in },
                persistedDataReadObserver: { _, data in
                    observedPayloads.set([data])
                    readCaptured.signal()
                    _ = releaseRead.wait(timeout: .now() + 5)
                }
            )

            DispatchQueue.global(qos: .userInitiated).async {
                loaded.set(store.loadRecent(maximumDays: 1))
                loadFinished.signal()
            }
            XCTAssertEqual(readCaptured.wait(timeout: .now() + 5), .success)
            try FileManager.default.moveItem(at: memoryDirectory, to: detachedDirectory)
            try FileManager.default.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true
            )
            let replacementURL = memoryDirectory.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            try replacement.data.write(to: replacementURL, options: [.atomic])
            let replacementBytes = try Data(contentsOf: replacementURL)
            releaseRead.signal()
            XCTAssertEqual(loadFinished.wait(timeout: .now() + 5), .success)

            let recent = try XCTUnwrap(loaded.get())
            XCTAssertTrue(recent.memories.isEmpty)
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(observedPayloads.get(), [original.data])
            XCTAssertEqual(try Data(contentsOf: replacementURL), replacementBytes)
            XCTAssertEqual(
                try Data(
                    contentsOf: detachedDirectory.appendingPathComponent(
                        "2026-08-20.computer-history.json"
                    )
                ),
                original.data
            )
        }

        func testLoadRecentRejectsSelectedFileChangedInPlaceDuringDecode() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            var original = try legacyMemoryFixture(
                day: day,
                title: "Original selected file",
                summary: "The reader captures these bytes."
            ).data
            var replacement = try legacyMemoryFixture(
                day: day,
                title: "Changed selected file",
                summary: "A same-size in-place replacement must invalidate the result."
            ).data
            let equalByteCount = max(original.count, replacement.count)
            original.append(Data(repeating: 0x20, count: equalByteCount - original.count))
            replacement.append(Data(repeating: 0x20, count: equalByteCount - replacement.count))
            try writeMemoryFixture(original, dayKey: "2026-08-20", root: fixtureRoot)
            let jsonURL = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("2026-08-20.computer-history.json")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                ofItemAtPath: jsonURL.path
            )

            let readCaptured = DispatchSemaphore(value: 0)
            let releaseRead = DispatchSemaphore(value: 0)
            let loadFinished = DispatchSemaphore(value: 0)
            let loaded = LockedValue<ComputerHistoryRecentLoadResult?>(nil)
            var diagnostics: [String] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { diagnostics.append($0) },
                persistedDataReadObserver: { _, _ in
                    readCaptured.signal()
                    _ = releaseRead.wait(timeout: .now() + 5)
                }
            )

            DispatchQueue.global(qos: .userInitiated).async {
                loaded.set(store.loadRecent(maximumDays: 1))
                loadFinished.signal()
            }
            XCTAssertEqual(readCaptured.wait(timeout: .now() + 5), .success)
            try replacement.write(to: jsonURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: jsonURL.path
            )
            releaseRead.signal()
            XCTAssertEqual(loadFinished.wait(timeout: .now() + 5), .success)

            let recent = try XCTUnwrap(loaded.get())
            XCTAssertTrue(recent.memories.isEmpty)
            XCTAssertFalse(recent.isComplete)
            XCTAssertTrue(diagnostics.contains { $0.contains("selected recent-memory files changed") })
            XCTAssertEqual(try Data(contentsOf: jsonURL), replacement)
        }

        func testLoadRecentReportsIncompleteWhenBoundedBackfillCannotReachOlderValidMemory() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let oldestDay = makeDay(year: 2024, month: 1, day: 1)
            let oldest = try legacyMemoryFixture(
                day: oldestDay,
                title: "Older than the bounded window",
                summary: "Must be preserved as last-known-good, not returned inexactly."
            )
            try writeMemoryFixture(oldest.data, dayKey: dayKey(oldestDay), root: fixtureRoot)
            for offset in 1...513 {
                let day = try XCTUnwrap(
                    Calendar.current.date(byAdding: .day, value: offset, to: oldestDay)
                )
                try writeMemoryFixture(
                    Data("not-json".utf8),
                    dayKey: dayKey(day),
                    root: fixtureRoot
                )
            }

            var diagnostics: [String] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: 1_024 * 1_024,
                    defaultCumulativeBytes: 1_024 * 1_024,
                    absoluteCumulativeBytes: 1_024 * 1_024,
                    maximumDiagnosticMessages: 2,
                    maximumDirectoryEntries: 1_000,
                    maximumDirectoryEnumerationSeconds: 10
                ),
                diagnosticSink: { diagnostics.append($0) }
            )

            let recent = store.loadRecent(maximumDays: 1)
            XCTAssertTrue(recent.memories.isEmpty)
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(diagnostics.count, 2)
            XCTAssertTrue(diagnostics.last?.contains("512 bounded backfill candidates") == true)
            XCTAssertEqual(
                try Data(
                    contentsOf: fixtureRoot
                        .appendingPathComponent("computer-history", isDirectory: true)
                        .appendingPathComponent(dayKey(oldestDay) + ".computer-history.json")
                ),
                oldest.data
            )
        }

        func testLoadRecentEntryBudgetReturnsNoInexactPartialNewestResult() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let fixture = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 20),
                title: "Potentially partial",
                summary: "Must not be returned without exhausting the directory."
            )
            try writeMemoryFixture(fixture.data, dayKey: "2026-08-20", root: fixtureRoot)
            let directory = fixtureRoot.appendingPathComponent("computer-history", isDirectory: true)
            for index in 0 ..< 20 {
                XCTAssertTrue(
                    FileManager.default.createFile(
                        atPath: directory.appendingPathComponent(".extra-\(index).txt").path,
                        contents: Data()
                    )
                )
            }

            var loadedCount = 0
            var diagnostics: [String] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: 1_024 * 1_024,
                    defaultCumulativeBytes: 1_024 * 1_024,
                    absoluteCumulativeBytes: 1_024 * 1_024,
                    maximumDiagnosticMessages: 2,
                    maximumDirectoryEntries: 5,
                    maximumDirectoryEnumerationSeconds: 10
                ),
                diagnosticSink: { diagnostics.append($0) },
                persistedDataReadObserver: { _, _ in
                    loadedCount += 1
                }
            )

            let recent = store.loadRecent(maximumDays: 1)
            XCTAssertTrue(recent.memories.isEmpty)
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(loadedCount, 0)
            XCTAssertEqual(diagnostics.count, 1)
            XCTAssertTrue(diagnostics[0].contains("5-entry budget"))
            XCTAssertTrue(diagnostics[0].contains("no partial newest-day result"))
        }

        func testLoadRecentTimeBudgetIsDeterministicAndDiagnosticIsBounded() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let fixture = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 20),
                title: "Timed out",
                summary: "The injected monotonic clock makes this deterministic."
            )
            try writeMemoryFixture(fixture.data, dayKey: "2026-08-20", root: fixtureRoot)

            var clockReadCount = 0
            var diagnostics: [String] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: 1_024 * 1_024,
                    defaultCumulativeBytes: 1_024 * 1_024,
                    absoluteCumulativeBytes: 1_024 * 1_024,
                    maximumDiagnosticMessages: 2,
                    maximumDirectoryEntries: 100,
                    maximumDirectoryEnumerationSeconds: 1
                ),
                diagnosticSink: { diagnostics.append($0) },
                recentLoadClock: {
                    defer { clockReadCount += 1 }
                    return clockReadCount == 0 ? 0 : 2
                }
            )

            let recent = store.loadRecent(maximumDays: 1)
            XCTAssertTrue(recent.memories.isEmpty)
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(diagnostics.count, 1)
            XCTAssertTrue(diagnostics[0].contains("1.0-second time budget"))
            XCTAssertTrue(diagnostics[0].contains("no partial newest-day result"))
        }

        func testExtendedLoadUsesAbsoluteBudgetAndObservesOnlyBoundedPayloads() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            var fixtures: [(key: String, fixture: LegacyMemoryFixture)] = []
            for day in 18 ... 20 {
                let fixture = try legacyMemoryFixture(
                    day: makeDay(year: 2026, month: 8, day: day),
                    title: "Day \(day)",
                    summary: String(repeating: "evidence \(day) ", count: day)
                )
                let key = String(format: "2026-08-%02d", day)
                try writeMemoryFixture(fixture.data, dayKey: key, root: fixtureRoot)
                fixtures.append((key, fixture))
            }

            let sortedByNewest = fixtures.sorted { $0.key > $1.key }
            let absoluteBudget = sortedByNewest[0].fixture.data.count
                + sortedByNewest[1].fixture.data.count
            var observedPayloads: [(name: String, byteCount: Int)] = []
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: fixtures.map { $0.fixture.data.count }.max()! + 1,
                    defaultCumulativeBytes: 1,
                    absoluteCumulativeBytes: absoluteBudget,
                    maximumDiagnosticMessages: 2
                ),
                diagnosticSink: { _ in },
                persistedDataReadObserver: { url, data in
                    observedPayloads.append((url.lastPathComponent, data.count))
                }
            )

            let recent = store.loadRecent(maximumDays: 365)
            XCTAssertEqual(recent.memories.count, 2)
            XCTAssertFalse(recent.isComplete)
            XCTAssertEqual(
                observedPayloads.map { $0.name },
                sortedByNewest.prefix(2).map { $0.key + ".computer-history.json" }
            )
            XCTAssertLessThanOrEqual(
                observedPayloads.map { $0.byteCount }.reduce(0, +),
                absoluteBudget
            )
        }

        func testAnswerUsesDefaultThirtyDayEncodedBudget() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let older = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 19),
                title: "Older",
                summary: "older searchable memory"
            )
            let newest = try legacyMemoryFixture(
                day: makeDay(year: 2026, month: 8, day: 20),
                title: "Newest",
                summary: "newest searchable memory"
            )
            try writeMemoryFixture(older.data, dayKey: "2026-08-19", root: fixtureRoot)
            try writeMemoryFixture(newest.data, dayKey: "2026-08-20", root: fixtureRoot)

            var loadedCount = 0
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                recentLoadLimits: ComputerHistoryStore.RecentLoadLimits(
                    maximumSingleFileBytes: max(older.data.count, newest.data.count) + 1,
                    defaultCumulativeBytes: newest.data.count,
                    absoluteCumulativeBytes: older.data.count + newest.data.count,
                    maximumDiagnosticMessages: 1
                ),
                diagnosticSink: { _ in },
                persistedDataReadObserver: { _, _ in
                    loadedCount += 1
                }
            )

            let answer = store.answer("searchable")
            XCTAssertEqual(loadedCount, 1)
            XCTAssertTrue(
                answer.limitations.contains {
                    $0.contains("Retained Computer History loading was incomplete")
                        && $0.contains("absence is not exhaustive")
                }
            )
        }

        func testAnswerFindsRawOnlyEvidenceWithoutPersistingSearchState() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let now = Date()
            let day = Calendar.current.startOfDay(for: now)
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )
            _ = try store.write(
                makeMemory(
                    day: day,
                    title: "Representative memory",
                    summary: "The compact projection intentionally omits the raw-only anchor."
                ),
                for: day
            )
            let event = HistoryEvent(
                id: "raw-only-store-event",
                sessionID: "store-search",
                timestamp: now.addingTimeInterval(-60),
                kind: .windowChanged,
                app: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(
                    title: "heliotrope raw-only locator",
                    role: "AXWindow",
                    subrole: nil
                )
            )
            let eventsDirectory = fixtureRoot.appendingPathComponent(
                "events",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true
            )
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            let eventFile = eventsDirectory.appendingPathComponent(
                formatter.string(from: day) + ".jsonl"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var eventBytes = try encoder.encode(event)
            eventBytes.append(0x0A)
            try eventBytes.write(to: eventFile)
            let pathsBefore = Set(
                FileManager.default.enumerator(atPath: fixtureRoot.path)?
                    .compactMap { $0 as? String } ?? []
            )

            let answer = store.answer("heliotrope raw-only locator")

            XCTAssertEqual(
                answer.hits.first?.provenance.sourceEventIDs,
                [event.id]
            )
            XCTAssertTrue(answer.answer.contains("heliotrope raw-only locator"))
            XCTAssertTrue(
                answer.limitations.contains {
                    $0.contains("created no search index or persisted copy")
                }
            )
            XCTAssertEqual(
                Set(
                    FileManager.default.enumerator(atPath: fixtureRoot.path)?
                        .compactMap { $0 as? String } ?? []
                ),
                pathsBefore
            )
        }

        func testMissingSourceFailsClosedAndPreservesRetainedMemoryAndCodexMirror() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            _ = try store.write(
                makeMemory(day: day, title: "Temporary", summary: "Temporary fixture."),
                for: day
            )

            let JSONURL = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("2026-08-20.computer-history.json")
            let codexMarkdownURL = codexRoot.appendingPathComponent(
                "2026-08-20-goalong-computer-history.md"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: JSONURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: codexMarkdownURL.path))

            XCTAssertThrowsError(try store.buildAndWrite(for: day)) { error in
                XCTAssertTrue(error.localizedDescription.contains("could not be opened safely"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: JSONURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: codexMarkdownURL.path))
            XCTAssertEqual(store.loadStored(for: day)?.title, "Temporary")
        }

        func testBuildAndWriteRejectsCorruptPriorAndKeepsLastKnownGood() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let baselineStore = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )
            _ = try baselineStore.write(
                makeMemory(
                    day: day,
                    title: "Last known good",
                    summary: "A corrupt prior memory must not replace this day."
                ),
                for: day
            )
            try writeMemoryFixture(
                Data("not-json".utf8),
                dayKey: "2026-08-19",
                root: fixtureRoot
            )

            let jsonURL = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("2026-08-20.computer-history.json")
            let markdownURL = codexRoot.appendingPathComponent(
                "2026-08-20-goalong-computer-history.md"
            )
            let baselineJSON = try Data(contentsOf: jsonURL)
            let baselineMarkdown = try Data(contentsOf: markdownURL)
            let event = HistoryEvent(
                id: "corrupt-prior-build-event",
                sessionID: "corrupt-prior-build",
                timestamp: day.addingTimeInterval(3_600),
                kind: .windowChanged,
                app: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(
                    title: "A complete new source pass",
                    role: "AXWindow",
                    subrole: nil
                )
            )
            let evidence = ComputerHistoryEvidenceLoad(
                events: [event],
                semanticSnapshots: [:],
                sourceJournalSummary: ComputerHistorySourceJournalSummary(
                    eventCount: 1,
                    continuityBoundaryCount: 0,
                    firstSourceSequence: nil,
                    lastSourceSequence: nil,
                    lastSourceEventHash: nil
                ),
                issues: [],
                metrics: ComputerHistoryEvidenceLoadMetrics(
                    eventBytesRead: 1,
                    semanticBytesRead: 0,
                    peakStreamBufferBytes: 1,
                    rawEventCount: 1,
                    retainedEventCount: 1,
                    retainedEventBytes: 1,
                    semanticRowsVisited: 0,
                    retainedSemanticSnapshotCount: 0,
                    retainedSemanticSnapshotBytes: 0,
                    peakRetainedEvidenceRows: 1,
                    peakEstimatedRetainedEvidenceBytes: 1
                )
            )
            let rebuildingStore = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in },
                evidenceLoader: { _, _ in evidence }
            )

            XCTAssertThrowsError(try rebuildingStore.buildAndWrite(for: day)) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("incomplete recent-memory listing")
                )
            }
            XCTAssertEqual(try Data(contentsOf: jsonURL), baselineJSON)
            XCTAssertEqual(try Data(contentsOf: markdownURL), baselineMarkdown)
            XCTAssertEqual(rebuildingStore.loadStored(for: day)?.title, "Last known good")
        }

        func testBuildAndWriteRejectsIncompleteBoundedEvidenceAndKeepsLastKnownGood() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let baselineStore = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot,
                diagnosticSink: { _ in }
            )
            _ = try baselineStore.write(
                makeMemory(
                    day: day,
                    title: "Last known good",
                    summary: "Incomplete source passes must never replace these bytes."
                ),
                for: day
            )
            let jsonURL = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("2026-08-20.computer-history.json")
            let markdownURL = codexRoot.appendingPathComponent(
                "2026-08-20-goalong-computer-history.md"
            )
            let baselineJSON = try Data(contentsOf: jsonURL)
            let baselineMarkdown = try Data(contentsOf: markdownURL)
            let event = HistoryEvent(
                id: "bounded-build-event",
                sessionID: "bounded-build",
                timestamp: day.addingTimeInterval(3_600),
                kind: .windowChanged,
                app: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(
                    title: "A newer partial analysis",
                    role: "AXWindow",
                    subrole: nil
                )
            )
            let summary = ComputerHistorySourceJournalSummary(
                eventCount: 1,
                continuityBoundaryCount: 0,
                firstSourceSequence: nil,
                lastSourceSequence: nil,
                lastSourceEventHash: nil
            )
            let baseMetrics = ComputerHistoryEvidenceLoadMetrics(
                eventBytesRead: 1,
                semanticBytesRead: 0,
                peakStreamBufferBytes: 1,
                rawEventCount: 1,
                retainedEventCount: 1,
                retainedEventBytes: 1,
                semanticRowsVisited: 0,
                retainedSemanticSnapshotCount: 0,
                retainedSemanticSnapshotBytes: 0,
                peakRetainedEvidenceRows: 1,
                peakEstimatedRetainedEvidenceBytes: 1
            )
            let rejectedLoads: [(String, ComputerHistoryEvidenceLoad)] = [
                (
                    "cancelled",
                    ComputerHistoryEvidenceLoad(
                        events: [event],
                        semanticSnapshots: [:],
                        sourceJournalSummary: summary,
                        issues: [],
                        metrics: ComputerHistoryEvidenceLoadMetrics(
                            eventBytesRead: 1,
                            semanticBytesRead: 0,
                            peakStreamBufferBytes: 1,
                            rawEventCount: 1,
                            retainedEventCount: 1,
                            retainedEventBytes: 1,
                            semanticRowsVisited: 0,
                            retainedSemanticSnapshotCount: 0,
                            retainedSemanticSnapshotBytes: 0,
                            wasCancelled: true
                        )
                    )
                ),
                (
                    "changed",
                    ComputerHistoryEvidenceLoad(
                        events: [event],
                        semanticSnapshots: [:],
                        sourceJournalSummary: summary,
                        issues: [],
                        metrics: ComputerHistoryEvidenceLoadMetrics(
                            eventBytesRead: 1,
                            semanticBytesRead: 0,
                            peakStreamBufferBytes: 1,
                            rawEventCount: 1,
                            retainedEventCount: 1,
                            retainedEventBytes: 1,
                            semanticRowsVisited: 0,
                            retainedSemanticSnapshotCount: 0,
                            retainedSemanticSnapshotBytes: 0,
                            sourceChangedDuringRead: true
                        )
                    )
                ),
                (
                    "could not be opened safely",
                    ComputerHistoryEvidenceLoad(
                        events: [event],
                        semanticSnapshots: [:],
                        sourceJournalSummary: summary,
                        issues: [],
                        metrics: ComputerHistoryEvidenceLoadMetrics(
                            eventBytesRead: 1,
                            semanticBytesRead: 0,
                            peakStreamBufferBytes: 1,
                            rawEventCount: 1,
                            retainedEventCount: 1,
                            retainedEventBytes: 1,
                            semanticRowsVisited: 0,
                            retainedSemanticSnapshotCount: 0,
                            retainedSemanticSnapshotBytes: 0,
                            sourceAccessWasIncomplete: true
                        )
                    )
                ),
                (
                    "budget",
                    ComputerHistoryEvidenceLoad(
                        events: [event],
                        semanticSnapshots: [:],
                        sourceJournalSummary: summary,
                        issues: [],
                        metrics: ComputerHistoryEvidenceLoadMetrics(
                            eventBytesRead: 1,
                            semanticBytesRead: 0,
                            peakStreamBufferBytes: 1,
                            rawEventCount: 1,
                            retainedEventCount: 1,
                            retainedEventBytes: 1,
                            semanticRowsVisited: 0,
                            retainedSemanticSnapshotCount: 0,
                            retainedSemanticSnapshotBytes: 0,
                            evidenceBudgetExceeded: true
                        )
                    )
                ),
                (
                    "source gap",
                    ComputerHistoryEvidenceLoad(
                        events: [event],
                        semanticSnapshots: [:],
                        sourceJournalSummary: summary,
                        issues: [
                            HistoryLoadIssue(
                                path: "fixture",
                                line: nil,
                                message: "source gap"
                            )
                        ],
                        metrics: baseMetrics
                    )
                ),
            ]

            for (expectedReason, rejectedLoad) in rejectedLoads {
                let store = ComputerHistoryStore(
                    rootDirectory: fixtureRoot,
                    codexMemoryDirectory: codexRoot,
                    diagnosticSink: { _ in },
                    evidenceLoader: { _, _ in rejectedLoad }
                )
                XCTAssertThrowsError(try store.buildAndWrite(for: day)) { error in
                    XCTAssertTrue(error.localizedDescription.contains(expectedReason))
                }
                XCTAssertEqual(try Data(contentsOf: jsonURL), baselineJSON)
                XCTAssertEqual(try Data(contentsOf: markdownURL), baselineMarkdown)
                XCTAssertEqual(store.loadStored(for: day)?.title, "Last known good")
            }
        }

        func testMemoryFileURLsExposeCompactJSONAndSingleCodexMirror() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            _ = try store.write(
                makeMemory(day: day, title: "Visible", summary: "Visible fixture."),
                for: day
            )

            let URLs = store.memoryFileURLs(for: day)
            XCTAssertEqual(
                URLs.map(\.lastPathComponent),
                [
                    "2026-08-20.computer-history.json",
                    "2026-08-20-goalong-computer-history.md",
                ]
            )
            XCTAssertTrue(URLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixtureRoot
                        .appendingPathComponent("computer-history/2026-08-20.computer-history.md")
                        .path
                )
            )
        }

        func testWriteCreatesPrivateRegularFilesThroughValidatedDirectories() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fixtureRoot = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let codexRoot = container.appendingPathComponent("codex", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            let memory = makeMemory(
                day: day,
                title: "Secure write",
                summary: "Written through validated directory descriptors."
            )

            XCTAssertEqual(try store.write(memory, for: day), memory)
            XCTAssertEqual(store.loadStored(for: day), memory)

            let memoryRoot = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            for directory in [memoryRoot, codexRoot] {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            }
            for fileURL in store.memoryFileURLs(for: day) {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
        }

        func testWriteRejectsSymlinkedComputerHistoryRootWithoutTouchingExternalDirectory() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fixtureRoot = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let codexRoot = container.appendingPathComponent("codex", isDirectory: true)
            let externalRoot = container.appendingPathComponent("external", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)

            let sentinel = externalRoot.appendingPathComponent("sentinel.txt")
            try Data("external must remain unchanged".utf8).write(to: sentinel)
            let linkedMemoryRoot = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedMemoryRoot,
                withDestinationURL: externalRoot
            )

            let day = makeDay(year: 2026, month: 8, day: 20)
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            XCTAssertThrowsError(
                try store.write(
                    makeMemory(day: day, title: "Reject", summary: "Must not escape."),
                    for: day
                )
            )
            XCTAssertEqual(
                try Data(contentsOf: sentinel),
                Data("external must remain unchanged".utf8)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath:
                        externalRoot
                        .appendingPathComponent("2026-08-20.computer-history.json")
                        .path
                )
            )
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: linkedMemoryRoot.path),
                externalRoot.path
            )
        }

        func testWriteRejectsSymlinkedAncestorWithoutCreatingExternalStorage() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let externalRoot = container.appendingPathComponent("external", isDirectory: true)
            let linkedAncestor = container.appendingPathComponent("redirect", isDirectory: true)
            let fixtureRoot =
                linkedAncestor
                .appendingPathComponent("nested/LocalHistory", isDirectory: true)
            let codexRoot = container.appendingPathComponent("codex", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(
                at: externalRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedAncestor,
                withDestinationURL: externalRoot
            )

            let day = makeDay(year: 2026, month: 8, day: 20)
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            XCTAssertThrowsError(
                try store.write(
                    makeMemory(day: day, title: "Reject", summary: "Must not follow ancestor."),
                    for: day
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath:
                        externalRoot
                        .appendingPathComponent("nested/LocalHistory/computer-history")
                        .path
                )
            )
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: linkedAncestor.path),
                externalRoot.path
            )
        }

        func testExplicitDeletionRemovesOnlyOwnedMemoriesAtOrAfterCutoff() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            let firstDay = makeDay(year: 2026, month: 8, day: 19)
            let secondDay = makeDay(year: 2026, month: 8, day: 20)
            _ = try store.write(
                makeMemory(day: firstDay, title: "Keep", summary: "Older fixture."),
                for: firstDay
            )
            _ = try store.write(
                makeMemory(day: secondDay, title: "Delete", summary: "Newer fixture."),
                for: secondDay
            )
            let unrelated = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("notes.txt")
            try Data("keep".utf8).write(to: unrelated, options: [.atomic])

            XCTAssertEqual(try store.deleteMemories(since: secondDay), 2)
            XCTAssertNotNil(store.loadStored(for: firstDay))
            XCTAssertNil(store.loadStored(for: secondDay))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

            XCTAssertEqual(try store.deleteMemories(), 2)
            XCTAssertNil(store.loadStored(for: firstDay))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        }

        func testExplicitDeletionRejectsOwnedSymlinkBeforeDeletingAnything() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            let safeDay = makeDay(year: 2026, month: 8, day: 19)
            _ = try store.write(
                makeMemory(day: safeDay, title: "Safe", summary: "Must remain."),
                for: safeDay
            )
            let externalTarget = fixtureRoot.appendingPathComponent("external-target.txt")
            try Data("external".utf8).write(to: externalTarget, options: [.atomic])
            let ownedSymlink = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("2026-08-20.computer-history.json")
            try FileManager.default.createSymbolicLink(
                at: ownedSymlink,
                withDestinationURL: externalTarget
            )

            XCTAssertThrowsError(try store.deleteMemories())
            XCTAssertNotNil(store.loadStored(for: safeDay))
            XCTAssertTrue(FileManager.default.fileExists(atPath: externalTarget.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: ownedSymlink.path))
        }

        func testExplicitDeletionRejectsSymlinkedMemoryRootWithoutTouchingExternalFile() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fixtureRoot = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let codexRoot = container.appendingPathComponent("codex", isDirectory: true)
            let externalRoot = container.appendingPathComponent("external", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)

            let externalOwnedFile = externalRoot.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            try Data("external".utf8).write(to: externalOwnedFile, options: [.atomic])
            let linkedMemoryRoot = fixtureRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedMemoryRoot,
                withDestinationURL: externalRoot
            )

            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            XCTAssertThrowsError(try store.deleteMemories())
            XCTAssertEqual(try Data(contentsOf: externalOwnedFile), Data("external".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: linkedMemoryRoot.path))
        }

        func testExplicitDeletionRejectsSymlinkedAncestorWithoutTouchingExternalFile() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let externalRoot = container.appendingPathComponent("external-history", isDirectory: true)
            let externalMemoryRoot = externalRoot.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            let linkedFixtureRoot = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let codexRoot = container.appendingPathComponent("codex", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(
                at: externalMemoryRoot,
                withIntermediateDirectories: true
            )

            let externalOwnedFile = externalMemoryRoot.appendingPathComponent(
                "2026-08-20.computer-history.json"
            )
            try Data("external".utf8).write(to: externalOwnedFile, options: [.atomic])
            try FileManager.default.createSymbolicLink(
                at: linkedFixtureRoot,
                withDestinationURL: externalRoot
            )

            let store = ComputerHistoryStore(
                rootDirectory: linkedFixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            XCTAssertThrowsError(try store.deleteMemories())
            XCTAssertEqual(try Data(contentsOf: externalOwnedFile), Data("external".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: linkedFixtureRoot.path))
        }

        func testLaterMirrorPreflightFailureDoesNotDeleteGoalongMemory() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let codexRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: fixtureRoot)
                try? FileManager.default.removeItem(at: codexRoot)
            }

            let day = makeDay(year: 2026, month: 8, day: 20)
            let store = ComputerHistoryStore(
                rootDirectory: fixtureRoot,
                codexMemoryDirectory: codexRoot
            )
            _ = try store.write(
                makeMemory(day: day, title: "Keep", summary: "Must survive failed preflight."),
                for: day
            )

            let goalongMemory = fixtureRoot
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent("2026-08-20.computer-history.json")
            let codexMirror = codexRoot.appendingPathComponent(
                "2026-08-20-goalong-computer-history.md"
            )
            let external = fixtureRoot.appendingPathComponent("external.txt")
            try Data("external".utf8).write(to: external, options: [.atomic])
            try FileManager.default.removeItem(at: codexMirror)
            try FileManager.default.createSymbolicLink(
                at: codexMirror,
                withDestinationURL: external
            )

            XCTAssertThrowsError(try store.deleteMemories())
            XCTAssertNotNil(store.loadStored(for: day))
            XCTAssertTrue(FileManager.default.fileExists(atPath: goalongMemory.path))
            XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: codexMirror.path))
        }

        private struct LegacyMemoryFixture {
            let memory: ComputerHistoryDayMemory
            let data: Data
        }

        private final class LockedValue<Value> {
            private let lock = NSLock()
            private var value: Value

            init(_ value: Value) {
                self.value = value
            }

            func set(_ value: Value) {
                lock.lock()
                self.value = value
                lock.unlock()
            }

            func get() -> Value {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        private func legacyMemoryFixture(
            day: Date,
            title: String,
            summary: String
        ) throws -> LegacyMemoryFixture {
            let memory = makeMemory(day: day, title: title, summary: summary)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return LegacyMemoryFixture(memory: memory, data: try encoder.encode(memory))
        }

        private func writeMemoryFixture(_ data: Data, dayKey: String, root: URL) throws {
            let directory = root.appendingPathComponent("computer-history", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(
                to: directory.appendingPathComponent(dayKey + ".computer-history.json"),
                options: [.atomic]
            )
        }

        private func makeMemory(day: Date, title: String, summary: String) -> ComputerHistoryDayMemory {
            let dayStart = Calendar.current.startOfDay(for: day)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
                .addingTimeInterval(-0.001)
            let coverage = ComputerHistoryCoverage(
                sourceEventCount: 12,
                actionEventCount: 8,
                semanticSnapshotCount: 5,
                linkedInteractionCount: 4,
                interactionsWithBeforeAndAfterContext: 3,
                resourceCount: 0,
                episodeCount: 0,
                suppressedEventCount: 1,
                firstSourceSequence: 10,
                lastSourceSequence: 21,
                lastSourceEventHash: "fixture-hash"
            )
            let base = ComputerHistoryDayMemory(
                dayStart: dayStart,
                dayEnd: dayEnd,
                generatedAt: dayStart.addingTimeInterval(43_200),
                title: title,
                executiveSummary: summary,
                episodes: [],
                resources: [],
                workflowPatterns: [],
                suggestions: [],
                coverage: coverage,
                markdown: ""
            )
            return ComputerHistoryDayMemory(
                schemaVersion: base.schemaVersion,
                dayStart: base.dayStart,
                dayEnd: base.dayEnd,
                generatedAt: base.generatedAt,
                title: base.title,
                executiveSummary: base.executiveSummary,
                episodes: base.episodes,
                resources: base.resources,
                workflowPatterns: base.workflowPatterns,
                suggestions: base.suggestions,
                coverage: base.coverage,
                markdown: ComputerHistoryMarkdownRenderer.render(base),
                securityNotice: base.securityNotice
            )
        }

        private func makeUnboundedLegacyMemory(
            day: Date,
            episodeCount: Int
        ) -> ComputerHistoryDayMemory {
            let dayStart = Calendar.current.startOfDay(for: day)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
                .addingTimeInterval(-0.001)
            let provenance = ActivityProvenance(
                sourceEventIDs: ["legacy-source"],
                sourceSequences: [1],
                sourceEventHashes: ["legacy-source-hash"]
            )
            let episodes = (0..<episodeCount).map { index in
                let timestamp = dayStart.addingTimeInterval(TimeInterval(index * 2))
                let interaction = ComputerHistoryInteraction(
                    id: "legacy-interaction-\(index)",
                    start: timestamp,
                    end: timestamp,
                    action: .click,
                    label: "Legacy action \(index)",
                    application: "Fixture",
                    bundleIdentifier: "com.goalong.fixture",
                    host: "fixture.example",
                    resourceIDs: [],
                    beforeContext: nil,
                    afterContext: nil,
                    semanticDelta: ["Observed legacy state \(index)"],
                    confidence: 0.9,
                    provenance: provenance
                )
                return ComputerHistoryEpisode(
                    id: "legacy-episode-\(index)",
                    start: timestamp,
                    end: timestamp,
                    title: "Legacy episode \(index)",
                    summary: "Legacy derived summary \(index)",
                    status: .inProgress,
                    statusConfidence: 0.7,
                    applications: ["Fixture"],
                    sites: ["fixture.example"],
                    resourceIDs: [],
                    requestsOrIntentions: [],
                    observableOutcomes: [],
                    interactions: [interaction],
                    eventCount: 1,
                    semanticSnapshotCount: 0,
                    workflowFingerprint: "legacy-workflow-\(index)",
                    provenance: provenance
                )
            }
            let coverage = ComputerHistoryCoverage(
                sourceEventCount: episodeCount,
                actionEventCount: episodeCount,
                semanticSnapshotCount: 0,
                linkedInteractionCount: episodeCount,
                interactionsWithBeforeAndAfterContext: 0,
                resourceCount: 0,
                episodeCount: episodeCount,
                suppressedEventCount: 0,
                firstSourceSequence: 1,
                lastSourceSequence: UInt64(episodeCount),
                lastSourceEventHash: "legacy-last-hash"
            )
            let base = ComputerHistoryDayMemory(
                dayStart: dayStart,
                dayEnd: dayEnd,
                generatedAt: dayStart.addingTimeInterval(43_200),
                title: "Legacy unbounded fixture",
                executiveSummary: "All exact counts must survive derived-memory compaction.",
                episodes: episodes,
                resources: [],
                workflowPatterns: [],
                suggestions: [],
                coverage: coverage,
                markdown: ""
            )
            return ComputerHistoryDayMemory(
                schemaVersion: base.schemaVersion,
                dayStart: base.dayStart,
                dayEnd: base.dayEnd,
                generatedAt: base.generatedAt,
                title: base.title,
                executiveSummary: base.executiveSummary,
                episodes: base.episodes,
                resources: base.resources,
                workflowPatterns: base.workflowPatterns,
                suggestions: base.suggestions,
                coverage: base.coverage,
                markdown: ComputerHistoryMarkdownRenderer.render(base),
                securityNotice: base.securityNotice
            )
        }

        private func replacingGeneratedAt(
            _ memory: ComputerHistoryDayMemory,
            with generatedAt: Date
        ) -> ComputerHistoryDayMemory {
            let base = ComputerHistoryDayMemory(
                schemaVersion: memory.schemaVersion,
                dayStart: memory.dayStart,
                dayEnd: memory.dayEnd,
                generatedAt: generatedAt,
                title: memory.title,
                executiveSummary: memory.executiveSummary,
                episodes: memory.episodes,
                resources: memory.resources,
                workflowPatterns: memory.workflowPatterns,
                suggestions: memory.suggestions,
                coverage: memory.coverage,
                markdown: "",
                securityNotice: memory.securityNotice
            )
            return ComputerHistoryDayMemory(
                schemaVersion: base.schemaVersion,
                dayStart: base.dayStart,
                dayEnd: base.dayEnd,
                generatedAt: base.generatedAt,
                title: base.title,
                executiveSummary: base.executiveSummary,
                episodes: base.episodes,
                resources: base.resources,
                workflowPatterns: base.workflowPatterns,
                suggestions: base.suggestions,
                coverage: base.coverage,
                markdown: ComputerHistoryMarkdownRenderer.render(base),
                securityNotice: base.securityNotice
            )
        }

        private func replacingMarkdown(
            _ memory: ComputerHistoryDayMemory,
            with markdown: String
        ) -> ComputerHistoryDayMemory {
            ComputerHistoryDayMemory(
                schemaVersion: memory.schemaVersion,
                dayStart: memory.dayStart,
                dayEnd: memory.dayEnd,
                generatedAt: memory.generatedAt,
                title: memory.title,
                executiveSummary: memory.executiveSummary,
                episodes: memory.episodes,
                resources: memory.resources,
                workflowPatterns: memory.workflowPatterns,
                suggestions: memory.suggestions,
                coverage: memory.coverage,
                markdown: markdown,
                securityNotice: memory.securityNotice
            )
        }

        private func makeDay(year: Int, month: Int, day: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: 12)
            )!
        }

        private func dayKey(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }
#endif
