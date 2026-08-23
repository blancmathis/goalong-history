#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class LocalActivityMemoryStore {
        private let summarizer: any ActivitySummarizer
        private let rootDirectory: URL
        private let memoryDirectory: URL
        private let fileManager: FileManager

        init(
            summarizer: any ActivitySummarizer = DeterministicActivitySummarizer(),
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            fileManager: FileManager = .default
        ) {
            self.summarizer = summarizer
            self.rootDirectory = rootDirectory
            self.fileManager = fileManager
            memoryDirectory = rootDirectory.appendingPathComponent("memories", isDirectory: true)
        }

        @discardableResult
        func buildAndWrite(for day: Date) throws -> ActivityMemory? {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let end = next.addingTimeInterval(-0.001)
            let loaded = HistoryLocalStoreReader(
                rootDirectory: rootDirectory
            ).load(start: start, end: end)
            guard !loaded.events.isEmpty else {
                removeStored(for: start)
                return nil
            }

            let memory = try summarizer.summarize(
                ActivitySummaryInput(
                    events: loaded.events,
                    intervalStart: start,
                    intervalEnd: end,
                    semanticSnapshots: loaded.semanticSnapshots
                )
            )
            try prepareDirectory()
            let base = Self.dayFormatter.string(from: start) + ".memory"
            let JSONURL = memoryDirectory.appendingPathComponent(base + ".json")
            let MarkdownURL = memoryDirectory.appendingPathComponent(base + ".md")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(memory).write(to: JSONURL, options: .atomic)
            try Data(ActivityMemoryMarkdownRenderer.render(memory).utf8)
                .write(to: MarkdownURL, options: .atomic)
            secure([JSONURL, MarkdownURL])
            return memory
        }

        @discardableResult
        func removeStored(for day: Date) -> Int {
            let base = Self.dayFormatter.string(
                from: Calendar.current.startOfDay(for: day)
            ) + ".memory"
            return remove([
                memoryDirectory.appendingPathComponent(base + ".json"),
                memoryDirectory.appendingPathComponent(base + ".md"),
            ])
        }

        @discardableResult
        func removeAllStored() -> Int {
            removeAllFiles(in: memoryDirectory)
        }

        private func prepareDirectory() throws {
            try fileManager.createDirectory(
                at: memoryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: memoryDirectory.path
            )
        }

        private func secure(_ URLs: [URL]) {
            for URL in URLs {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: URL.path
                )
            }
        }

        private func remove(_ URLs: [URL]) -> Int {
            var removed = 0
            for URL in URLs where fileManager.fileExists(atPath: URL.path) {
                do {
                    try fileManager.removeItem(at: URL)
                    removed += 1
                } catch {
                    Diagnostics.write("Could not remove derived memory \(URL.path): \(error)")
                }
            }
            return removed
        }

        private func removeAllFiles(in directory: URL) -> Int {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            return remove(files)
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
