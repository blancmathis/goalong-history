import Foundation

public enum AppleScreenTimeCollectorAvailability: Equatable, Sendable {
    case available
    case unavailablePlatform
    case operatingSystemTooOld
    case missingEntitlementOrApproval
    case outsideSupportedCustomerRegion
}

public protocol AppleScreenTimeCollecting {
    var availability: AppleScreenTimeCollectorAvailability { get }

    func requestAuthorization() async throws

    func collect(
        interval: DateInterval,
        scope: AppleScreenTimeScope,
        live: Bool
    ) async throws -> AppleScreenTimeExportEnvelope
}

public struct UnavailableAppleScreenTimeCollector: AppleScreenTimeCollecting {
    public let availability: AppleScreenTimeCollectorAvailability

    public init(availability: AppleScreenTimeCollectorAvailability = .unavailablePlatform) {
        self.availability = availability
    }

    public func requestAuthorization() async throws {
        throw AppleScreenTimeNativeCollectorError.unavailable(availability)
    }

    public func collect(
        interval: DateInterval,
        scope: AppleScreenTimeScope,
        live: Bool
    ) async throws -> AppleScreenTimeExportEnvelope {
        throw AppleScreenTimeNativeCollectorError.unavailable(availability)
    }
}

public enum AppleScreenTimeNativeCollectorError: Error, CustomStringConvertible {
    case unavailable(AppleScreenTimeCollectorAvailability)
    case authorizationNotApprovedWithDataAccess
    case invalidInterval

    public var description: String {
        switch self {
        case .unavailable(let availability):
            return "Apple Screen Time collection is unavailable: \(String(describing: availability))."
        case .authorizationNotApprovedWithDataAccess:
            return "Apple Screen Time access was not approved with app and website data access."
        case .invalidInterval:
            return "The requested Apple Screen Time interval is invalid."
        }
    }
}

#if os(iOS) && canImport(DeviceActivity) && canImport(FamilyControls)
    import DeviceActivity
    import FamilyControls

    /// Official Screen Time collector for the 2026 DeviceActivity data-export API.
    ///
    /// Apple limits customer use of `activityData(filteredBy:using:)` to eligible EU devices,
    /// requires `approvedWithDataAccess`, and requires the managed
    /// `com.apple.developer.family-controls.app-and-website-usage` entitlement.
    @available(iOS 26.0, *)
    public struct AppleDeviceActivityCollector: AppleScreenTimeCollecting {
        public init() {}

        public var availability: AppleScreenTimeCollectorAvailability { .available }

        public func requestAuthorization() async throws {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            guard AuthorizationCenter.shared.authorizationStatus == .approvedWithDataAccess else {
                throw AppleScreenTimeNativeCollectorError.authorizationNotApprovedWithDataAccess
            }
        }

        public func collect(
            interval: DateInterval,
            scope: AppleScreenTimeScope,
            live: Bool
        ) async throws -> AppleScreenTimeExportEnvelope {
            guard interval.duration > 0 else {
                throw AppleScreenTimeNativeCollectorError.invalidInterval
            }
            guard AuthorizationCenter.shared.authorizationStatus == .approvedWithDataAccess else {
                throw AppleScreenTimeNativeCollectorError.authorizationNotApprovedWithDataAccess
            }

            let devices: DeviceActivityFilter.Devices
            switch scope.mode {
            case .macOnly:
                devices = .init([.mac])
            case .allDevices, .selectedDevices:
                // Apple filters by device model, not by the human-readable physical-device name.
                // Selected physical devices are therefore filtered after collection.
                devices = .all
            }

            let filter = DeviceActivityFilter(
                segment: .daily(during: interval),
                users: .all,
                devices: devices
            )
            let policy: DeviceActivityData.Policy = live ? .live : .cached
            var reports: [AppleScreenTimeDeviceReport] = []

            for try await activityData in DeviceActivityData.activityData(filteredBy: filter, using: policy) {
                let device = AppleScreenTimeDevice(
                    name: activityData.device.name,
                    kind: Self.map(activityData.device.model)
                )
                guard scope.includes(device) else { continue }

                var segments: [AppleScreenTimeSegment] = []
                for try await segment in activityData.activitySegments {
                    segments.append(
                        AppleScreenTimeSegment(
                            start: segment.dateInterval.start,
                            end: segment.dateInterval.end,
                            totalScreenOnDuration: segment.totalActivityDuration,
                            longestActivityStart: segment.longestActivity?.start,
                            longestActivityEnd: segment.longestActivity?.end
                        )
                    )
                }

                reports.append(
                    AppleScreenTimeDeviceReport(
                        device: device,
                        lastUpdatedAt: activityData.lastUpdatedDate,
                        segments: segments
                    )
                )
            }

            let info = Bundle.main.infoDictionary
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown.collector"
            let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
            let provenance = AppleScreenTimeProvenance(
                collectorBundleIdentifier: bundleIdentifier,
                collectorVersion: version,
                collectorPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
                authorization: .approvedWithDataAccess,
                fetchPolicy: live ? .live : .cached,
                euCustomerRequirementAcknowledged: true
            )

            return AppleScreenTimeExportEnvelope(
                requestedStart: interval.start,
                requestedEnd: interval.end,
                requestedScope: scope,
                provenance: provenance,
                reports: reports
            )
        }

        private static func map(
            _ model: DeviceActivityData.Device.Model
        ) -> AppleScreenTimeDeviceKind {
            switch model {
            case .mac: return .mac
            case .iPhone: return .iPhone
            case .iPad: return .iPad
            case .iPod: return .iPod
            @unknown default: return .unknown
            }
        }
    }
#endif
