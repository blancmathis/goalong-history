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

        static var agentTokenBudget: Int { agentTokenBudget(in: .standard) }

        static func agentTokenBudget(in defaults: UserDefaults) -> Int {
            let raw = defaults.integer(forKey: agentTokenBudgetKey)
            return raw == 0 ? 1_600 : min(max(raw, 400), 12_000)
        }
    }

    enum ActivityAnalysisPaths {
        static let applicationSupportDirectory: URL = GoalongBuildChannel.dataRoot

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
#endif
