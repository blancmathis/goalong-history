#if os(macOS)
import Foundation
import Combine
import LocalHistoryCore
import LocalHistoryQueryCLI
import AppleScreenTime
import AppleSystemScreenTime

struct GoalongOtherDeviceUsage: Equatable, Sendable, Identifiable {
    let device: AppleScreenTimeDevice
    let screenOnSeconds: TimeInterval
    let duringMacGapsSeconds: TimeInterval
    let duringMacActivitySeconds: TimeInterval
    let lastUpdatedAt: Date
    let estimated: Bool
    var id: String { device.id }
}
struct GoalongOtherDevicesLane: Equatable, Sendable {
    let status: GoalongSystemSourceStatus
    var devices: [GoalongOtherDeviceUsage] = []
}
enum GoalongOtherDevicesSource {
    static func build(reports: [AppleScreenTimeDeviceReport], macDay: GoalongLocalAnalytics.Day, scope: AppleScreenTimeScope,
                      enabled: Bool, privacy: GoalongPrivacyPolicy = .init()) -> GoalongOtherDevicesLane {
        guard enabled else { return .init(status: .disabled) }
        // Device totals have no app/domain provenance with which to remove global exclusions.
        guard !privacy.hasExclusions else { return .init(status: .partial) }
        let gapIntervals = macDay.segments.filter { $0.kind == .unobserved || $0.kind == .idle }.map { DateInterval(start: $0.start, end: $0.end) }
        let activityIntervals = macDay.segments.filter { $0.kind.isActive }.map { DateInterval(start: $0.start, end: $0.end) }
        let day = DateInterval(start: macDay.date, end: macDay.end)
        var rows: [GoalongOtherDeviceUsage] = [], partial = macDay.state == .incomplete
        for report in reports.prefix(128) where report.device.kind != .mac && report.device.id != AppleScreenTimeProvenance.appleSettingsAllDevicesReportID && scope.includes(report.device) {
            guard report.segments.count <= 10_000 else { partial = true; continue }
            var seconds: TimeInterval = 0, gaps: TimeInterval = 0, activity: TimeInterval = 0, estimated = false
            var lastEnd: Date?
            for segment in report.segments.sorted(by: { $0.start < $1.start }) {
                guard segment.end > segment.start, lastEnd.map({ $0 <= segment.start }) ?? true else { partial = true; continue }
                lastEnd = segment.end
                guard let clipped = GoalongSourceIntervals.clipped(segment.start, segment.end, to: day) else { continue }
                let weight = segment.totalScreenOnDuration / segment.interval.duration
                seconds += clipped.duration * weight
                let gapOverlap = GoalongSourceIntervals.unionSeconds(gapIntervals.compactMap { GoalongSourceIntervals.clipped($0.start, $0.end, to: clipped) })
                let activeOverlap = GoalongSourceIntervals.unionSeconds(activityIntervals.compactMap { GoalongSourceIntervals.clipped($0.start, $0.end, to: clipped) })
                gaps += gapOverlap * weight; activity += activeOverlap * weight
                // A partial-duration coarse bucket does not locate those seconds exactly.
                if weight > 0 && weight < 1 && (gapOverlap > 0 || activeOverlap > 0 || clipped.duration < segment.interval.duration) { estimated = true }
            }
            rows.append(.init(device: report.device, screenOnSeconds: seconds, duringMacGapsSeconds: gaps,
                              duringMacActivitySeconds: activity, lastUpdatedAt: report.lastUpdatedAt, estimated: estimated))
        }
        if reports.count > 128 { partial = true }
        return .init(status: partial ? .partial : rows.isEmpty ? .noData : .ready, devices: rows)
    }
    static func load(root: URL, day: GoalongLocalAnalytics.Day, enabled: Bool, deviceIDs: Set<String>? = nil,
                     privacy: GoalongPrivacyPolicy = .init(), allowsApplication: ((AppleScreenTimeApplicationUsage) -> Bool)? = nil) -> GoalongOtherDevicesLane {
        guard enabled else { return .init(status: .disabled) }
        do {
            let screenRoot = root.appendingPathComponent("apple-screen-time")
            let archive = try AppleSystemScreenTimeDailyArchive(rootDirectory: screenRoot, createIfMissing: false)
            guard let record = try archive.storedRecord(for: day.date) else { return .init(status: .noData) }
            if record.collection.status.kind == .fullDiskAccessRequired { return .init(status: .permissionDenied) }
            guard let stored = record.collection.storedExport else { return .init(status: .noData) }
            // Configuration read through a bounded no-follow helper; do not create a store while reading.
            let configBytes = try GoalongSystemSourceFiles.read(root: root, folder: "apple-screen-time", name: "configuration.json", maximumBytes: 65_536)
            let configured = try configBytes.map { try AppleScreenTimeJSON.decode(AppleScreenTimeConfiguration.self, from: $0) } ?? .default
            var reports = stored.envelope.reports
            if let deviceIDs { reports = reports.filter { deviceIDs.contains($0.device.id) } }
            var removed = false
            if let allowsApplication {
                reports = reports.filter { report in
                    let applications = report.segments.flatMap(\.applications)
                    let allowed = !applications.isEmpty && applications.allSatisfy(allowsApplication)
                    if !allowed { removed = true }; return allowed
                }
            }
            let built = build(reports: reports, macDay: day, scope: configured.scope, enabled: true, privacy: privacy)
            return removed || record.collection.status.kind == .partial ? .init(status: .partial, devices: built.devices) : built
        } catch { return .init(status: .failed("Lecture des appareils Apple incomplète.")) }
    }
}
struct GoalongHealthLane: Equatable, Sendable {
    var status: GoalongSystemSourceStatus
    var sleepSeconds: TimeInterval?
    var sleepStages: [String: TimeInterval] = [:]
    var steps: Double?
    var workoutCount = 0
    var workoutSeconds: TimeInterval = 0
    var timeZone: String?
    /// Sleep is split at midnight, not assigned to the wake-up day by the import.
    let sleepLabel = "Sommeil pendant cette date (découpé à minuit dans le fuseau de l’import)"
}
enum GoalongHealthSource {
    static func load(root: URL, day: Date) -> GoalongHealthLane {
        let key = GoalongSystemSourceFiles.dayKey(day)
        do {
            guard let bytes = try GoalongSystemSourceFiles.read(root: root, folder: "health", name: key + ".json", maximumBytes: 2 * 1024 * 1024) else { return .init(status: .noData) }
            if let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], envelope["version"] as? Int != 2 { return .init(status: .unsupported) }
            let data = try GoalongHealthArchive.read(day: key, root: root)
            return try decode(data)
        } catch { return .init(status: .failed("Import Santé illisible ou incompatible.")) }
    }
    static func decode(_ data: Data) throws -> GoalongHealthLane {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any], envelope["version"] as? Int == 2,
              envelope["source"] as? String == "apple-health", let days = envelope["days"] as? [[String: Any]], days.count == 1,
              let health = days[0]["health"] as? [String: Any], health["version"] as? Int == 1,
              let metrics = health["metrics"] as? [[String: Any]], metrics.count <= 128,
              let workouts = health["workouts"] as? [[String: Any]], workouts.count <= 100 else { throw CocoaError(.fileReadCorruptFile) }
        var result = GoalongHealthLane(status: .partial) // Explicit imports are partial snapshots of selected sources.
        result.timeZone = (days[0]["telemetry"] as? [String: Any])?["timezone"] as? String
        for metric in metrics {
            guard let key = metric["key"] as? String, let n = metric["value"] as? Double, n.isFinite, n >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            if key.hasPrefix("sleep"), key.hasSuffix("Seconds") { result.sleepStages[key] = n }
            if key == "steps" { result.steps = n }
        }
        if let sleep = result.sleepStages["sleepSeconds"] { result.sleepSeconds = sleep }
        else if !result.sleepStages.isEmpty { result.sleepSeconds = ["sleepUnspecifiedSeconds", "sleepCoreSeconds", "sleepDeepSeconds", "sleepREMSeconds"].reduce(0) { $0 + (result.sleepStages[$1] ?? 0) } }
        result.workoutCount = workouts.count
        for workout in workouts {
            guard let duration = workout["durationSeconds"] as? Double, duration.isFinite, duration >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            result.workoutSeconds += duration
        }
        return result
    }
}
struct GoalongSystemSourcesDay: Sendable {
    let calls: GoalongCallLane
    let calendar: GoalongCalendarLane
    let otherDevices: GoalongOtherDevicesLane
    let health: GoalongHealthLane
    let note: String?
    let noteStatus: GoalongSystemSourceStatus
}
actor GoalongSystemSourcesReader {
    private let root: URL
    private var devicesCache: [String: (String, GoalongLocalAnalytics.Day, GoalongOtherDevicesLane)] = [:]
    private var healthCache: [String: (String, GoalongHealthLane)] = [:]
    init(root: URL) { self.root = root }
    func read(day: GoalongLocalAnalytics.Day, callsEnabled: Bool, calendarEnabled: Bool, screenTimeEnabled: Bool) async -> GoalongSystemSourcesDay {
        let privacy = GoalongPrivacyPolicy.load(in: root)
        let key = GoalongSystemSourceFiles.dayKey(day.date)
        let url = root.appendingPathComponent("health/" + key + ".json")
        let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let fingerprint = "\(attributes?.fileResourceIdentifier as Any)|\(attributes?.fileSize ?? -1)|\(attributes?.contentModificationDate as Any)"
        let health: GoalongHealthLane
        if let cached = healthCache[key], cached.0 == fingerprint { health = cached.1 }
        else { health = GoalongHealthSource.load(root: root, day: day.date); if healthCache.count >= 64 { healthCache.removeAll() }; healthCache[key] = (fingerprint, health) }
        let devices: GoalongOtherDevicesLane
        let deviceURLs = [root.appendingPathComponent("apple-screen-time/days/" + key + ".json"),
                          root.appendingPathComponent("apple-screen-time/configuration.json")]
        let deviceFingerprint = deviceURLs.map { url -> String in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            return "\(values?.fileResourceIdentifier as Any)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate as Any)"
        }.joined(separator: "|") + "|" + privacy.revision + "|\(screenTimeEnabled)"
        if let cached = devicesCache[key], cached.0 == deviceFingerprint, cached.1 == day { devices = cached.2 }
        else {
            devices = GoalongOtherDevicesSource.load(root: root, day: day, enabled: screenTimeEnabled, privacy: privacy)
            if devicesCache.count >= 8 { devicesCache.removeAll() }; devicesCache[key] = (deviceFingerprint, day, devices)
        }
        let agenda = await GoalongCalendarSource.shared.read(day: day.date, enabled: calendarEnabled && !privacy.blocked)
        let note: String?, noteStatus: GoalongSystemSourceStatus
        do { note = try GoalongDayNoteStore.get(root: root, day: day.date); noteStatus = note == nil ? .noData : .ready }
        catch { note = nil; noteStatus = .failed("Note du jour illisible.") }
        return .init(calls: GoalongCallPresenceMonitor.lane(root: root, day: day.date, enabled: callsEnabled, privacy: privacy), calendar: agenda,
                     otherDevices: devices,
                     health: health, note: note, noteStatus: noteStatus)
    }
}
/// UI API: on-demand reads, independent permission request, reversible source toggles and a day note.
@MainActor final class GoalongSystemSourcesModel: ObservableObject {
    @Published private(set) var value: GoalongSystemSourcesDay?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    var calendarEnabled: Bool { consent.isEnabled(.calendar) }
    var callPresenceEnabled: Bool { (try? RecorderConfig.load(from: root.appendingPathComponent("config.json")))?.effectiveCaptureCallPresence ?? true }
    var calendarPermission: GoalongSystemSourceStatus { GoalongCalendarSource.authorization(for: .event) }
    var remindersPermission: GoalongSystemSourceStatus { GoalongCalendarSource.authorization(for: .reminder) }
    private let root: URL
    private let reader: GoalongSystemSourcesReader
    private let consent: GoalongCapabilityConsentStore
    private var request = UUID()
    init(root: URL = AppPaths.applicationSupportDirectory, consent: GoalongCapabilityConsentStore = .shared) {
        self.root = root; self.reader = .init(root: root); self.consent = consent
    }
    func refresh(day: GoalongLocalAnalytics.Day) async {
        let id = UUID(); request = id; loading = true; defer { if request == id { loading = false } }
        if GoalongGlobalPause.isPaused(in: root) { value = nil; return }
        let consents = consent.document
        let config = try? RecorderConfig.load(from: root.appendingPathComponent("config.json"))
        let loaded = await reader.read(day: day, callsEnabled: consents.isEnabled(.localComputerHistory) && config?.effectiveCaptureCallPresence != false,
                                      calendarEnabled: consents.isEnabled(.calendar), screenTimeEnabled: consents.isEnabled(.appleScreenTime))
        guard request == id else { return } // a newer read owns the value
        guard !Task.isCancelled, !GoalongGlobalPause.isPaused(in: root), consent.document == consents else { value = nil; return }
        value = loaded
    }
    @discardableResult func setCalendarEnabled(_ enabled: Bool) -> Bool {
        let saved = consent.set(.calendar, enabled: enabled, surface: .settings)
        if saved { request = UUID(); value = nil; if !enabled { Task { await GoalongCalendarSource.shared.disable() } } }
        return saved
    }
    func requestCalendarPermissions() async {
        guard calendarEnabled, !GoalongGlobalPause.isPaused(in: root) else { return }
        _ = await GoalongCalendarSource.shared.requestAccess(enabled: true)
        value = nil
        objectWillChange.send()
    }
    func setNote(_ text: String, day: Date) throws { try GoalongDayNoteStore.set(text, root: root, day: day); request = UUID(); value = nil }
    func deleteNote(day: Date) throws { try GoalongDayNoteStore.delete(root: root, day: day); request = UUID(); value = nil }
}
#endif
