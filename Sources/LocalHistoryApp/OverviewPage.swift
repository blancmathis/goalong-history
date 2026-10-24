#if os(macOS)
    import AppleScreenTime
    import Foundation
    import SwiftUI

    struct DailyAppUsage: Identifiable, Equatable {
        let id: String
        var name: String
        var bundleIdentifier: String?
        var appleCurrentMacSeconds: TimeInterval
        var appleOtherDeviceSeconds: TimeInterval
        var goalongSeconds: TimeInterval

        var screenTimeSeconds: TimeInterval {
            appleCurrentMacSeconds + appleOtherDeviceSeconds
        }

        var displaySeconds: TimeInterval {
            screenTimeSeconds > 0 ? screenTimeSeconds : goalongSeconds
        }

        var sourceDetail: String {
            if screenTimeSeconds > 0, goalongSeconds > 0 {
                return "Temps d’écran Apple · Goalong a observé \(DashboardFormatters.duration(seconds: goalongSeconds)) sur ce Mac"
            }
            if screenTimeSeconds > 0 { return "Apple Screen Time" }
            return "Goalong observed foreground on this Mac"
        }
    }

    enum OverviewUsageProjection {
        static let conciseMinimumDuration: TimeInterval = 5 * 60
        static let conciseMaximumItems = 6

        static func durationLabel(seconds: TimeInterval) -> String {
            DashboardFormatters.duration(seconds: seconds)
        }

        static func summary(
            filtered: AppleScreenTimeDaySummary?,
            allReported: AppleScreenTimeDaySummary?,
            includesInactiveSystemTime: Bool
        ) -> AppleScreenTimeDaySummary? {
            includesInactiveSystemTime ? (allReported ?? filtered) : filtered
        }

        static func hasHiddenInactiveSystemTime(
            filtered: AppleScreenTimeDaySummary?,
            allReported: AppleScreenTimeDaySummary?
        ) -> Bool {
            guard let allReported else { return false }
            let filteredDuration = filtered?.totalScreenOnDuration ?? 0
            if allReported.totalScreenOnDuration > filteredDuration + 0.5 { return true }

            let filteredIDs = Set(
                filtered?.deviceSummaries.flatMap(\.applications).map(\.id) ?? []
            )
            return allReported.deviceSummaries
                .flatMap(\.applications)
                .contains { !filteredIDs.contains($0.id) }
        }

        static func applications(
            filteredSummary: AppleScreenTimeDaySummary?,
            allReportedSummary: AppleScreenTimeDaySummary?,
            goalongUsage: [TrackedUsageItem],
            currentMacDeviceID: String,
            includesInactiveSystemTime: Bool
        ) -> [DailyAppUsage] {
            let selectedSummary = summary(
                filtered: filteredSummary,
                allReported: allReportedSummary,
                includesInactiveSystemTime: includesInactiveSystemTime
            )
            let hasAppleSummary = selectedSummary != nil
            var merged: [String: DailyAppUsage] = [:]

            for deviceSummary in selectedSummary?.deviceSummaries ?? [] {
                for application in deviceSummary.applications {
                    let key = appKey(
                        name: application.resolvedName,
                        bundleIdentifier: application.bundleIdentifier
                    )
                    let isCurrentMac = deviceSummary.device.id == currentMacDeviceID
                    if var existing = merged[key] {
                        if isCurrentMac {
                            existing.appleCurrentMacSeconds += application.duration
                        } else {
                            existing.appleOtherDeviceSeconds += application.duration
                        }
                        merged[key] = existing
                    } else {
                        merged[key] = DailyAppUsage(
                            id: key,
                            name: application.resolvedName,
                            bundleIdentifier: application.bundleIdentifier,
                            appleCurrentMacSeconds: isCurrentMac ? application.duration : 0,
                            appleOtherDeviceSeconds: isCurrentMac ? 0 : application.duration,
                            goalongSeconds: 0
                        )
                    }
                }
            }

            for application in goalongUsage where application.kind == .application {
                if !includesInactiveSystemTime,
                   !AppleScreenTimeUsageFilter.countsTowardDeviceUsage(
                       bundleIdentifier: application.bundleIdentifier,
                       deviceKind: .mac
                   )
                {
                    continue
                }
                let key = appKey(
                    name: application.name,
                    bundleIdentifier: application.bundleIdentifier
                )
                if var existing = merged[key] {
                    existing.goalongSeconds = max(
                        existing.goalongSeconds,
                        application.foregroundSeconds
                    )
                    if existing.bundleIdentifier == nil {
                        existing.bundleIdentifier = application.bundleIdentifier
                    }
                    if existing.name == (existing.bundleIdentifier ?? "") {
                        existing.name = application.name
                    }
                    merged[key] = existing
                } else if !hasAppleSummary {
                    merged[key] = DailyAppUsage(
                        id: key,
                        name: application.name,
                        bundleIdentifier: application.bundleIdentifier,
                        appleCurrentMacSeconds: 0,
                        appleOtherDeviceSeconds: 0,
                        goalongSeconds: application.foregroundSeconds
                    )
                }
            }

            return merged.values
                .filter { $0.displaySeconds > 0.5 }
                .sorted { lhs, rhs in
                    if lhs.displaySeconds != rhs.displaySeconds {
                        return lhs.displaySeconds > rhs.displaySeconds
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }

        static func websites(_ trackedUsage: [TrackedUsageItem]) -> [TrackedUsageItem] {
            trackedUsage
                .filter {
                    $0.kind == .website
                        && $0.foregroundSeconds > 0
                        && SharingSubjectKey.displayableWebsiteHost($0.host ?? $0.name) != nil
                }
                .sorted { lhs, rhs in
                    if lhs.foregroundSeconds != rhs.foregroundSeconds {
                        return lhs.foregroundSeconds > rhs.foregroundSeconds
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }

        static func appleApplications(
            _ summary: AppleScreenTimeDaySummary?
        ) -> [AppleScreenTimeApplicationUsage] {
            var merged: [String: AppleScreenTimeApplicationUsage] = [:]
            for application in summary?.deviceSummaries.flatMap(\.applications) ?? [] {
                if let existing = merged[application.id] {
                    merged[application.id] = AppleScreenTimeApplicationUsage(
                        bundleIdentifier: existing.bundleIdentifier ?? application.bundleIdentifier,
                        displayName: existing.displayName ?? application.displayName,
                        duration: existing.duration + application.duration
                    )
                } else {
                    merged[application.id] = application
                }
            }
            return merged.values
                .filter { $0.duration > 0.5 }
                .sorted { lhs, rhs in
                    if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
                    return lhs.resolvedName.localizedCaseInsensitiveCompare(rhs.resolvedName)
                        == .orderedAscending
                }
        }

        static func presentedApplications(
            _ applications: [DailyAppUsage],
            showsAll: Bool
        ) -> [DailyAppUsage] {
            presentedValues(
                applications,
                showsAll: showsAll,
                duration: \DailyAppUsage.displaySeconds
            )
        }

        static func presentedWebsites(
            _ websites: [TrackedUsageItem],
            showsAll: Bool
        ) -> [TrackedUsageItem] {
            presentedValues(
                websites,
                showsAll: showsAll,
                duration: \TrackedUsageItem.foregroundSeconds
            )
        }

        static func presentedAppleApplications(
            _ applications: [AppleScreenTimeApplicationUsage],
            showsAll: Bool
        ) -> [AppleScreenTimeApplicationUsage] {
            presentedValues(
                applications,
                showsAll: showsAll,
                duration: \AppleScreenTimeApplicationUsage.duration
            )
        }

        private static func presentedValues<Value>(
            _ values: [Value],
            showsAll: Bool,
            duration: KeyPath<Value, TimeInterval>
        ) -> [Value] {
            let positive = values.filter { $0[keyPath: duration] > 0.5 }
            guard !showsAll else { return positive }
            return Array(
                positive
                    .filter { $0[keyPath: duration] >= conciseMinimumDuration }
                    .prefix(conciseMaximumItems)
            )
        }

        private static func appKey(name: String, bundleIdentifier: String?) -> String {
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                return "bundle:\(bundleIdentifier.lowercased())"
            }
            let normalized = name
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            return "name:\(normalized)"
        }
    }
#endif
