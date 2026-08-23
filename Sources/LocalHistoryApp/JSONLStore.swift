#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class JSONLStore {
        private let queue = DispatchQueue(label: "ai.goalong.localhistory.jsonl-store")
        private let encoder: JSONEncoder
        private let retentionDays: Int
        private let rootDirectory: URL
        private let eventsDirectory: URL
        private let fileManager: FileManager

        private var currentFileURL: URL?
        private var currentHandle: FileHandle?
        private var writesSinceSync = 0

        init(
            retentionDays: Int,
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            fileManager: FileManager = .default
        ) throws {
            self.retentionDays = retentionDays
            self.rootDirectory = rootDirectory
            self.fileManager = fileManager
            eventsDirectory = rootDirectory.appendingPathComponent("events", isDirectory: true)

            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]

            try prepareDirectories()
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

        func delete(
            _ request: HistoryDeletionRequest,
            completion: @escaping (Result<HistoryEventDeletionResult, Error>) -> Void
        ) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    self.closeCurrentHandle()
                    let result = try HistoryJSONLDeletionEngine.deleteEvents(
                        in: self.eventsDirectory,
                        request: request,
                        fileManager: self.fileManager
                    )
                    DispatchQueue.main.async { completion(.success(result)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        /// Compatibility wrapper for older menu and dashboard call sites.
        func deleteEvents(since cutoff: Date, completion: @escaping (Result<Int, Error>) -> Void) {
            delete(
                HistoryDeletionRequest(
                    scope: .interval,
                    start: cutoff,
                    end: .distantFuture
                )
            ) { result in
                completion(result.map(\.deletedEventCount))
            }
        }

        /// Compatibility wrapper for older menu and dashboard call sites.
        func deleteAll(completion: @escaping (Result<Int, Error>) -> Void) {
            delete(HistoryDeletionRequest(scope: .allDetailedData)) { result in
                completion(result.map(\.deletedEventCount))
            }
        }

        private func appendSynchronously(_ event: HistoryEvent) {
            do {
                let destination = eventFileURL(for: event.timestamp)
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

        private func ensureHandle(for URL: URL) throws {
            if currentFileURL == URL, currentHandle != nil { return }
            closeCurrentHandle()

            if !fileManager.fileExists(atPath: URL.path) {
                fileManager.createFile(
                    atPath: URL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: URL.path
            )

            let handle = try FileHandle(forWritingTo: URL)
            try handle.seekToEnd()
            currentFileURL = URL
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

        private func prepareDirectories() throws {
            try fileManager.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootDirectory.path
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: eventsDirectory.path
            )
        }

        private func eventFileURL(for date: Date) -> URL {
            eventsDirectory.appendingPathComponent(Self.dayFormatter.string(from: date) + ".jsonl")
        }

        private func eventFiles() throws -> [URL] {
            guard fileManager.fileExists(atPath: eventsDirectory.path) else { return [] }
            let files = try fileManager.contentsOfDirectory(
                at: eventsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return files.filter { $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        private func purgeExpiredFilesSynchronously() {
            guard retentionDays > 0 else { return }
            let calendar = Calendar.current
            guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: Date()) else {
                return
            }

            do {
                for file in try eventFiles() {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                    if let modificationDate = values.contentModificationDate,
                        modificationDate < cutoff
                    {
                        try fileManager.removeItem(at: file)
                    }
                }
            } catch {
                Diagnostics.write("Retention cleanup failed: \(error)")
            }
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
#endif
