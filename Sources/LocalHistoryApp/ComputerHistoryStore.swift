#if os(macOS)
    import Foundation
    import LocalHistoryCore

    /// Persists the full-fidelity causal memory separately from regenerable minute-level
    /// analysis. A Markdown mirror is also written to Codex's local memory extension
    /// directory so future Codex sessions can discover the same reviewed history.
    final class ComputerHistoryStore {
        private let fileManager = FileManager.default
        private let rootDirectory: URL
        private let memoryDirectory: URL
        private let codexMemoryDirectory: URL

        init(rootDirectory: URL = AppPaths.applicationSupportDirectory) {
            self.rootDirectory = rootDirectory
            memoryDirectory = rootDirectory.appendingPathComponent("computer-history", isDirectory: true)
            let configuredCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            codexMemoryDirectory = configuredCodexHome
                .appendingPathComponent("memories", isDirectory: true)
                .appendingPathComponent("extensions", isDirectory: true)
                .appendingPathComponent("goalong", isDirectory: true)
        }

        @discardableResult
        func buildAndWrite(for day: Date) throws -> ComputerHistoryDayMemory? {
            let start = Calendar.current.startOfDay(for: day)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
            let loaded = HistoryLocalStoreReader(rootDirectory: rootDirectory).load(
                start: start,
                end: next.addingTimeInterval(-0.001)
            )
            guard !loaded.events.isEmpty else {
                removeStored(for: start)
                return nil
            }
            for issue in loaded.issues {
                Diagnostics.write(
                    "Computer History load gap: \(issue.path):\(issue.line.map(String.init) ?? "-") \(issue.message)"
                )
            }

            let prior = loadRecent(before: start, maximumDays: 30)
            let memory = ComputerHistoryEngine.analyze(
                events: loaded.events,
                semanticSnapshots: loaded.semanticSnapshots,
                day: start,
                priorMemories: prior
            )
            try write(memory, for: start)
            return memory
        }

        func loadStored(for day: Date) -> ComputerHistoryDayMemory? {
            let URL = JSONFile(for: day)
            guard let data = try? Data(contentsOf: URL) else { return nil }
            return try? Self.decoder.decode(ComputerHistoryDayMemory.self, from: data)
        }

        func loadRecent(maximumDays: Int = 30) -> [ComputerHistoryDayMemory] {
            loadRecent(before: .distantFuture, maximumDays: maximumDays)
        }

        func answer(_ query: String, maximumDays: Int = 30) -> ComputerHistoryAnswer {
            ComputerHistorySearchService(memories: loadRecent(maximumDays: maximumDays)).ask(query)
        }

        func modificationDate(for day: Date) -> Date? {
            let eventFile = rootDirectory
                .appendingPathComponent("events", isDirectory: true)
                .appendingPathComponent(dayString(day) + ".jsonl")
            return try? eventFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        private func loadRecent(before date: Date, maximumDays: Int) -> [ComputerHistoryDayMemory] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: memoryDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            let limit = min(max(1, maximumDays), 365)
            return files
                .filter { $0.lastPathComponent.hasSuffix(".computer-history.json") }
                .compactMap { URL -> ComputerHistoryDayMemory? in
                    guard let data = try? Data(contentsOf: URL),
                        let value = try? Self.decoder.decode(ComputerHistoryDayMemory.self, from: data),
                        value.dayStart < date
                    else { return nil }
                    return value
                }
                .sorted { $0.dayStart < $1.dayStart }
                .suffix(limit)
                .map { $0 }
        }

        private func write(_ memory: ComputerHistoryDayMemory, for day: Date) throws {
            try prepareDirectory(memoryDirectory)
            let JSONURL = JSONFile(for: day)
            let markdownURL = MarkdownFile(for: day)
            try Self.encoder.encode(memory).write(to: JSONURL, options: .atomic)
            try Data(memory.markdown.utf8).write(to: markdownURL, options: .atomic)
            secure([JSONURL, markdownURL])

            do {
                try prepareDirectory(codexMemoryDirectory)
                let codexURL = codexMemoryDirectory.appendingPathComponent(
                    dayString(day) + "-goalong-computer-history.md"
                )
                try Data(memory.markdown.utf8).write(to: codexURL, options: .atomic)
                secure([codexURL])
            } catch {
                // The Goalong copy remains authoritative if a custom CODEX_HOME is unavailable.
                Diagnostics.write("Could not mirror Computer History memory into Codex: \(error)")
            }
        }

        private func removeStored(for day: Date) {
            for URL in [JSONFile(for: day), MarkdownFile(for: day)] {
                try? fileManager.removeItem(at: URL)
            }
        }

        private func JSONFile(for day: Date) -> URL {
            memoryDirectory.appendingPathComponent(dayString(day) + ".computer-history.json")
        }

        private func MarkdownFile(for day: Date) -> URL {
            memoryDirectory.appendingPathComponent(dayString(day) + ".computer-history.md")
        }

        private func prepareDirectory(_ URL: URL) throws {
            try fileManager.createDirectory(
                at: URL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: URL.path)
        }

        private func secure(_ URLs: [URL]) {
            for URL in URLs {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: URL.path)
            }
        }

        private func dayString(_ date: Date) -> String {
            Self.dayFormatter.string(from: Calendar.current.startOfDay(for: date))
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()

        private static let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()

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
