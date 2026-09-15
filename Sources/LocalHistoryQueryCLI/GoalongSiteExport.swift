import AppleScreenTime
import AppleSystemScreenTime
import Foundation
import LocalHistoryCore

public struct GoalongSiteExportOptions: Codable {
    public var deviceIDs: [String]
    public var includeApplications: Bool
    public var includeHourly: Bool
    public var includeWebsites: Bool
    public var includeRecap: Bool
    public var structuredReport: Bool
    public var maskedApplications: [String]
    public var recapText: String?
    public var recapSectionIndices: [Int]?
    public var rhythmProject: String?
    public var rhythmApplications: [String]
    public var includeRhythmTimeline: Bool
    public var includeRhythmTimes: Bool
    public var includeRhythmContext: Bool
    public var contextualRhythm: GoalongContextualRhythm.Rhythm?
    /// nil preserves legacy CLI behavior. An empty list explicitly discloses no rows.
    public var selectedApplicationIDs: [String]?
    public var selectedWebsiteDomains: [String]?
    public var includeDeviceNames: Bool?
    /// Exact selection: unselected activity must not survive in device totals.
    public var strictSelection: Bool?

    public init(deviceIDs: [String] = [], includeApplications: Bool = false,
                includeHourly: Bool = false, includeWebsites: Bool = false,
                includeRecap: Bool = false, structuredReport: Bool = false,
                maskedApplications: [String] = [], recapText: String? = nil, recapSectionIndices: [Int]? = nil,
                rhythmProject: String? = nil, rhythmApplications: [String] = [],
                includeRhythmTimeline: Bool = false, includeRhythmTimes: Bool = false, includeRhythmContext: Bool = false,
                contextualRhythm: GoalongContextualRhythm.Rhythm? = nil,
                selectedApplicationIDs: [String]? = nil, selectedWebsiteDomains: [String]? = nil,
                includeDeviceNames: Bool? = nil, strictSelection: Bool? = nil) {
        self.deviceIDs = deviceIDs
        self.includeApplications = includeApplications
        self.includeHourly = includeHourly
        self.includeWebsites = includeWebsites
        self.includeRecap = includeRecap
        self.structuredReport = structuredReport
        self.maskedApplications = maskedApplications
        self.recapText = recapText
        self.recapSectionIndices = recapSectionIndices
        self.rhythmProject = rhythmProject
        self.rhythmApplications = rhythmApplications
        self.includeRhythmTimeline = includeRhythmTimeline
        self.includeRhythmTimes = includeRhythmTimes
        self.includeRhythmContext = includeRhythmContext
        self.contextualRhythm = contextualRhythm
        self.selectedApplicationIDs = selectedApplicationIDs
        self.selectedWebsiteDomains = selectedWebsiteDomains
        self.includeDeviceNames = includeDeviceNames
        self.strictSelection = strictSelection
    }
}

public enum GoalongSiteExportError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let message): return message }
    }
}

