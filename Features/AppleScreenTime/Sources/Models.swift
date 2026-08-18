import Foundation

public enum AppleScreenTimeDeviceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case mac
    case iPhone
    case iPad
    case iPod
    case unknown

    public var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .iPod: return "iPod"
        case .unknown: return "Apple device"
        }
    }
}

public struct AppleScreenTimeDevice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let kind: AppleScreenTimeDeviceKind

    public init(id: String? = nil, name: String?, kind: AppleScreenTimeDeviceKind) {
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleanedName?.isEmpty == false ? cleanedName : nil
        self.kind = kind
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Self.stableID(kind: kind, name: cleanedName)
    }

    public var displayName: String {
        name ?? kind.displayName
    }

    private static func stableID(kind: AppleScreenTimeDeviceKind, name: String?) -> String {
        // FNV-1a is not a security primitive. It is only a deterministic, non-secret identifier
        // that keeps a device row stable between imports when Apple doesn't expose a public ID.
        let value = "\(kind.rawValue)|\(name?.lowercased() ?? "unnamed")"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

public enum AppleScreenTimeScopeMode: String, Codable, CaseIterable, Hashable, Sendable {
    case allDevices
    case macOnly
    case selectedDevices

    public var displayName: String {
        switch self {
        case .allDevices: return "All Apple devices"
        case .macOnly: return "Mac only"
        case .selectedDevices: return "Selected devices"
        }
    }
}

public struct AppleScreenTimeScope: Codable, Equatable, Sendable {
    public var mode: AppleScreenTimeScopeMode
    public var selectedDeviceIDs: [String]

    public init(mode: AppleScreenTimeScopeMode = .allDevices, selectedDeviceIDs: [String] = []) {
        self.mode = mode
        self.selectedDeviceIDs = Array(Set(selectedDeviceIDs.filter { !$0.isEmpty })).sorted()
    }

    public static let allDevices = AppleScreenTimeScope(mode: .allDevices)
    public static let macOnly = AppleScreenTimeScope(mode: .macOnly)

    public func includes(_ device: AppleScreenTimeDevice) -> Bool {
        switch mode {
        case .allDevices:
            return true
        case .macOnly:
            return device.kind == .mac
        case .selectedDevices:
            return selectedDeviceIDs.contains(device.id)
        }
    }

    public func normalized(availableDevices: [AppleScreenTimeDevice]) -> AppleScreenTimeScope {
        guard mode == .selectedDevices else { return AppleScreenTimeScope(mode: mode) }
        let available = Set(availableDevices.map(\.id))
        return AppleScreenTimeScope(
            mode: .selectedDevices,
            selectedDeviceIDs: selectedDeviceIDs.filter { available.contains($0) }
        )
    }
}

public enum AppleScreenTimeShareLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case totalsOnly
    case perDevice
    case applications

    public var displayName: String {
        switch self {
        case .totalsOnly: return "Totals only"
        case .perDevice: return "Per-device totals"
        case .applications: return "Devices and applications"
        }
    }
}

public struct AppleScreenTimeConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var scope: AppleScreenTimeScope
    public var shareLevel: AppleScreenTimeShareLevel

    public init(
        enabled: Bool = false,
        scope: AppleScreenTimeScope = .allDevices,
        shareLevel: AppleScreenTimeShareLevel = .perDevice
    ) {
        self.enabled = enabled
        self.scope = scope
        self.shareLevel = shareLevel
    }

    public static let `default` = AppleScreenTimeConfiguration()
}

public struct AppleScreenTimeApplicationUsage: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let bundleIdentifier: String?
    public let displayName: String?
    public let duration: TimeInterval

    public init(bundleIdentifier: String?, displayName: String?, duration: TimeInterval) {
        self.bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.duration = max(0, duration.isFinite ? duration : 0)
    }

    public var id: String {
        bundleIdentifier ?? "name:\(displayName ?? "unknown")"
    }

    public var resolvedName: String {
        displayName ?? bundleIdentifier ?? "Unknown application"
    }
}

