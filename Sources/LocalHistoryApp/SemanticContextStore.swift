#if os(macOS)
    import Carbon
    import Foundation
    import LocalHistoryCore

    final class SemanticContextStore {
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.semantic-context",
            qos: .utility
        )
        private let rootDirectory: URL
        private let semanticDirectory: URL
        private let fileManager: FileManager

        init(
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            fileManager: FileManager = .default
        ) {
            self.rootDirectory = rootDirectory
            self.fileManager = fileManager
            semanticDirectory = rootDirectory.appendingPathComponent("semantic", isDirectory: true)
        }

        func append(
            capture: AXRichContextCapture,
            context: ContextSnapshot,
            timestamp: Date = Date()
        ) throws -> SemanticContextReference {
            let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                !IsSecureEventInputEnabled(),
                context.suppressionReason == nil,
                context.focusedElement?.isSecure != true
            else {
                throw SemanticContextStoreError.suppressedOrEmpty
            }

            let payload = SemanticContextPayload(
                id: UUID().uuidString,
                capturedAt: timestamp,
                application: context.app,
                window: context.window,
                url: context.url,
                focusedRole: context.focusedElement?.role,
                source: source(from: capture.source),
                text: text,
                contentSHA256: SHA256Digest.hashHex(text),
                redacted: capture.redacted,
                truncated: capture.truncated
            )
            let reference = payload.reference
            let file = semanticFileURL(for: timestamp)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(payload)
            data.append(0x0A)

            try queue.sync {
                try prepareDirectories()
                if !fileManager.fileExists(atPath: file.path) {
                    fileManager.createFile(
                        atPath: file.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            return reference
        }

        func delete(
            _ request: HistoryDeletionRequest,
            additionallyDeleting snapshotIDs: [String] = [],
            completion: @escaping (Result<HistorySemanticDeletionResult, Error>) -> Void
        ) {
            queue.async {
                do {
                    let result = try HistoryJSONLDeletionEngine.deleteSemanticSnapshots(
                        in: self.semanticDirectory,
                        request: request,
                        additionallyDeleting: snapshotIDs,
                        fileManager: self.fileManager
                    )
                    DispatchQueue.main.async { completion(.success(result)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        /// Compatibility wrapper for older dashboard call sites.
        func deleteEvents(
            since cutoff: Date,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            delete(
                HistoryDeletionRequest(
                    scope: .interval,
                    start: cutoff,
                    end: .distantFuture
                )
            ) { result in
                completion(result.map(\.deletedSnapshotCount))
            }
        }

        /// Compatibility wrapper for older dashboard call sites.
        func deleteAll(completion: @escaping (Result<Int, Error>) -> Void) {
            delete(HistoryDeletionRequest(scope: .allDetailedData)) { result in
                completion(result.map(\.deletedSnapshotCount))
            }
        }

        private func prepareDirectories() throws {
            try fileManager.createDirectory(
                at: semanticDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootDirectory.path
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: semanticDirectory.path
            )
        }

        private func semanticFileURL(for date: Date) -> URL {
            semanticDirectory.appendingPathComponent(
                Self.dayFormatter.string(from: date) + ".semantic.jsonl"
            )
        }

        private func source(from raw: String) -> SemanticContextSource {
            let values = Set(raw.split(separator: "+").map(String.init))
            if values.count > 1 { return .mixed }
            if values.contains("selected") { return .selectedText }
            if values.contains("focused") { return .focusedValue }
            return .visibleText
        }

        private static let dayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()
    }

    enum SemanticContextStoreError: Error {
        case suppressedOrEmpty
    }
#endif
