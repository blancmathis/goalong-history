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

        func loadStored(for day: Date) -> ActivityDayAnalysis? {
            let URL = ActivityAnalysisPaths.JSONFile(for: day)
            guard let data = try? Data(contentsOf: URL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ActivityDayAnalysis.self, from: data)
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

    }

    /// Runs alongside the recorder. It never performs network requests and its optional
    /// rich-context payloads stay in a separate local store; only their references go
    /// through EventRecorder and receive an event hash, chain position and minute seal.
    final class ActivityAnalysisPageModel: ObservableObject {
        @Published private(set) var analysis: ActivityDayAnalysis?
        @Published private(set) var isLoading = false
        @Published private(set) var errorMessage: String?

        private let refreshRuntime: ActivityAnalysisRefreshServing
        private let storedAnalysisLoader: (Date) -> ActivityDayAnalysis?
        private var refreshRequestID = UUID()

        init(
            store: ActivityAnalysisStore = ActivityAnalysisStore(),
            refreshRuntime: ActivityAnalysisRefreshServing = ActivityAnalysisRuntime.shared,
            storedAnalysisLoader: ((Date) -> ActivityDayAnalysis?)? = nil
        ) {
            self.refreshRuntime = refreshRuntime
            self.storedAnalysisLoader = storedAnalysisLoader ?? { store.loadStored(for: $0) }
        }

        func refresh(day: Date, forceRebuild: Bool = false) {
            let normalized = Calendar.current.startOfDay(for: day)
            let requestID = UUID()
            refreshRequestID = requestID
            errorMessage = nil
            if !forceRebuild, let stored = storedAnalysisLoader(normalized) {
                analysis = stored
                isLoading = false
                return
            }
            isLoading = true
            refreshRuntime.refresh(day: normalized, force: forceRebuild) { [weak self] result in
                let publish = { [weak self] in
                    guard let self, self.refreshRequestID == requestID else { return }
                    switch result {
                    case .success:
                        self.analysis = self.storedAnalysisLoader(normalized)
                    case let .failure(error):
                        if Self.wasInvalidatedByHistoryClear(error) {
                            self.analysis = nil
                        } else {
                            self.analysis = self.storedAnalysisLoader(normalized)
                        }
                        self.errorMessage = error.localizedDescription
                    }
                    self.isLoading = false
                }
                if Thread.isMainThread {
                    publish()
                } else {
                    DispatchQueue.main.async(execute: publish)
                }
            }
        }

        private static func wasInvalidatedByHistoryClear(_ error: Error) -> Bool {
            guard let refreshError = error as? ActivityAnalysisRefreshError else {
                return false
            }
            switch refreshError {
            case .temporarilySuspended, .invalidatedByHistoryClear:
                return true
            case .runtimeUnavailable:
                return false
            }
        }

        func openAgentBrief(for day: Date) {
            let URL = ActivityAnalysisPaths.agentMarkdownFile(for: day)
            if FileManager.default.fileExists(atPath: URL.path) {
                GoalongWorkspaceOpenPolicy.open(URL, purpose: .localFile)
            } else {
                GoalongWorkspaceOpenPolicy.open(
                    ActivityAnalysisPaths.analysisDirectory,
                    purpose: .localFile
                )
            }
        }

        func revealAnalysisFiles(for day: Date) {
            let files = [
                ActivityAnalysisPaths.agentMarkdownFile(for: day),
                ActivityAnalysisPaths.JSONFile(for: day),
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
            if files.isEmpty {
                GoalongWorkspaceOpenPolicy.open(
                    ActivityAnalysisPaths.analysisDirectory,
                    purpose: .localFile
                )
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        }
    }
#endif
