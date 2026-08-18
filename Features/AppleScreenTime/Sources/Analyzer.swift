import Foundation

public enum AppleScreenTimeValidationError: Error, CustomStringConvertible, Equatable {
    case unsupportedSchema(Int)
    case invalidRequestedInterval
    case excessiveRequestedInterval
    case tooManyDevices
    case duplicateDeviceID(String)
    case tooManySegments(String)
    case invalidSegment(String)
    case tooManyApplications(String)
    case invalidApplicationDuration(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported Apple Screen Time schema version: \(version)."
        case .invalidRequestedInterval:
            return "The requested Screen Time interval is invalid."
        case .excessiveRequestedInterval:
            return "The Screen Time export covers an unexpectedly large interval."
        case .tooManyDevices:
            return "The Screen Time export contains too many devices."
        case .duplicateDeviceID(let id):
            return "The Screen Time export repeats device identifier \(id)."
        case .tooManySegments(let id):
            return "Device \(id) contains too many activity segments."
        case .invalidSegment(let id):
            return "Device \(id) contains an invalid activity segment."
        case .tooManyApplications(let id):
            return "Device \(id) contains too many application rows."
        case .invalidApplicationDuration(let id):
            return "Device \(id) contains an invalid application duration."
        }
    }
}

public enum AppleScreenTimeValidator {
    public static func validate(_ envelope: AppleScreenTimeExportEnvelope) throws {
        guard envelope.schemaVersion == 1 else {
            throw AppleScreenTimeValidationError.unsupportedSchema(envelope.schemaVersion)
        }
        guard envelope.requestedEnd > envelope.requestedStart else {
            throw AppleScreenTimeValidationError.invalidRequestedInterval
        }
        guard envelope.requestedEnd.timeIntervalSince(envelope.requestedStart) <= 366 * 86_400 else {
            throw AppleScreenTimeValidationError.excessiveRequestedInterval
        }
        guard envelope.reports.count <= 32 else {
            throw AppleScreenTimeValidationError.tooManyDevices
        }

        var deviceIDs = Set<String>()
        for report in envelope.reports {
            let deviceID = report.device.id
            guard !deviceID.isEmpty, deviceIDs.insert(deviceID).inserted else {
                throw AppleScreenTimeValidationError.duplicateDeviceID(deviceID)
            }
            guard report.segments.count <= 10_000 else {
                throw AppleScreenTimeValidationError.tooManySegments(deviceID)
            }

            var applicationRows = 0
            for segment in report.segments {
                let intervalDuration = segment.end.timeIntervalSince(segment.start)
                guard intervalDuration > 0,
                      intervalDuration.isFinite,
                      segment.totalScreenOnDuration.isFinite,
                      segment.totalScreenOnDuration >= 0,
                      segment.totalScreenOnDuration <= intervalDuration + 1
                else {
                    throw AppleScreenTimeValidationError.invalidSegment(deviceID)
                }

                applicationRows += segment.applications.count
                guard applicationRows <= 100_000 else {
                    throw AppleScreenTimeValidationError.tooManyApplications(deviceID)
                }
                for application in segment.applications {
                    guard application.duration.isFinite,
                          application.duration >= 0,
                          application.duration <= intervalDuration + 1
                    else {
                        throw AppleScreenTimeValidationError.invalidApplicationDuration(deviceID)
                    }
                }
            }
        }
    }
}

