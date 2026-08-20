#if os(macOS)
    import Carbon
    import Foundation
    import LocalHistoryCore

    final class SemanticContextStore {
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.semantic-context",
            qos: .utility
        )

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
            let file = AppPaths.semanticFileURL(for: timestamp)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(payload)
            data.append(0x0A)

            try queue.sync {
                try AppPaths.prepare()
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(
                        atPath: file.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                try? FileManager.default.setAttributes(
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

        func deleteEvents(
            since cutoff: Date,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            queue.async {
                do {
                    let files = try self.semanticFiles()
                    var deleted = 0
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    for file in files {
                        let data = try Data(contentsOf: file)
                        let lines = data.split(separator: 0x0A)
                        var kept = Data()
                        for line in lines {
                            let payload = try decoder.decode(SemanticContextPayload.self, from: Data(line))
                            if payload.capturedAt >= cutoff {
                                deleted += 1
                            } else {
                                kept.append(line)
                                kept.append(0x0A)
                            }
                        }
                        if kept.isEmpty {
                            try? FileManager.default.removeItem(at: file)
                        } else {
                            try kept.write(to: file, options: .atomic)
                            try? FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: file.path
                            )
                        }
                    }
                    DispatchQueue.main.async { completion(.success(deleted)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        func deleteAll(completion: @escaping (Result<Int, Error>) -> Void) {
            queue.async {
                do {
                    let files = try self.semanticFiles()
                    for file in files { try FileManager.default.removeItem(at: file) }
                    DispatchQueue.main.async { completion(.success(files.count)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        private func semanticFiles() throws -> [URL] {
            guard FileManager.default.fileExists(atPath: AppPaths.semanticDirectory.path) else {
                return []
            }
            return try FileManager.default.contentsOfDirectory(
                at: AppPaths.semanticDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "jsonl" }
        }

        private func source(from raw: String) -> SemanticContextSource {
            let values = Set(raw.split(separator: "+").map(String.init))
            if values.count > 1 { return .mixed }
            if values.contains("selected") { return .selectedText }
            if values.contains("focused") { return .focusedValue }
            return .visibleText
        }
    }

    enum SemanticContextStoreError: Error {
        case suppressedOrEmpty
    }
#endif