public struct AppleScreenTimeSegment: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let totalScreenOnDuration: TimeInterval
    public let longestActivityStart: Date?
    public let longestActivityEnd: Date?
    public let applications: [AppleScreenTimeApplicationUsage]

    public init(
        start: Date,
        end: Date,
        totalScreenOnDuration: TimeInterval,
        longestActivityStart: Date? = nil,
        longestActivityEnd: Date? = nil,
        applications: [AppleScreenTimeApplicationUsage] = []
    ) {
        self.start = min(start, end)
        self.end = max(start, end)
        let maximum = max(0, self.end.timeIntervalSince(self.start))
        self.totalScreenOnDuration = min(maximum, max(0, totalScreenOnDuration.isFinite ? totalScreenOnDuration : 0))
        self.longestActivityStart = longestActivityStart
        self.longestActivityEnd = longestActivityEnd
        self.applications = applications
    }

    public var interval: DateInterval {
        DateInterval(start: start, end: end)
    }
}

public struct AppleScreenTimeDeviceReport: Codable, Equatable, Identifiable, Sendable {
    public let device: AppleScreenTimeDevice
    public let lastUpdatedAt: Date
    public let segments: [AppleScreenTimeSegment]

    public init(device: AppleScreenTimeDevice, lastUpdatedAt: Date, segments: [AppleScreenTimeSegment]) {
        self.device = device
        self.lastUpdatedAt = lastUpdatedAt
        self.segments = segments.sorted { $0.start < $1.start }
    }

    public var id: String { device.id }
}

public enum AppleScreenTimeAuthorizationEvidence: String, Codable, Sendable {
    case approvedWithDataAccess
    case approvedWithoutDataAccess
    case unknown
}

public enum AppleScreenTimeFetchPolicy: String, Codable, Sendable {
    case live
    case cached
    case unknown
}

public struct AppleScreenTimeSignature: Codable, Equatable, Sendable {
    public let algorithm: String
    public let publicKeyBase64: String
    public let signatureBase64: String
    public let keyIdentifier: String?

    public init(
        algorithm: String,
        publicKeyBase64: String,
        signatureBase64: String,
        keyIdentifier: String? = nil
    ) {
        self.algorithm = algorithm
        self.publicKeyBase64 = publicKeyBase64
        self.signatureBase64 = signatureBase64
        self.keyIdentifier = keyIdentifier
    }
}

public struct AppleScreenTimeProvenance: Codable, Equatable, Sendable {
    public let api: String
    public let collectorBundleIdentifier: String
    public let collectorVersion: String
    public let collectorPlatform: String
    public let authorization: AppleScreenTimeAuthorizationEvidence
    public let fetchPolicy: AppleScreenTimeFetchPolicy
    public let euCustomerRequirementAcknowledged: Bool
    public let signature: AppleScreenTimeSignature?

    public init(
        api: String = "Apple DeviceActivityData.activityData",
        collectorBundleIdentifier: String,
        collectorVersion: String,
        collectorPlatform: String,
        authorization: AppleScreenTimeAuthorizationEvidence,
        fetchPolicy: AppleScreenTimeFetchPolicy,
        euCustomerRequirementAcknowledged: Bool,
        signature: AppleScreenTimeSignature? = nil
    ) {
        self.api = api
        self.collectorBundleIdentifier = collectorBundleIdentifier
        self.collectorVersion = collectorVersion
        self.collectorPlatform = collectorPlatform
        self.authorization = authorization
        self.fetchPolicy = fetchPolicy
        self.euCustomerRequirementAcknowledged = euCustomerRequirementAcknowledged
        self.signature = signature
    }
}

public struct AppleScreenTimeExportEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let requestedStart: Date
    public let requestedEnd: Date
    public let requestedScope: AppleScreenTimeScope
    public let provenance: AppleScreenTimeProvenance
    public let reports: [AppleScreenTimeDeviceReport]

    public init(
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        requestedStart: Date,
        requestedEnd: Date,
        requestedScope: AppleScreenTimeScope,
        provenance: AppleScreenTimeProvenance,
        reports: [AppleScreenTimeDeviceReport]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.requestedStart = min(requestedStart, requestedEnd)
        self.requestedEnd = max(requestedStart, requestedEnd)
        self.requestedScope = requestedScope
        self.provenance = provenance
        self.reports = reports.sorted { lhs, rhs in
            if lhs.device.kind.rawValue != rhs.device.kind.rawValue {
                return lhs.device.kind.rawValue < rhs.device.kind.rawValue
            }
            return lhs.device.displayName.localizedCaseInsensitiveCompare(rhs.device.displayName) == .orderedAscending
        }
    }
}

