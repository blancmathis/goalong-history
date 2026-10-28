#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// T-045 H2: defects found in zones no earlier round audited.
    final class T045H2Tests: XCTestCase {
        /// H2-01: a failed « Effacer l’historique » showed the store's English debug sentence
        /// and the private path in the French alert « Échec de la suppression ».
        func testHistoryClearFailuresShowFrenchTextWithoutPaths() throws {
            let root = try makeDirectory()
            let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let store = try JSONLStore(retentionDays: 0, eventsDirectory: events, prepareApplicationStorage: false)
            try FileManager.default.removeItem(at: events)
            try FileManager.default.createSymbolicLink(at: events, withDestinationURL: elsewhere)
            assertFrenchAlert(try XCTUnwrap(deleteEvents(store)), hiding: events.path)

            let semantic = root.appendingPathComponent("semantic", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: semantic, withDestinationURL: elsewhere)
            let semanticStore = SemanticContextStore(semanticDirectory: semantic, secureInputEnabled: { false })
            assertFrenchAlert(try XCTUnwrap(deleteSemantic(semanticStore)), hiding: semantic.path)

            let derivedRoot = root.appendingPathComponent("derived-root")
            try FileManager.default.createSymbolicLink(at: derivedRoot, withDestinationURL: elsewhere)
            do {
                _ = try DerivedHistoryCleaner(rootDirectory: derivedRoot, codexMemoryDirectory: elsewhere)
                    .prepareDeletion(since: Date())
                XCTFail("an unsafe derived root must refuse the clear")
            } catch {
                assertFrenchAlert(error, hiding: derivedRoot.path)
            }
        }

        /// H2-01: the French I/O sentence keeps what `strerror` told before (full disk, refused access).
        func testHistoryIOMessageKeepsTheErrnoMeaning() {
            XCTAssertEqual(GoalongUserFacingError.historyIOMessage(code: ENOSPC), GoalongUserFacingError.historyDiskFullMessage)
            XCTAssertEqual(GoalongUserFacingError.historyIOMessage(code: EACCES), GoalongUserFacingError.historyAccessDeniedMessage)
            XCTAssertEqual(GoalongUserFacingError.historyIOMessage(code: EIO), GoalongUserFacingError.historyIOMessage)
        }

        /// D-150b: the Computer History page showed the store's English sentence and the private path
        /// when a day could not be written (`ComputerHistoryPageModel.displayMessage`).
        func testComputerHistoryStorageFailuresShowFrenchTextWithoutPaths() {
            let url = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Goalong/computer-history/2026-10-28.json")
            let failures: [ComputerHistoryStore.StorageError] = [
                .incompleteRecentMemoryListing,
                .incompleteSourceEvidence("the bounded source pass was cancelled"),
                .memoryTooLarge(actualBytes: 9_000_000, maximumBytes: 8_000_000),
                .storedMemoryChangedDuringRead(url),
                .unsafeStoragePath(url),
                .posix(operation: "openat", URL: url, code: ENOSPC),
                .posix(operation: "openat", URL: url, code: EACCES),
                .posix(operation: "openat", URL: url, code: EIO),
            ]
            for failure in failures {
                let text = ComputerHistoryPageModel.displayMessage(for: failure)
                assertFrenchAlert(failure, hiding: url.path)
                XCTAssertFalse(text.contains("Computer History"), text)
                XCTAssertFalse(text.contains("bytes"), text)
                XCTAssertNotNil(failure.errorDescription)
            }
            XCTAssertTrue(ComputerHistoryStore.StorageError.unsafeStoragePath(url).errorDescription?.contains(url.path) == true)
        }

        private func assertFrenchAlert(_ error: Error, hiding path: String, line: UInt = #line) {
            let text = GoalongUserFacingError.message(error)
            for english in ["The ", "Could not", "Refusing", "failed for", "Deletion", "Owned path"] {
                XCTAssertFalse(text.contains(english), text, line: line)
            }
            XCTAssertFalse(text.contains(path), text, line: line)
            XCTAssertNotEqual(text, GoalongUserFacingError.genericMessage, line: line)
        }

        private func deleteEvents(_ store: JSONLStore) -> Error? {
            let done = expectation(description: "events clear")
            var failure: Error?
            store.deleteEvents(since: Date().addingTimeInterval(-600)) {
                if case .failure(let error) = $0 { failure = error }
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return failure
        }

        private func deleteSemantic(_ store: SemanticContextStore) -> Error? {
            let done = expectation(description: "semantic clear")
            var failure: Error?
            store.deleteEvents(since: Date().addingTimeInterval(-600)) {
                if case .failure(let error) = $0 { failure = error }
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return failure
        }

        private func makeDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-t045h2-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            return directory.resolvingSymlinksInPath()
        }
    }
#endif
