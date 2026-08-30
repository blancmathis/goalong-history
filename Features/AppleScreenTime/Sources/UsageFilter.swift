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
