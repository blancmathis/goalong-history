#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class LocalActivityMemoryStore {
        private let summarizer: any ActivitySummarizer

        init(summarizer: any ActivitySummarizer = DeterministicActivitySummarizer()) {
            self.summarizer = summarizer
        }

        @discardableResult
        func buildAndWrite(for day: Date) throws -> ActivityMemory? {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let end = next.addingTimeInterval(-0.001)
            let loaded = HistoryLocalStoreReader(
                rootDirectory: AppPaths.applicationSupportDirectory
            ).load(start: start, end: end)
            guard !loaded.events.isEmpty else { return nil }

            let memory = try summarizer.summarize(
                ActivitySummaryInput(
                    events: loaded.events,
                    intervalStart: start,
                    intervalEnd: end,
                    semanticSnapshots: loaded.semanticSnapshots
                )
            )
            try AppPaths.prepare()
            let base = AppPaths.localDayString(for: start) + ".memory"
            let JSONURL = AppPaths.memoriesDirectory.appendingPathComponent(base + ".json")
            let MarkdownURL = AppPaths.memoriesDirectory.appendingPathComponent(base + ".md")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(memory).write(to: JSONURL, options: .atomic)
            try Data(ActivityMemoryMarkdownRenderer.render(memory).utf8)
                .write(to: MarkdownURL, options: .atomic)
            for URL in [JSONURL, MarkdownURL] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: URL.path
                )
            }
            return memory
        }
    }
#endif