public enum AppleScreenTimeImportVerification: String, Codable, Sendable {
    /// The payload does not contain a companion signature.
    case unsigned
    /// A signature is present but this LocalHistory build has not verified it against a trusted official key.
    case signaturePresentUnverified
    /// A caller supplied a trusted verifier and the companion signature passed.
    case verifiedOfficialCollector
}

public struct AppleScreenTimeStoredExport: Codable, Equatable, Sendable {
    public let importedAt: Date
    public let verification: AppleScreenTimeImportVerification
    public let envelope: AppleScreenTimeExportEnvelope

    public init(
        importedAt: Date = Date(),
        verification: AppleScreenTimeImportVerification,
        envelope: AppleScreenTimeExportEnvelope
    ) {
        self.importedAt = importedAt
        self.verification = verification
        self.envelope = envelope
    }
}

public struct AppleScreenTimeDeviceSummary: Codable, Equatable, Identifiable, Sendable {
    public let device: AppleScreenTimeDevice
    public let screenOnDuration: TimeInterval
    public let lastUpdatedAt: Date
    public let applications: [AppleScreenTimeApplicationUsage]

    public var id: String { device.id }
}

public struct AppleScreenTimeDaySummary: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let scope: AppleScreenTimeScope
    public let verification: AppleScreenTimeImportVerification
    public let provenance: AppleScreenTimeProvenance
    public let totalScreenOnDuration: TimeInterval
    public let deviceSummaries: [AppleScreenTimeDeviceSummary]
    public let topApplications: [AppleScreenTimeApplicationUsage]
    public let latestDataUpdate: Date?

    public init(
        start: Date,
        end: Date,
        scope: AppleScreenTimeScope,
        verification: AppleScreenTimeImportVerification,
        provenance: AppleScreenTimeProvenance,
        totalScreenOnDuration: TimeInterval,
        deviceSummaries: [AppleScreenTimeDeviceSummary],
        topApplications: [AppleScreenTimeApplicationUsage],
        latestDataUpdate: Date?
    ) {
        self.start = start
        self.end = end
        self.scope = scope
        self.verification = verification
        self.provenance = provenance
        self.totalScreenOnDuration = totalScreenOnDuration
        self.deviceSummaries = deviceSummaries
        self.topApplications = topApplications
        self.latestDataUpdate = latestDataUpdate
    }

    public var includedDevices: [AppleScreenTimeDevice] {
        deviceSummaries.map(\.device)
    }
}

public struct AppleScreenTimeShareDevice: Codable, Equatable, Sendable {
    public let device: AppleScreenTimeDevice
    public let screenOnDuration: TimeInterval
    public let applications: [AppleScreenTimeApplicationUsage]?
}

public struct AppleScreenTimeSharePayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let start: Date
    public let end: Date
    public let requestedScope: AppleScreenTimeScope
    public let includedDeviceCount: Int
    public let totalScreenOnDuration: TimeInterval
    public let aggregationMethod: String
    public let disclosureLevel: AppleScreenTimeShareLevel
    public let devices: [AppleScreenTimeShareDevice]?
    public let provenance: AppleScreenTimeProvenance
    public let importVerification: AppleScreenTimeImportVerification
    public let trustNotice: String

    public init(
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        start: Date,
        end: Date,
        requestedScope: AppleScreenTimeScope,
        includedDeviceCount: Int,
        totalScreenOnDuration: TimeInterval,
        aggregationMethod: String = "sum_of_per_device_screen_on_duration_no_cross_device_deduplication",
        disclosureLevel: AppleScreenTimeShareLevel,
        devices: [AppleScreenTimeShareDevice]?,
        provenance: AppleScreenTimeProvenance,
        importVerification: AppleScreenTimeImportVerification,
        trustNotice: String
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.start = start
        self.end = end
        self.requestedScope = requestedScope
        self.includedDeviceCount = includedDeviceCount
        self.totalScreenOnDuration = totalScreenOnDuration
        self.aggregationMethod = aggregationMethod
        self.disclosureLevel = disclosureLevel
        self.devices = devices
        self.provenance = provenance
        self.importVerification = importVerification
        self.trustNotice = trustNotice
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
