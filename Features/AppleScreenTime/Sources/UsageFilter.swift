import Foundation

/// Removes explicit operating-system surfaces that represent a locked or unattended display,
/// not application use. Exact bundle identifiers and device kinds keep the boundary conservative.
public enum AppleScreenTimeUsageFilter {
    public static func countsTowardDeviceUsage(
        bundleIdentifier: String?,
        deviceKind: AppleScreenTimeDeviceKind
    ) -> Bool {
        guard let identifier = normalized(bundleIdentifier) else { return true }

        switch deviceKind {
        case .mac:
            return identifier != "com.apple.loginwindow"
                && !identifier.hasPrefix("com.apple.screensaver.")
        case .iPhone, .iPad, .iPod:
            return identifier != "com.apple.sleeplockscreen"
                && identifier != "com.apple.incallservice"
        case .appleWatch, .appleTV, .homePod, .visionPro, .unknown:
            return true
        }
    }

    public static func removingSystemInactivity(
        from reports: [AppleScreenTimeDeviceReport]
    ) -> [AppleScreenTimeDeviceReport] {
        reports.compactMap { report in
            let segments = report.segments.compactMap {
                removingSystemInactivity(from: $0, deviceKind: report.device.kind)
            }
            guard !segments.isEmpty else { return nil }
            return AppleScreenTimeDeviceReport(
                device: report.device,
                lastUpdatedAt: report.lastUpdatedAt,
                segments: segments
            )
        }
    }

    /// Removes explicit inactive-system application rows while preserving Apple-provided
    /// aggregate screen-on totals byte-for-byte. ScreenTimeAgent has already decided the total;
    /// subtracting a timed item here would turn an exact Apple value back into a reconstruction.
    public static func removingSystemApplicationsPreservingTotals(
        from reports: [AppleScreenTimeDeviceReport]
    ) -> [AppleScreenTimeDeviceReport] {
        reports.map { report in
            AppleScreenTimeDeviceReport(
                device: report.device,
                lastUpdatedAt: report.lastUpdatedAt,
                segments: report.segments.map { segment in
                    AppleScreenTimeSegment(
                        start: segment.start,
                        end: segment.end,
                        totalScreenOnDuration: segment.totalScreenOnDuration,
                        longestActivityStart: segment.longestActivityStart,
                        longestActivityEnd: segment.longestActivityEnd,
                        applications: segment.applications.filter {
                            countsTowardDeviceUsage(
                                bundleIdentifier: $0.bundleIdentifier,
                                deviceKind: report.device.kind
                            )
                        }
                    )
                }
            )
        }
    }

    private static func removingSystemInactivity(
        from segment: AppleScreenTimeSegment,
        deviceKind: AppleScreenTimeDeviceKind
    ) -> AppleScreenTimeSegment? {
        let excluded = segment.applications.filter {
            !countsTowardDeviceUsage(
                bundleIdentifier: $0.bundleIdentifier,
                deviceKind: deviceKind
            )
        }
        guard !excluded.isEmpty else { return segment }

        let applications = segment.applications.filter {
            countsTowardDeviceUsage(
                bundleIdentifier: $0.bundleIdentifier,
                deviceKind: deviceKind
            )
        }
        let excludedDuration = min(
            segment.totalScreenOnDuration,
            excluded.reduce(0) { $0 + $1.duration }
        )
        let attributedActiveDuration = min(
            segment.totalScreenOnDuration,
            applications.reduce(0) { $0 + $1.duration }
        )
        let activeDuration = max(
            attributedActiveDuration,
            segment.totalScreenOnDuration - excludedDuration
        )
        guard activeDuration > 0 || !applications.isEmpty else { return nil }

        return AppleScreenTimeSegment(
            start: segment.start,
            end: segment.end,
            totalScreenOnDuration: activeDuration,
            longestActivityStart: segment.longestActivityStart,
            longestActivityEnd: segment.longestActivityEnd,
            applications: applications
        )
    }

    private static func normalized(_ bundleIdentifier: String?) -> String? {
        guard let value = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty
        else { return nil }
        return value
    }
}