/// Deliberately emits only the website's public exchange fields. Local proof metadata and
/// transcript/event bodies have no representation here. Source provenance is not verification.
public enum GoalongSiteExport {
    public static func payload(record: AppleSystemScreenTimeDailyArchiveRecord,
                               options: GoalongSiteExportOptions = .init(),
                               websites: [DailyWebsiteUsage]? = nil,
                               recap: String? = nil, now: Date = Date(),
                               privacy: GoalongPrivacyPolicy = .init()) throws -> Data {
        guard !privacy.blocked else { throw GoalongSiteExportError.invalid("Les exclusions sont illisibles. Aucun envoi n’est autorisé.") }
        if privacy.hasExclusions && (options.includeRecap || options.rhythmProject != nil || options.contextualRhythm != nil) {
            throw GoalongSiteExportError.invalid("Les textes et analyses ne peuvent pas être filtrés avec ces exclusions. Envoyez uniquement des données chiffrées.")
        }
        guard let zone = TimeZone(identifier: record.timeZoneIdentifier),
              let stored = record.collection.storedExport else {
            throw GoalongSiteExportError.invalid("The stored Screen Time day has no valid timezone or data.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let interval = calendar.dateInterval(of: .day, for: record.dayStart),
              interval.start == record.dayStart, interval.end == record.dayEnd,
              interval.duration <= 90_000, record.dayStart <= now else {
            throw GoalongSiteExportError.invalid("The stored day boundaries do not match its timezone.")
        }
        try AppleScreenTimeValidator.validate(stored.envelope)
        let reports = stored.envelope.reports.filter {
            $0.device.id != AppleScreenTimeProvenance.appleSettingsAllDevicesReportID
        }
        let available = Set(reports.map { $0.device.id })
        guard Set(options.deviceIDs).count == options.deviceIDs.count,
              Set(options.deviceIDs).isSubset(of: available) else {
            throw GoalongSiteExportError.invalid("A selected device is absent or duplicated. Use goalong screen-time DAY to inspect device IDs.")
        }
        let selected = reports.filter { options.deviceIDs.isEmpty || options.deviceIDs.contains($0.device.id) }
        guard !selected.isEmpty, selected.count <= 12 else {
            throw GoalongSiteExportError.invalid("Select between one and twelve recorded physical devices.")
        }
        let scope = AppleScreenTimeScope(mode: .selectedDevices, selectedDeviceIDs: selected.map { $0.device.id })
        let summary = AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: scope)
        let completed = record.dayEnd <= now
        let provenance: String
        switch stored.envelope.provenance.sourceAssurance {
        case .privateAppleAggregateStore: provenance = "apple-private-aggregate"
        case .reconstructedAppleUsage: provenance = "apple-reconstructed"
        case .publicDeviceActivityExport, .appleSettingsObservablePresentation: provenance = "unknown"
        }
        let sourceReady = [.ready, .localOnly].contains(record.collection.status.kind)
        let coverage = completed && sourceReady && provenance != "apple-reconstructed" ? "complete" : "partial"
        let masks = Set(options.maskedApplications.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let devices: [[String: Any]] = try selected.map { report in
            let item = summary?.deviceSummaries.first { $0.device.id == report.device.id }
            // The analyzer intentionally omits a known zero row; a present zero segment still
            // distinguishes measured zero from a report with no usable segments.
            let hasSegments = report.segments.contains { $0.start < interval.end && $0.end > interval.start }
            let total = try item.map { try seconds($0.screenOnDuration) }
                ?? (hasSegments && report.segments.allSatisfy { $0.totalScreenOnDuration == 0 } ? 0 : nil)
            let allApps = options.includeApplications ? item?.applications ?? [] : []
            let allowedApps = options.selectedApplicationIDs.map(Set.init)
            // Apple totals cannot be safely decomposed into an excluded website's usage.
            // Domain exclusions therefore omit these opaque per-app aggregates as well.
            let apps = allApps.filter {
                (allowedApps?.contains($0.id) ?? true)
                    && !privacy.excludes(appID: $0.bundleIdentifier ?? $0.id, name: $0.resolvedName)
                    && privacy.domains.isEmpty
            }
            let mayIncludeTotal = options.strictSelection != true && !privacy.hasExclusions
            guard apps.count <= 200 else { throw GoalongSiteExportError.invalid("This device exceeds 200 applications; export totals or select fewer details.") }
            var result: [String: Any] = [
                "id": options.includeDeviceNames == false
                    ? "device-" + SHA256Digest.hashHex(Data(report.device.id.utf8))
                    : try text(report.device.id, maximum: 160),
                "name": options.includeDeviceNames == false
                    ? anonymousDeviceName(report.device.kind)
                    : try text(report.device.displayName, maximum: 100),
                "kind": kind(report.device.kind), "source": "apple-screen-time",
                "provenance": provenance, "coverage": total == nil ? "unknown" : coverage,
                // Apple rows do not carry Goalong categories. Mark nonempty breakdowns
                // partial so an unclassified social/work metric cannot become a false zero.
                "appsCoverage": options.includeApplications && total != nil
                    ? (options.selectedApplicationIDs != nil ? "partial" : (apps.isEmpty ? coverage : "partial")) : "unknown",
                "screenSeconds": mayIncludeTotal ? (total as Any? ?? NSNull()) : NSNull(), "hourly": NSNull(),
                "apps": try apps.map { app -> [String: Any] in
                    ["id": try text(app.id, maximum: 160),
                     "name": try text(app.resolvedName, maximum: 100),
                     "seconds": try seconds(app.duration), "category": "other"]
                }
            ]
            if mayIncludeTotal, options.includeHourly, let total {
                result["hourly"] = try hourly(report: report, stored: stored, calendar: calendar,
                                               interval: interval, total: total) as Any? ?? NSNull()
            }
            return result
        }
        var websiteValue: Any = NSNull()
        if options.includeWebsites, masks.isEmpty, let websites {
            let allowedDomains = options.selectedWebsiteDomains.map { Set($0.map { $0.lowercased() }) }
            let websites = websites.filter {
                guard let normalizedHost = GoalongPublicDomain.normalized($0.host),
                      allowedDomains?.contains(normalizedHost) ?? true,
                      !privacy.excludes(domain: $0.host) else { return false }
                guard !privacy.applications.isEmpty else { return true }
                // A mixed or unidentifiable browser origin cannot reintroduce an excluded app.
                guard !$0.sourceUsage.isEmpty else {
                    return $0.sourceApplications.count == 1 && $0.primaryBundleIdentifier != nil
                        && !privacy.excludes(appID: $0.primaryBundleIdentifier, name: $0.sourceApplications.first)
                }
                return !$0.sourceUsage.contains { privacy.excludes(appID: $0.bundleIdentifier, name: $0.applicationName) }
            }
            guard websites.count <= 200 else { throw GoalongSiteExportError.invalid("This day exceeds 200 domains; export without website details.") }
            let rows: [[String: Any]] = try websites.compactMap { website in
                guard let publicHost = GoalongPublicDomain.normalized(website.host) else { return nil }
                return ["domain": publicHost, "browser": "Navigateurs sur ce Mac",
                        "seconds": try seconds(website.foregroundSeconds)]
            }
            // Reading every retained event does not establish full-day recording coverage.
            websiteValue = ["source": "goalong-computer-history", "coverage": "partial",
                            "includedInApplicationTotals": true, "rows": rows]
        }
        let summaryText = options.includeRecap && masks.isEmpty ? options.recapText ?? recap ?? "" : ""
        guard summaryText.utf16.count <= 3000 else {
            throw GoalongSiteExportError.invalid("The saved recap exceeds the 3000-character site limit; prepare a shorter explicit analysis or omit --include-recap.")
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: record.dayStart)
        let payload: [String: Any] = ["version": 2, "source": "goalong-history", "days": [[
            "date": day, "title": "Activité du \(day)", "summary": summaryText,
            "outcomes": [], "activities": [], "telemetry": [
                "timezone": zone.identifier, "receivedAt": ISO8601DateFormatter().string(from: record.storedAt),
                "state": completed ? "completed" : "in-progress", "devices": devices.map { device in
                    var output = device
                    let rows = device["apps"] as? [[String: Any]] ?? []
                    let visible = rows.enumerated().map { index, app -> [String: Any] in
                        let hide = [app["name"] as? String, app["id"] as? String].compactMap { $0?.lowercased() }.contains { masks.contains($0) }
                        return hide ? ["id": "masked-application-\(index)", "name": "Activité masquée", "seconds": app["seconds"] ?? 0, "category": "other"] : app
                    }
                    output["apps"] = visible
                    return output
                },
                "websites": websiteValue, "agent": NSNull()
            ]
        ]]]
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        if options.structuredReport { return try GoalongProductivityExport.payload(fromSelectedSiteExport: data) }
        guard data.count <= 2 * 1024 * 1024 else { throw GoalongSiteExportError.invalid("The website export exceeds 2 MiB.") }
        data.append(0x0A)
        return data
    }

    private static func seconds(_ value: Double) throws -> Int {
        guard value.isFinite, value >= 0, value <= 90_000 else {
            throw GoalongSiteExportError.invalid("An activity duration is outside the supported calendar-day range.")
        }
        return Int(value.rounded())
    }

    private static func text(_ value: String, maximum: Int) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.utf16.count <= maximum else {
            throw GoalongSiteExportError.invalid("An activity label exceeds the website exchange limit.")
        }
        return result
    }

    private static func anonymousDeviceName(_ value: AppleScreenTimeDeviceKind) -> String {
        switch value {
        case .mac: return "Ordinateur"
        case .iPhone, .iPod: return "Téléphone"
        case .iPad: return "Tablette"
        case .appleWatch: return "Montre"
        default: return "Appareil"
        }
    }

    private static func kind(_ value: AppleScreenTimeDeviceKind) -> String {
        switch value {
        case .mac: return "computer"
        case .iPhone, .iPod: return "phone"
        case .iPad: return "tablet"
        case .appleWatch: return "watch"
        default: return "other"
        }
    }

    private static func hourly(report: AppleScreenTimeDeviceReport, stored: AppleScreenTimeStoredExport,
                               calendar: Calendar, interval: DateInterval, total: Int) throws -> [Any]? {
        let filtered: [AppleScreenTimeDeviceReport]
        if stored.envelope.provenance.usesScreenTimeAgentAggregateStore {
            filtered = AppleScreenTimeUsageFilter.removingSystemApplicationsPreservingTotals(from: [report])
        } else if stored.envelope.provenance.usesAppleSettingsObservablePresentation {
            filtered = [report]
        } else {
            filtered = AppleScreenTimeUsageFilter.removingSystemInactivity(from: [report])
        }
        guard let source = filtered.first, !source.segments.isEmpty else { return nil }
        var values = [Double?](repeating: nil, count: 24)
        var previousEnd = interval.start
        for segment in source.segments {
            guard let hour = calendar.dateInterval(of: .hour, for: segment.start),
                  segment.start == hour.start, segment.end == hour.end,
                  segment.start >= interval.start, segment.end <= interval.end,
                  segment.start >= previousEnd else { return nil }
            previousEnd = segment.end
            let index = calendar.component(.hour, from: segment.start)
            values[index] = (values[index] ?? 0) + segment.totalScreenOnDuration
        }
        var rounded = try values.map { try $0.map(seconds) }
        // Individual rounding may differ from the source's once-rounded daily total. Keep
        // a tiny rounding remainder in a measured hour, never fabricate another hour.
        let remainder = total - rounded.compactMap { $0 }.reduce(0, +)
        guard abs(remainder) <= 24 else { return nil }
        if remainder != 0 {
            guard let index = rounded.indices.first(where: {
                rounded[$0] != nil && rounded[$0]! + remainder >= 0 && rounded[$0]! + remainder <= 7200
            }) else { return nil }
            rounded[index]! += remainder
        }
        guard rounded.compactMap({ $0 }).allSatisfy({ $0 <= 7200 }) else { return nil }
        return rounded.map { $0 as Any? ?? NSNull() }
    }
}
