#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class JSONLStore {
        private let queue = DispatchQueue(label: "ai.goalong.localhistory.jsonl-store")
        private let encoder: JSONEncoder
        private let decoder: JSONDecoder
        private let retentionDays: Int

        private var currentFileURL: URL?
        private var currentHandle: FileHandle?
        private var writesSinceSync = 0

        init(retentionDays: Int) throws {
            self.retentionDays = retentionDays

            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]

            decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            try AppPaths.prepare()
            purgeExpiredFilesSynchronously()
        }

        func append(_ event: HistoryEvent) {
            queue.async { [weak self] in
                self?.appendSynchronously(event)
            }
        }

        func flush() {
            queue.sync {
                try? currentHandle?.synchronize()
            }
        }

        func close() {
            queue.sync {
                closeCurrentHandle()
            }
        }

        func deleteEvents(since cutoff: Date, completion: @escaping (Result<Int, Error>) -> Void) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    self.closeCurrentHandle()
                    let deleted = try self.rewriteFilesKeepingEvents(before: cutoff)
                    DispatchQueue.main.async { completion(.success(deleted)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        func deleteAll(completion: @escaping (Result<Int, Error>) -> Void) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    self.closeCurrentHandle()
                    let files = try self.eventFiles()
                    for file in files {
                        try FileManager.default.removeItem(at: file)
                    }
                    DispatchQueue.main.async { completion(.success(files.count)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        private func appendSynchronously(_ event: HistoryEvent) {
            do {
                let destination = AppPaths.eventFileURL(for: event.timestamp)
                try ensureHandle(for: destination)

                var data = try encoder.encode(event)
                data.append(0x0A)
                try currentHandle?.write(contentsOf: data)
                writesSinceSync += 1

                if writesSinceSync >= 20 {
                    try currentHandle?.synchronize()
                    writesSinceSync = 0
                }
            } catch {
                Diagnostics.write("Failed to append event: \(error)")
            }
        }

        private func ensureHandle(for url: URL) throws {
            if currentFileURL == url, currentHandle != nil { return }
            closeCurrentHandle()

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            currentFileURL = url
            currentHandle = handle
        }

        private func closeCurrentHandle() {
            if let handle = currentHandle {
                try? handle.synchronize()
                try? handle.close()
            }
            currentHandle = nil
            currentFileURL = nil
            writesSinceSync = 0
        }

        private func eventFiles() throws -> [URL] {
            let files = try FileManager.default.contentsOfDirectory(
                at: AppPaths.eventsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        private func rewriteFilesKeepingEvents(before cutoff: Date) throws -> Int {
            var deletedCount = 0

            for file in try eventFiles() {
                let data = try Data(contentsOf: file)
                guard let content = String(data: data, encoding: .utf8) else { continue }

                var keptLines: [Substring] = []
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let lineData = String(line).data(using: .utf8),
                        let event = try? decoder.decode(HistoryEvent.self, from: lineData)
                    else {
                        keptLines.append(line)
                        continue
                    }

                    if event.timestamp >= cutoff {
                        deletedCount += 1
                    } else {
                        keptLines.append(line)
                    }
                }

                if keptLines.isEmpty {
                    try FileManager.default.removeItem(at: file)
                } else {
                    let rendered = keptLines.map(String.init).joined(separator: "\n") + "\n"
                    guard let output = rendered.data(using: .utf8) else { continue }
                    try output.write(to: file, options: [.atomic])
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            }

            return deletedCount
        }

        private func purgeExpiredFilesSynchronously() {
            guard retentionDays > 0 else { return }
            let calendar = Calendar.current
            guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }

            do {
                for file in try eventFiles() {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                    if let modificationDate = values.contentModificationDate, modificationDate < cutoff {
                        try FileManager.default.removeItem(at: file)
                    }
                }
            } catch {
                Diagnostics.write("Retention cleanup failed: \(error)")
            }
        }
    }
#endif
