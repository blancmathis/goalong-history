#if os(macOS)
    import AppleScreenTime
    import Foundation
    import LocalHistoryCore

    enum UsageBreakdownMode {
        case websites
        case browsers
    }

    struct UsageBreakdownChild: Identifiable, Equatable {
        enum Kind: Equatable {
            case website
            case remainder
        }

        let id: String
        let kind: Kind
        let name: String
        let host: String?
        let seconds: TimeInterval
    }

    struct UsageBreakdownItem: Identifiable, Equatable {
        enum Kind: Equatable {
            case application
            case website
            case browser
            case otherWeb
            case otherActive
        }

        let id: String
        let kind: Kind
        let name: String
        let bundleIdentifier: String?
        let host: String?
        let seconds: TimeInterval
        let children: [UsageBreakdownChild]

        var searchableText: String {
            ([name, bundleIdentifier, host].compactMap { $0 }
                + children.flatMap { [$0.name, $0.host].compactMap { $0 } })
                .joined(separator: " ")
                .lowercased()
        }
    }

    struct UsageBreakdown: Equatable {
        let totalSeconds: TimeInterval
        let appsAndWebsites: [UsageBreakdownItem]
        let appsAndBrowsers: [UsageBreakdownItem]
        let usesAppleTotal: Bool
        let websiteAttributedSeconds: TimeInterval

        func items(for mode: UsageBreakdownMode) -> [UsageBreakdownItem] {
            switch mode {
            case .websites: return appsAndWebsites
            case .browsers: return appsAndBrowsers
            }
        }
    }

    enum UsageBreakdownProjection {
        static let conciseMinimumDuration: TimeInterval = 5 * 60
        static let conciseMaximumItems = 8
        static let conciseFallbackItems = 3

        private struct ApplicationSeed {
            let id: String
            let name: String
            let bundleIdentifier: String?
            let seconds: TimeInterval
        }

        private struct SourceIdentity {
            let key: String
            let normalizedName: String
        }

        static func build(
            summary: AppleScreenTimeDaySummary?,
            trackedUsage: [TrackedUsageItem],
            includesInactiveSystemTime: Bool = false
        ) -> UsageBreakdown {
            let applications = applicationSeeds(
                summary: summary,
                trackedUsage: trackedUsage,
                includesInactiveSystemTime: includesInactiveSystemTime
            )
            let websites = OverviewUsageProjection.websites(trackedUsage)
            let sourceIdentities = websites.flatMap(sourceUsages).map {
                SourceIdentity(
                    key: applicationKey(
                        name: $0.applicationName,
                        bundleIdentifier: $0.bundleIdentifier
                    ),
                    normalizedName: normalizedName($0.applicationName)
                )
            }
            let sourceKeys = Set(sourceIdentities.map(\.key))
            let sourceNames = Set(sourceIdentities.map(\.normalizedName))

            let browserApplications = applications.filter {
                isBrowser(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    sourceKeys: sourceKeys,
                    sourceNames: sourceNames
                )
            }
            let browserIDs = Set(browserApplications.map(\.id))
            let ordinaryApplications = applications.filter { !browserIDs.contains($0.id) }

            var browserIDBySourceKey: [String: String] = [:]
            var browserIDsByName: [String: [String]] = [:]
            for browser in browserApplications {
                browserIDBySourceKey[browser.id] = browser.id
                browserIDsByName[normalizedName(browser.name), default: []].append(browser.id)
            }
            for source in sourceIdentities where browserIDBySourceKey[source.key] == nil {
                let matches = browserIDsByName[source.normalizedName] ?? []
                if matches.count == 1 { browserIDBySourceKey[source.key] = matches[0] }
            }

            var rawSitesByBrowser: [String: [String: TimeInterval]] = [:]
            for website in websites {
                let host = website.host ?? website.name
                for source in sourceUsages(website) {
                    let sourceKey = applicationKey(
                        name: source.applicationName,
                        bundleIdentifier: source.bundleIdentifier
                    )
                    guard let browserID = browserIDBySourceKey[sourceKey] else { continue }
                    rawSitesByBrowser[browserID, default: [:]][host, default: 0]
                        += source.foregroundSeconds
                }
            }

            var globalSites: [String: TimeInterval] = [:]
            var otherWebSeconds: TimeInterval = 0
            var browserItems: [UsageBreakdownItem] = []
            for browser in browserApplications {
                let rawSites = rawSitesByBrowser[browser.id] ?? [:]
                let rawSiteTotal = rawSites.values.reduce(0, +)
                let scale = rawSiteTotal > browser.seconds && rawSiteTotal > 0
                    ? browser.seconds / rawSiteTotal
                    : 1
                let children = rawSites.map { host, rawSeconds in
                    UsageBreakdownChild(
                        id: "\(browser.id):site:\(host)",
                        kind: .website,
                        name: host,
                        host: host,
                        seconds: rawSeconds * scale
                    )
                }
                .filter { $0.seconds > 0.5 }
                .sorted(by: childSort)
                let attributed = min(browser.seconds, children.reduce(0) { $0 + $1.seconds })
                let remainder = max(0, browser.seconds - attributed)
                for child in children {
                    globalSites[child.name, default: 0] += child.seconds
                }
                otherWebSeconds += remainder

                var completeChildren = children
                if remainder > 0.5 {
                    completeChildren.append(
                        UsageBreakdownChild(
                            id: "\(browser.id):remainder",
                            kind: .remainder,
                            name: "Other or unidentified browsing",
                            host: nil,
                            seconds: remainder
                        )
                    )
                }
                browserItems.append(
                    UsageBreakdownItem(
                        id: browser.id,
                        kind: .browser,
                        name: browser.name,
                        bundleIdentifier: browser.bundleIdentifier,
                        host: nil,
                        seconds: browser.seconds,
                        children: completeChildren
                    )
                )
            }

            let ordinaryItems = ordinaryApplications.map {
                UsageBreakdownItem(
                    id: $0.id,
                    kind: .application,
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    host: nil,
                    seconds: $0.seconds,
                    children: []
                )
            }
            let websiteItems = globalSites.map { host, seconds in
                UsageBreakdownItem(
                    id: "website:\(host)",
                    kind: .website,
                    name: host,
                    bundleIdentifier: nil,
                    host: host,
                    seconds: seconds,
                    children: []
                )
            }

            let applicationTotal = applications.reduce(0) { $0 + $1.seconds }
            let total = summary?.totalScreenOnDuration ?? applicationTotal
            let otherActiveSeconds = max(0, total - applicationTotal)
            var residualItems: [UsageBreakdownItem] = []
            if otherWebSeconds > 0.5 {
                residualItems.append(
                    UsageBreakdownItem(
                        id: "other-web",
                        kind: .otherWeb,
                        name: "Other web activity",
                        bundleIdentifier: nil,
                        host: nil,
                        seconds: otherWebSeconds,
                        children: []
                    )
                )
            }
            if otherActiveSeconds > 0.5 {
                residualItems.append(
                    UsageBreakdownItem(
                        id: "other-active",
                        kind: .otherActive,
                        name: "Other active time",
                        bundleIdentifier: nil,
                        host: nil,
                        seconds: otherActiveSeconds,
                        children: []
                    )
                )
            }

            let mixed = (ordinaryItems + websiteItems + residualItems).sorted(by: itemSort)
            let browserView = (
                ordinaryItems
                    + browserItems
                    + residualItems.filter { $0.kind == .otherActive }
            ).sorted(by: itemSort)
            return UsageBreakdown(
                totalSeconds: total,
                appsAndWebsites: mixed,
                appsAndBrowsers: browserView,
                usesAppleTotal: summary != nil,
                websiteAttributedSeconds: websiteItems.reduce(0) { $0 + $1.seconds }
            )
        }

        static func presentedItems(
            _ items: [UsageBreakdownItem],
            showsAll: Bool
        ) -> [UsageBreakdownItem] {
            let positive = items.filter { $0.seconds > 0.5 }
            guard !showsAll else { return positive }
            let meaningful = positive.filter { $0.seconds >= conciseMinimumDuration }
            if meaningful.isEmpty {
                return Array(positive.prefix(conciseFallbackItems))
            }
            return Array(meaningful.prefix(conciseMaximumItems))
        }

        static func hiddenSeconds(
            totalSeconds: TimeInterval,
            presentedItems: [UsageBreakdownItem]
        ) -> TimeInterval {
            max(0, totalSeconds - presentedItems.reduce(0) { $0 + $1.seconds })
        }

        private static func applicationSeeds(
            summary: AppleScreenTimeDaySummary?,
            trackedUsage: [TrackedUsageItem],
            includesInactiveSystemTime: Bool
        ) -> [ApplicationSeed] {
            if let summary {
                return OverviewUsageProjection.appleApplications(summary).map {
                    ApplicationSeed(
                        id: applicationKey(
                            name: $0.resolvedName,
                            bundleIdentifier: $0.bundleIdentifier
                        ),
                        name: $0.resolvedName,
                        bundleIdentifier: $0.bundleIdentifier,
                        seconds: $0.duration
                    )
                }
            }

            return trackedUsage.compactMap { usage in
                guard usage.kind == .application, usage.foregroundSeconds > 0.5 else {
                    return nil
                }
                if !includesInactiveSystemTime,
                    !AppleScreenTimeUsageFilter.countsTowardDeviceUsage(
                        bundleIdentifier: usage.bundleIdentifier,
                        deviceKind: .mac
                    )
                {
                    return nil
                }
                return ApplicationSeed(
                    id: applicationKey(
                        name: usage.name,
                        bundleIdentifier: usage.bundleIdentifier
                    ),
                    name: usage.name,
                    bundleIdentifier: usage.bundleIdentifier,
                    seconds: usage.foregroundSeconds
                )
            }
            .sorted {
                if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        private static func sourceUsages(
            _ website: TrackedUsageItem
        ) -> [DailyWebsiteSourceUsage] {
            if !website.sourceUsage.isEmpty { return website.sourceUsage }
            guard website.sourceApplications.count == 1,
                let applicationName = website.sourceApplications.first
            else { return [] }
            return [
                DailyWebsiteSourceUsage(
                    applicationName: applicationName,
                    bundleIdentifier: website.bundleIdentifier,
                    foregroundSeconds: website.foregroundSeconds,
                    eventCount: website.eventCount,
                    identityProofAvailable: website.identityProofAvailable
                )
            ]
        }

        private static func isBrowser(
            name: String,
            bundleIdentifier: String?,
            sourceKeys: Set<String>,
            sourceNames: Set<String>
        ) -> Bool {
            let key = applicationKey(name: name, bundleIdentifier: bundleIdentifier)
            if sourceKeys.contains(key) || sourceNames.contains(normalizedName(name)) {
                return true
            }
            if let bundleIdentifier {
                let normalizedBundle = bundleIdentifier.lowercased()
                if knownBrowserBundleIdentifiers.contains(normalizedBundle) { return true }
                if ["browser", "safari", "chrome", "firefox", "brave", "opera", "vivaldi"]
                    .contains(where: normalizedBundle.contains)
                {
                    return true
                }
            }
            let normalized = name.lowercased()
            return browserNameMarkers.contains { normalized.contains($0) }
        }

        private static let knownBrowserBundleIdentifiers = Set(
            RecorderConfig.default.browserBundleIdentifiers.map { $0.lowercased() }
                + ["com.apple.mobilesafari"]
        )

        private static let browserNameMarkers = [
            "safari", "chrome", "chromium", "firefox", "librewolf", "floorp",
            "edge", "brave", "arc", "opera", "vivaldi", "orion", "duckduckgo",
            "zen browser", "dia", "sigmaos", "browser", "aside", "ecosia",
        ]

        private static func applicationKey(
            name: String,
            bundleIdentifier: String?
        ) -> String {
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                return "bundle:\(bundleIdentifier.lowercased())"
            }
            return "name:\(normalizedName(name))"
        }

        private static func normalizedName(_ value: String) -> String {
            value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
        }

        private static func itemSort(
            _ left: UsageBreakdownItem,
            _ right: UsageBreakdownItem
        ) -> Bool {
            if left.seconds != right.seconds { return left.seconds > right.seconds }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        private static func childSort(
            _ left: UsageBreakdownChild,
            _ right: UsageBreakdownChild
        ) -> Bool {
            if left.seconds != right.seconds { return left.seconds > right.seconds }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }
#endif
