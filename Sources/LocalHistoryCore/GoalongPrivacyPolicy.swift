import Foundation

/// Explicit global exclusions, separate from legacy recorder-only filters.
/// Missing policy preserves existing choices. Invalid policy denies access.
public struct GoalongPrivacyPolicy: Codable, Equatable {
    public var version = 1
    public var revision = UUID().uuidString
    public var applications: [String: String] = [:]
    public var domains: [String] = []
    public var inspectDomainsForExclusions = false
    public var blocked = false
    /// Opaque browser aggregates before this policy cannot be retroactively filtered.
    public var effectiveFrom: Date?
    public init() {}
    public var hasExclusions: Bool { blocked || !applications.isEmpty || !domains.isEmpty }
    public func excludes(appID: String?, name: String? = nil) -> Bool {
        if blocked { return true }
        if let appID, applications.keys.contains(where: { $0.caseInsensitiveCompare(appID) == .orderedSame }) { return true }
        return name.map { name in applications.values.contains { $0.caseInsensitiveCompare(name) == .orderedSame } } ?? false
    }
    public func excludes(domain: String?) -> Bool {
        if blocked { return true }
        guard let domain else { return false }
        return URLRedactor.domain(domain.lowercased(), matches: domains)
    }
    public func permits(_ event: HistoryEvent) -> Bool {
        !excludes(appID: event.app?.bundleIdentifier, name: event.app?.name) && !excludes(domain: event.url?.host)
    }
    public func eventForPersistence(_ event: HistoryEvent, expectedRevision: String?) -> HistoryEvent {
        let changed = expectedRevision.map { $0 != revision } ?? false
        guard blocked || changed || !permits(event) else { return event }
        return HistoryEvent(schemaVersion: event.schemaVersion, id: event.id, sessionID: event.sessionID,
            timestamp: event.timestamp, kind: .heartbeat, suppressionReason: .excludedApplication)
    }
    public func applying(to config: RecorderConfig) -> RecorderConfig {
        var result = config
        result.excludedBundleIdentifiers = Array(Set(config.excludedBundleIdentifiers + Array(applications.keys))).sorted()
        result.excludedDomains = Array(Set(config.excludedDomains + domains)).sorted()
        return result
    }
    public static func file(in root: URL) -> URL { root.appendingPathComponent("global-exclusions.json") }
    public static func load(in root: URL) -> Self {
        let file = file(in: root)
        guard FileManager.default.fileExists(atPath: file.path) else { var empty = Self(); empty.revision = "none"; return empty }
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 262_144 else { return failClosed }
            let policy = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard policy.version == 1, policy.applications.count <= 2048, policy.domains.count <= 512 else { return failClosed }
            return policy
        } catch { return failClosed }
    }
    private static var failClosed: Self { var p = Self(); p.blocked = true; p.revision = "unreadable"; return p }
    public func save(in root: URL) throws {
        guard version == 1, applications.count <= 2048, domains.count <= 512 else {
            throw NSError(domain: "GoalongPrivacy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Trop d’exclusions ou format incompatible."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = Self.file(in: root)
        let temp = root.appendingPathComponent(".exclusions-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard fm.createFile(atPath: temp.path, contents: try encoder.encode(self), attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "GoalongPrivacy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Les exclusions n’ont pas été enregistrées."])
        }
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temp) }
        else { try fm.moveItem(at: temp, to: target) }
    }
}

/// Fast readers share a metadata-validated snapshot. Network dispatchers use load(),
/// never the cache, to revalidate the current policy immediately before sending.
public enum GoalongPrivacyPolicyCache {
    private static let lock = NSLock()
    private struct Entry { let signature: String; let policy: GoalongPrivacyPolicy }
    private static var values: [String: Entry] = [:]
    public static func read(in root: URL) -> GoalongPrivacyPolicy {
        let path = GoalongPrivacyPolicy.file(in: root).path
        let metadata = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (metadata?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let signature = "\(metadata?[.systemFileNumber] ?? "none")|\(modified)|\(metadata?[.size] ?? "none")"
        lock.lock(); defer { lock.unlock() }
        if let cached = values[path], cached.signature == signature { return cached.policy }
        let policy = GoalongPrivacyPolicy.load(in: root)
        if values.count > 16 { values.removeAll() }
        values[path] = Entry(signature: signature, policy: policy)
        return policy
    }
    public static func invalidate(in root: URL) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: GoalongPrivacyPolicy.file(in: root).path)
    }
}
