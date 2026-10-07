#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
        case overview
        case work
        case history
        case monitoring
        case blocking
        case concentration
        case distractions
        case ambiance
        case braise
        case analytics
        case activity
        case screenTime
        case agentActivity
        case chatGPTRecap
        case share
        case privacy
        case cli
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Activité"
            case .analytics: return "Activité"
            case .work: return "Mon travail"
            case .history: return "Historique"
            case .monitoring: return "Surveillance temps réel"
            case .blocking: return "Blocage"
            case .concentration: return "Concentration"
            case .distractions: return "Distractions"
            case .ambiance: return "Ambiance"
            case .braise: return "Braise"
            case .activity: return "Historique de ce Mac"
            case .screenTime: return "Temps d’écran Apple"
            case .agentActivity: return "Conversations IA"
            case .chatGPTRecap: return "Bilan quotidien"
            case .share: return "Partager"
            case .privacy: return "Confidentialité et sécurité"
            case .cli: return "Terminal"
            case .settings: return "Réglages"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "sun.max"
            case .analytics: return "chart.xyaxis.line"
            case .work: return "briefcase"
            case .history: return "clock.arrow.circlepath"
            case .monitoring: return "eye.circle"
            case .blocking: return "lock"
            case .concentration: return "scope"
            case .distractions: return "hand.raised.slash"
            case .ambiance: return "waveform"
            case .braise: return "sun.horizon"
            case .activity: return "clock.arrow.circlepath"
            case .screenTime: return "macbook.and.iphone"
            case .agentActivity: return "cpu"
            case .chatGPTRecap: return "chart.bar.xaxis"
            case .share: return "square.and.arrow.up"
            case .privacy: return "hand.raised"
            case .cli: return "terminal"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    struct DashboardSecondaryReturn: Equatable {
        let section: DashboardSection
        let pane: SettingsPane
    }

    extension DashboardSection {
        /// Pages opened from another page, with a back bar rather than a sidebar entry.
        var isSecondary: Bool {
            switch self {
            case .screenTime, .agentActivity, .chatGPTRecap, .share, .privacy, .cli: return true
            case .overview, .work, .history, .monitoring, .blocking, .concentration, .distractions, .ambiance, .braise, .analytics, .activity, .settings: return false
            }
        }

        /// Used only when a secondary page was opened without a known origin.
        var defaultReturnSection: DashboardSection {
            switch self {
            case .screenTime, .chatGPTRecap: return .overview
            default: return .settings
            }
        }
    }

    enum RuntimeStateKind: Equatable {
        case recording
        case paused
        case suppressed(SuppressionReason)
        case permissionsMissing
        case inputTapUnavailable
        case storageUnavailable(CaptureStorageFailureKind)
    }

    struct RuntimePresentation: Equatable {
        let state: RuntimeStateKind
        let accessibilityGranted: Bool
        let inputMonitoringGranted: Bool
        let eventTapRunning: Bool
        let verificationEnabled: Bool
        let verificationServer: String?
        let captureHealth: CaptureHealthAssessment?

        /// Publishing re-renders every view observing the dashboard model, so equality ignores
        /// the assessment's English diagnostic detail (it counts idle seconds). The live
        /// timestamps panel pulls its own snapshot instead of riding on this value.
        static func == (a: Self, b: Self) -> Bool {
            a.state == b.state && a.accessibilityGranted == b.accessibilityGranted
                && a.inputMonitoringGranted == b.inputMonitoringGranted && a.eventTapRunning == b.eventTapRunning
                && a.verificationEnabled == b.verificationEnabled && a.verificationServer == b.verificationServer
                && a.captureHealth?.state == b.captureHealth?.state
                && a.captureHealth?.captureProven == b.captureHealth?.captureProven
                && a.captureHealth?.limitations == b.captureHealth?.limitations
        }

        static let unavailable = RuntimePresentation(
            state: .permissionsMissing,
            accessibilityGranted: false,
            inputMonitoringGranted: false,
            eventTapRunning: false,
            verificationEnabled: false,
            verificationServer: nil,
            captureHealth: nil
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
            case .all: return "Tout"
            case .work: return "Travail"
            case .privateOrSuppressed: return "Privé"
            case .flagged: return "Signalé"
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
        let sourceApplications: [String]
        let sourceUsage: [DailyWebsiteSourceUsage]
        let bundleIdentifier: String?
        let host: String?
        let category: String?
        let foregroundSeconds: TimeInterval
        let activeMinutes: Int
        let eventCount: Int
        let identityProofAvailable: Bool

        var searchableText: String {
            ([name, appName, bundleIdentifier, host, category]
                .compactMap { $0 }
                + sourceApplications
                + sourceUsage.flatMap {
                    [$0.applicationName, $0.bundleIdentifier].compactMap { $0 }
                })
                .joined(separator: " ")
                .lowercased()
        }

        var sourceApplicationLabel: String? {
            let values = sourceApplications.isEmpty ? [appName].compactMap { $0 } : sourceApplications
            guard !values.isEmpty else { return nil }
            if values.count <= 2 { return values.joined(separator: " + ") }
            return values.prefix(2).joined(separator: " + ") + " +\(values.count - 2)"
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
        var captureCallPresence: Bool
        var capturePrivateBrowsing: Bool
        var redactAllURLQueryValues: Bool
        var foregroundIdleSeconds: Int
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
            captureCallPresence = config.effectiveCaptureCallPresence
            capturePrivateBrowsing = config.capturePrivateBrowsing == true
            redactAllURLQueryValues = config.redactAllURLQueryValues
            foregroundIdleSeconds = config.effectiveForegroundIdleSeconds
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
            output.captureCallPresence = captureCallPresence
            output.capturePrivateBrowsing = capturePrivateBrowsing
            output.redactAllURLQueryValues = redactAllURLQueryValues
            output.foregroundIdleSeconds = foregroundIdleSeconds
            output.retentionDays = retentionDays
            output.verificationEnabled = verificationEnabled
            output.verificationServerURL = verificationServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            output.enableAppAttest = enableAppAttest
            output.excludedDomains = (try? PrivacyScopeInput.domains(excludedDomainsText)) ?? base.excludedDomains
            let includedDomains = (try? PrivacyScopeInput.domains(includedDomainsText)) ?? (base.includedDomains ?? [])
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
            case .everything: return "Tous les détails"
            case .applicationOnly: return "Application uniquement"
            case .categoryOnly: return "Catégorie uniquement"
            case .privateOnly: return "Entièrement privé"
            case .mixed: return "Selon l’app ou le site"
            }
        }

        var dashboardSubtitle: String {
            switch self {
            case .everything:
                return "Application, contexte, catégorie et preuves d’activité"
            case .applicationOnly:
                return "Application et horaires ; le contexte reste sur ce Mac"
            case .categoryOnly:
                return "Catégorie locale vérifiée ; l’application reste privée"
            case .privateOnly:
                return "Seulement l’existence et la couverture de la période"
            case .mixed:
                return "Chaque événement suit la règle enregistrée pour son app ou son site"
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
