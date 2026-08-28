#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
        case overview
        case activity
        case screenTime
        case agentActivity
        case chatGPTRecap
        case share
        case privacy
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .activity: return "Computer History"
            case .screenTime: return "Apple Screen Time"
            case .agentActivity: return "Agentic work"
            case .chatGPTRecap: return "Activity"
            case .share: return "Share"
            case .privacy: return "Privacy & security"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .activity: return "clock.arrow.circlepath"
            case .screenTime: return "macbook.and.iphone"
            case .agentActivity: return "cpu"
            case .chatGPTRecap: return "chart.bar.xaxis"
            case .share: return "square.and.arrow.up"
            case .privacy: return "hand.raised"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    enum RuntimeStateKind: Equatable {
        case recording
        case paused
        case suppressed(SuppressionReason)
        case permissionsMissing
        case inputTapUnavailable
    }

    struct RuntimePresentation: Equatable {
        let state: RuntimeStateKind
        let accessibilityGranted: Bool
        let inputMonitoringGranted: Bool
        let eventTapRunning: Bool
        let verificationEnabled: Bool
        let verificationServer: String?
        let captureHealth: CaptureHealthAssessment?
        let captureHealthSnapshot: CaptureHealthSnapshot?

        static let unavailable = RuntimePresentation(
            state: .permissionsMissing,
            accessibilityGranted: false,
            inputMonitoringGranted: false,
            eventTapRunning: false,
            verificationEnabled: false,
            verificationServer: nil,
            captureHealth: nil,
            captureHealthSnapshot: nil
        )
    }

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case all
        case work
        case privateOrSuppressed
        case flagged

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .work: return "Work"
            case .privateOrSuppressed: return "Private"
            case .flagged: return "Flagged"
            }
        }
    }

    enum TimelineBucketKind: String {
        case noData
        case sealed
        case active
        case work
        case privateOrSuppressed
        case future
    }

    struct TimelineBucket: Identifiable {
        let start: Date
        let end: Date
        let kind: TimelineBucketKind
        let activeMinutes: Int
        let workMinutes: Int
        let privateMinutes: Int
        let sealedMinutes: Int

        var id: TimeInterval { start.timeIntervalSince1970 }
    }

    struct AppUsage: Identifiable {
        let appName: String
        let bundleIdentifier: String?
        let activeMinutes: Int
        let eventCount: Int

        var id: String { bundleIdentifier ?? "name:\(appName)" }
    }

    struct TrackedUsageItem: Identifiable {
        let id: String
        let kind: TrackedSubjectKind
        let name: String
        let appName: String?
        let bundleIdentifier: String?
        let host: String?
        let category: String?
        let foregroundSeconds: TimeInterval
        let activeMinutes: Int
        let eventCount: Int
        let identityProofAvailable: Bool

        var searchableText: String {
            [name, appName, bundleIdentifier, host, category]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
        }
    }

    struct ActivitySession: Identifiable {
        let id: String
        let start: Date
        let end: Date
        let appName: String
        let bundleIdentifier: String?
        let windowTitle: String?
        let host: String?
        let category: String?
        let isWork: Bool?
        let confidence: Double?
        let suppressionReason: SuppressionReason?
        let eventCount: Int
        let inputEventCount: Int
        let softwareAttributedEventCount: Int
        let kindCounts: [String: Int]
        let latestMessage: String?

        var duration: TimeInterval {
            max(1, end.timeIntervalSince(start) + 30)
        }

        var isFlagged: Bool { softwareAttributedEventCount > 0 }

        var searchableText: String {
            [
                appName,
                bundleIdentifier,
                windowTitle,
                host,
                category,
                suppressionReason?.rawValue,
                latestMessage,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        }
    }

    struct DashboardDaySnapshot {
        let day: Date
        let eventCount: Int
        let activeMinutes: Int
        let workMinutes: Int
        let sealedMinutes: Int
        let liveAnchoredMinutes: Int
        let privateMinutes: Int
        let softwareAttributedEvents: Int
        let sessions: [ActivitySession]
        let appUsage: [AppUsage]
        let trackedUsage: [TrackedUsageItem]
        let timeline: [TimelineBucket]
        let storageBytes: Int64
        let availableDays: [Date]

        static func empty(day: Date = Date()) -> DashboardDaySnapshot {
            DashboardDaySnapshot(
                day: day,
                eventCount: 0,
                activeMinutes: 0,
                workMinutes: 0,
                sealedMinutes: 0,
                liveAnchoredMinutes: 0,
                privateMinutes: 0,
                softwareAttributedEvents: 0,
                sessions: [],
                appUsage: [],
                trackedUsage: [],
                timeline: [],
                storageBytes: 0,
                availableDays: []
            )
        }
    }

    struct ShareSegment: Identifiable {
        let id: String
        let anchorSequences: [UInt64]
        let start: Date
        let end: Date
        let appSummary: String
        let categorySummary: String
        let canRevealDetails: Bool
        var level: ShareLevel

        var minuteCount: Int { anchorSequences.count }
    }

    struct DashboardSettingsDraft: Equatable {
        var captureClicks: Bool
        var captureScroll: Bool
        var captureKeyboardActivity: Bool
        var captureShortcuts: Bool
        var captureWindowTitles: Bool
        var captureElementLabels: Bool
        var captureURLs: Bool
        var redactAllURLQueryValues: Bool
        var retentionDays: Int
        var verificationEnabled: Bool
        var verificationServerURL: String
        var enableAppAttest: Bool
        var excludedDomainsText: String
        var excludedApplicationsText: String
        var includedDomainsText: String
        var includedApplicationsText: String

        init(config: RecorderConfig) {
            captureClicks = config.captureClicks
            captureScroll = config.captureScroll
            captureKeyboardActivity = config.captureKeyboardActivity
            captureShortcuts = config.captureShortcuts
            captureWindowTitles = config.captureWindowTitles
            captureElementLabels = config.captureElementLabels
            captureURLs = config.captureURLs
            redactAllURLQueryValues = config.redactAllURLQueryValues
            retentionDays = config.retentionDays
            verificationEnabled = config.verificationEnabled == true
            verificationServerURL = config.verificationServerURL ?? ""
            enableAppAttest = config.enableAppAttest != false
            excludedDomainsText = config.excludedDomains.joined(separator: "\n")
            excludedApplicationsText = config.excludedBundleIdentifiers.joined(separator: "\n")
            includedDomainsText = (config.includedDomains ?? []).joined(separator: "\n")
            includedApplicationsText = (config.includedBundleIdentifiers ?? []).joined(separator: "\n")
        }

        func applying(to base: RecorderConfig) -> RecorderConfig {
            var output = base
            output.captureClicks = captureClicks
            output.captureScroll = captureScroll
            output.captureKeyboardActivity = captureKeyboardActivity
            output.captureShortcuts = captureShortcuts
            output.captureWindowTitles = captureWindowTitles
            output.captureElementLabels = captureElementLabels
            output.captureURLs = captureURLs
            output.redactAllURLQueryValues = redactAllURLQueryValues
            output.retentionDays = retentionDays
            output.verificationEnabled = verificationEnabled
            output.verificationServerURL = verificationServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            output.enableAppAttest = enableAppAttest
            output.excludedDomains = Self.lines(from: excludedDomainsText).map { $0.lowercased() }
            let includedDomains = Self.lines(from: includedDomainsText).map { $0.lowercased() }
            output.includedDomains = includedDomains.isEmpty ? nil : includedDomains
            let includedApplications = Self.lines(from: includedApplicationsText)
            output.includedBundleIdentifiers = includedApplications.isEmpty ? nil : includedApplications

            var excludedApps = Self.lines(from: excludedApplicationsText)
            if !excludedApps.contains("ai.goalong.localhistory") {
                excludedApps.append("ai.goalong.localhistory")
            }
            output.excludedBundleIdentifiers = excludedApps
            return output.validated()
        }

        private static func lines(from value: String) -> [String] {
            var seen = Set<String>()
            return
                value
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    struct DashboardAlert: Identifiable {
        enum Kind {
            case information
            case error
        }

        let id = UUID()
        let kind: Kind
        let title: String
        let message: String
    }

    extension ShareLevel {
        var dashboardTitle: String {
            switch self {
            case .everything: return "Full details"
            case .applicationOnly: return "Application only"
            case .categoryOnly: return "Category only"
            case .privateOnly: return "Completely private"
            case .mixed: return "Mixed by app or site"
            }
        }

        var dashboardSubtitle: String {
            switch self {
            case .everything:
                return "Application, context, category and activity proofs"
            case .applicationOnly:
                return "Application and time; context stays on this Mac"
            case .categoryOnly:
                return "Verified local category; application stays private"
            case .privateOnly:
                return "Only the existence and coverage of the period"
            case .mixed:
                return "Each event follows its saved app or website rule"
            }
        }

        var dashboardSymbol: String {
            switch self {
            case .everything: return "eye"
            case .applicationOnly: return "app"
            case .categoryOnly: return "tag"
            case .privateOnly: return "eye.slash"
            case .mixed: return "slider.horizontal.3"
            }
        }
    }
#endif
