#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class LocalActivityMemoryStore {
        private let summarizer: any ActivitySummarizer
        private let rootDirectory: URL
        private let evidenceLoader: (Date, Date) -> ComputerHistoryEvidenceLoad

        init(
            summarizer: any ActivitySummarizer = DeterministicActivitySummarizer(),
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            evidenceLoader: ((Date, Date) -> ComputerHistoryEvidenceLoad)? = nil
        ) {
            self.summarizer = summarizer
            self.rootDirectory = rootDirectory.standardizedFileURL
            self.evidenceLoader =
                evidenceLoader ?? { start, endExclusive in
                    HistoryLocalStoreReader(
                        rootDirectory: rootDirectory
                    ).loadActivityMemoryEvidence(
                        start: start,
                        endExclusive: endExclusive
                    )
                }
        }

        @discardableResult
        func buildAndWrite(for day: Date) throws -> ActivityMemory? {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let loaded = evidenceLoader(start, next)
            if loaded.metrics.wasCancelled {
                throw LoadError.incompleteSourceEvidence(
                    "the bounded source pass was cancelled"
                )
            }
            if loaded.metrics.sourceChangedDuringRead {
                throw LoadError.incompleteSourceEvidence(
                    "a source changed while it was read"
                )
            }
            if loaded.metrics.sourceAccessWasIncomplete {
                throw LoadError.incompleteSourceEvidence(
                    "a source was absent, inaccessible or unsafe"
                )
            }
            if loaded.metrics.evidenceBudgetExceeded {
                throw LoadError.incompleteSourceEvidence(
                    "the 32,768-row or 64 MiB retained-evidence budget was exceeded"
                )
            }
            if let issue = loaded.issues.first {
                throw LoadError.incompleteSourceEvidence(issue.message)
            }
            let evidence = loaded.events.filter(\.isDerivedAnalysisEvidence)
            guard !evidence.isEmpty else { return nil }

            let memory = try summarizer.summarize(
                ActivitySummaryInput(
                    events: evidence,
                    intervalStart: start,
                    intervalEnd: next.addingTimeInterval(-0.001),
                    semanticSnapshots: loaded.semanticSnapshots
                )
            )
            let memoriesDirectory = rootDirectory.appendingPathComponent(
                "memories",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: memoriesDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let base = AppPaths.localDayString(for: start) + ".memory"
            let jsonURL = memoriesDirectory.appendingPathComponent(base + ".json")
            let markdownURL = memoriesDirectory.appendingPathComponent(base + ".md")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try GoalongOwnedAtomicFileWriter.write(encoder.encode(memory), to: jsonURL)
            try GoalongOwnedAtomicFileWriter.write(
                Data(ActivityMemoryMarkdownRenderer.render(memory).utf8),
                to: markdownURL
            )
            for URL in [jsonURL, markdownURL] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: URL.path
                )
            }
            return memory
        }

        enum LoadError: LocalizedError {
            case incompleteSourceEvidence(String)

            var errorDescription: String? {
                switch self {
                case .incompleteSourceEvidence(let reason):
                    return "Refused to replace activity memory from incomplete source evidence: \(reason)."
                }
            }
        }
    }
#endif
