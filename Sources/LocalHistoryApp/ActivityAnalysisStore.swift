#if os(macOS)
    import AppKit
    import ApplicationServices
    import Combine
    import Foundation
    import LocalHistoryCore

    enum ActivityAnalysisPreferences {
        static let richContextEnabledKey = "activityAnalysis.richContextEnabled"
        static let richContextIntervalKey = "activityAnalysis.richContextIntervalSeconds"
        static let agentTokenBudgetKey = "activityAnalysis.agentTokenBudget"

        static var richContextEnabled: Bool {
            UserDefaults.standard.bool(forKey: richContextEnabledKey)
        }

        static var richContextIntervalSeconds: TimeInterval {
            let raw = UserDefaults.standard.integer(forKey: richContextIntervalKey)
            return TimeInterval(raw == 0 ? 15 : min(max(raw, 8), 120))
        }

        static var agentTokenBudget: Int {
            let raw = UserDefaults.standard.integer(forKey: agentTokenBudgetKey)
            return raw == 0 ? 1_600 : min(max(raw, 400), 12_000)
        }
    }

    enum ActivityAnalysisPaths {
        static let applicationSupportDirectory: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("LocalHistory", isDirectory: true)
        }()

        static let eventsDirectory = applicationSupportDirectory.appendingPathComponent("events", isDirectory: true)
        static let analysisDirectory = applicationSupportDirectory.appendingPathComponent("analysis", isDirectory: true)

        static func prepare() throws {
            try FileManager.default.createDirectory(
                at: analysisDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: analysisDirectory.path)
        }

        static func eventFile(for day: Date) -> URL {
            eventsDirectory.appendingPathComponent(dayString(day) + ".jsonl")
        }

        static func JSONFile(for day: Date) -> URL {
            analysisDirectory.appendingPathComponent(dayString(day) + ".analysis.json")
        }

        static func agentMarkdownFile(for day: Date) -> URL {
            analysisDirectory.appendingPathComponent(dayString(day) + ".agent.md")
        }

        static func dayString(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }

    final class ActivityAnalysisStore {
        private let fileManager = FileManager.default

        func buildAndWrite(for day: Date) throws -> ActivityDayAnalysis {
            let events = loadEvents(for: day)
            let options = ActivityAnalysisOptions(agentTokenBudget: ActivityAnalysisPreferences.agentTokenBudget)
            let analysis = ActivityAnalysisEngine.analyze(events: events, day: day, options: options)
            try write(analysis, for: day)
            return analysis
        }

        func loadStored(for day: Date) -> ActivityDayAnalysis? {
            let URL = ActivityAnalysisPaths.JSONFile(for: day)
            guard let data = try? Data(contentsOf: URL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ActivityDayAnalysis.self, from: data)
        }

        func eventModificationDate(for day: Date) -> Date? {
            let URL = ActivityAnalysisPaths.eventFile(for: day)
            return try? URL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        func removeAnalysis(for day: Date) {
            for URL in [
                ActivityAnalysisPaths.JSONFile(for: day),
                ActivityAnalysisPaths.agentMarkdownFile(for: day),
            ] {
                try? fileManager.removeItem(at: URL)
            }
        }

        func removeOrphanedAnalyses() {
            guard
                let files = try? fileManager.contentsOfDirectory(
                    at: ActivityAnalysisPaths.analysisDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { return }

            for file in files {
                let name = file.lastPathComponent
                guard let range = name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
                    continue
                }
                let dayName = String(name[range])
                let eventFile = ActivityAnalysisPaths.eventsDirectory
                    .appendingPathComponent(dayName + ".jsonl")
                if !fileManager.fileExists(atPath: eventFile.path) {
                    try? fileManager.removeItem(at: file)
                }
            }
        }

        private func loadEvents(for day: Date) -> [HistoryEvent] {
            let start = Calendar.current.startOfDay(for: day)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: start) else {
                return []
            }
            let loaded = HistoryLocalStoreReader(
                rootDirectory: AppPaths.applicationSupportDirectory
            ).load(start: start, end: next.addingTimeInterval(-0.001))
            for issue in loaded.issues {
                Diagnostics.write("Activity analysis load gap: \(issue.path):\(issue.line.map(String.init) ?? "-") \(issue.message)")
            }
            return loaded.events.map { event in
                guard let semantic = SemanticContextResolver.text(
                    for: event,
                    semanticSnapshots: loaded.semanticSnapshots
                ) else { return event }
                var metadata = event.metadata ?? [:]
                metadata[ActivitySemanticMetadata.text] = semantic
                return HistoryEvent(
                    schemaVersion: event.schemaVersion,
                    id: event.id,
                    sessionID: event.sessionID,
                    timestamp: event.timestamp,
                    kind: event.kind,
                    app: event.app,
                    window: event.window,
                    element: event.element,
                    url: event.url,
                    pointer: event.pointer,
                    keyboard: event.keyboard,
                    scroll: event.scroll,
                    inputOrigin: event.inputOrigin,
                    semanticContext: event.semanticContext,
                    classification: event.classification,
                    suppressionReason: event.suppressionReason,
                    message: event.message,
                    metadata: metadata,
                    integrity: event.integrity
                )
            }
        }

        private func write(_ analysis: ActivityDayAnalysis, for day: Date) throws {
            try ActivityAnalysisPaths.prepare()

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let JSONData = try encoder.encode(analysis)
            let JSONURL = ActivityAnalysisPaths.JSONFile(for: day)
            try JSONData.write(to: JSONURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: JSONURL.path)

            let markdownURL = ActivityAnalysisPaths.agentMarkdownFile(for: day)
            try analysis.agentMarkdown.write(to: markdownURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markdownURL.path)
        }
    }

    /// Runs alongside the recorder. It never performs network requests and its optional
    /// rich-context payloads stay in a separate local store; only their references go
    /// through EventRecorder and receive an event hash, chain position and minute seal.
    final class ActivityAnalysisPageModel: ObservableObject {
        @Published private(set) var analysis: ActivityDayAnalysis?
        @Published private(set) var isLoading = false
        @Published private(set) var errorMessage: String?

        private let store = ActivityAnalysisStore()
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.analysis-page",
            qos: .userInitiated
        )
        private var requestedDay: Date?

        func refresh(day: Date) {
            let normalized = Calendar.current.startOfDay(for: day)
            requestedDay = normalized
            isLoading = true
            errorMessage = nil
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let next = try self.store.buildAndWrite(for: normalized)
                    DispatchQueue.main.async {
                        guard self.requestedDay == normalized else { return }
                        self.analysis = next
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.requestedDay == normalized else { return }
                        self.analysis = self.store.loadStored(for: normalized)
                        self.errorMessage = String(describing: error)
                        self.isLoading = false
                    }
                }
            }
        }

        func openAgentBrief(for day: Date) {
            let URL = ActivityAnalysisPaths.agentMarkdownFile(for: day)
            if FileManager.default.fileExists(atPath: URL.path) {
                NSWorkspace.shared.open(URL)
            } else {
                NSWorkspace.shared.open(ActivityAnalysisPaths.analysisDirectory)
            }
        }

        func revealAnalysisFiles(for day: Date) {
            let files = [
                ActivityAnalysisPaths.agentMarkdownFile(for: day),
                ActivityAnalysisPaths.JSONFile(for: day),
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
            if files.isEmpty {
                NSWorkspace.shared.open(ActivityAnalysisPaths.analysisDirectory)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        }
    }
#endif