public enum AppleScreenTimeAnalyzer {
    public static func summary(
        from storedExport: AppleScreenTimeStoredExport,
        interval: DateInterval,
        scope: AppleScreenTimeScope
    ) -> AppleScreenTimeDaySummary? {
        guard interval.duration > 0 else { return nil }

        let availableDevices = storedExport.envelope.reports.map(\.device)
        let normalizedScope = scope.normalized(availableDevices: availableDevices)
        let reports = storedExport.envelope.reports.filter { normalizedScope.includes($0.device) }

        var deviceSummaries: [AppleScreenTimeDeviceSummary] = []
        var applicationTotals: [String: AppleScreenTimeApplicationUsage] = [:]

        for report in reports {
            var deviceTotal: TimeInterval = 0
            var deviceApplications: [String: AppleScreenTimeApplicationUsage] = [:]

            for segment in report.segments {
                guard let overlap = overlap(of: segment.interval, with: interval) else { continue }
                let ratio = min(1, max(0, overlap.duration / max(0.001, segment.interval.duration)))
                deviceTotal += segment.totalScreenOnDuration * ratio

                for application in segment.applications {
                    let duration = application.duration * ratio
                    merge(application: application, duration: duration, into: &deviceApplications)
                    merge(application: application, duration: duration, into: &applicationTotals)
                }
            }

            guard deviceTotal > 0 || !deviceApplications.isEmpty else { continue }
            deviceSummaries.append(
                AppleScreenTimeDeviceSummary(
                    device: report.device,
                    screenOnDuration: deviceTotal,
                    lastUpdatedAt: report.lastUpdatedAt,
                    applications: sortedApplications(deviceApplications)
                )
            )
        }

        deviceSummaries.sort {
            if $0.screenOnDuration != $1.screenOnDuration {
                return $0.screenOnDuration > $1.screenOnDuration
            }
            return $0.device.displayName.localizedCaseInsensitiveCompare($1.device.displayName) == .orderedAscending
        }

        let total = deviceSummaries.reduce(0) { $0 + $1.screenOnDuration }
        let latestUpdate = deviceSummaries.map(\.lastUpdatedAt).max()

        return AppleScreenTimeDaySummary(
            start: interval.start,
            end: interval.end,
            scope: normalizedScope,
            verification: storedExport.verification,
            provenance: storedExport.envelope.provenance,
            totalScreenOnDuration: total,
            deviceSummaries: deviceSummaries,
            topApplications: Array(sortedApplications(applicationTotals).prefix(20)),
            latestDataUpdate: latestUpdate
        )
    }

    public static func sharePayload(
        from summary: AppleScreenTimeDaySummary,
        disclosureLevel: AppleScreenTimeShareLevel
    ) -> AppleScreenTimeSharePayload {
        let sharedDevices: [AppleScreenTimeShareDevice]?
        switch disclosureLevel {
        case .totalsOnly:
            sharedDevices = nil
        case .perDevice:
            sharedDevices = summary.deviceSummaries.map {
                AppleScreenTimeShareDevice(
                    device: $0.device,
                    screenOnDuration: $0.screenOnDuration,
                    applications: nil
                )
            }
        case .applications:
            sharedDevices = summary.deviceSummaries.map {
                AppleScreenTimeShareDevice(
                    device: $0.device,
                    screenOnDuration: $0.screenOnDuration,
                    applications: $0.applications
                )
            }
        }

        return AppleScreenTimeSharePayload(
            start: summary.start,
            end: summary.end,
            requestedScope: summary.scope,
            includedDeviceCount: summary.deviceSummaries.count,
            totalScreenOnDuration: summary.totalScreenOnDuration,
            disclosureLevel: disclosureLevel,
            devices: sharedDevices,
            provenance: summary.provenance,
            importVerification: summary.verification,
            trustNotice: trustNotice(for: summary.verification)
        )
    }

    private static func overlap(of lhs: DateInterval, with rhs: DateInterval) -> DateInterval? {
        let start = max(lhs.start, rhs.start)
        let end = min(lhs.end, rhs.end)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func merge(
        application: AppleScreenTimeApplicationUsage,
        duration: TimeInterval,
        into totals: inout [String: AppleScreenTimeApplicationUsage]
    ) {
        let key = application.id
        let existing = totals[key]
        totals[key] = AppleScreenTimeApplicationUsage(
            bundleIdentifier: existing?.bundleIdentifier ?? application.bundleIdentifier,
            displayName: existing?.displayName ?? application.displayName,
            duration: (existing?.duration ?? 0) + duration
        )
    }

    private static func sortedApplications(
        _ values: [String: AppleScreenTimeApplicationUsage]
    ) -> [AppleScreenTimeApplicationUsage] {
        values.values.sorted {
            if $0.duration != $1.duration { return $0.duration > $1.duration }
            return $0.resolvedName.localizedCaseInsensitiveCompare($1.resolvedName) == .orderedAscending
        }
    }

    private static func trustNotice(for verification: AppleScreenTimeImportVerification) -> String {
        switch verification {
        case .verifiedOfficialCollector:
            return "The companion export signature was verified against a trusted official collector key. Apple API and operating-system trust boundaries still apply."
        case .signaturePresentUnverified:
            return "The imported export contains a signature, but this LocalHistory build has not verified it against a trusted official collector key."
        case .unsigned:
            return "This Apple Screen Time JSON import is not cryptographically verified and may have been edited before LocalHistory imported it."
        }
    }
}
