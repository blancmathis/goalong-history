import Darwin
import Foundation
import CoreFoundation

/// Compact, explicitly imported days only. The original Apple export is never copied.
public enum GoalongHealthArchive {
    public static func save(_ result: GoalongHealthImportResult, root: URL) throws {
        let directory = try openDirectory(root, create: true)
        defer { close(directory) }
        guard let envelope = try JSONSerialization.jsonObject(with: result.payload) as? [String: Any],
              let days = envelope["days"] as? [[String: Any]], days.count <= 366 else {
            throw GoalongSiteExportError.invalid("L’aperçu Santé est invalide. Recréez-le.")
        }
        for day in days {
            guard let date = day["date"] as? String, validDay(date) else { throw GoalongSiteExportError.invalid("Date Santé invalide.") }
            let data = try JSONSerialization.data(withJSONObject: ["version": 2, "source": "apple-health", "days": [day]], options: [.sortedKeys])
            try validate(data, expectedDay: date)
            let temporary = ".health-\(UUID().uuidString)"
            let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(descriptor); unlinkat(directory, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw CocoaError(.fileWriteUnknown) }; offset += n
                }
            }
            guard fsync(descriptor) == 0, renameat(directory, temporary, directory, date + ".json") == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    public static func dates(root: URL) throws -> [String] {
        let directory = try openDirectory(root, create: false); defer { close(directory) }
        return try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("health").path)
            .filter { $0.hasSuffix(".json") && validDay(String($0.dropLast(5))) }.map { String($0.dropLast(5)) }.sorted().reversed()
    }

    public static func read(day: String, root: URL) throws -> Data {
        guard validDay(day) else { throw GoalongSiteExportError.invalid("Date Santé invalide.") }
        let directory = try openDirectory(root, create: false); defer { close(directory) }
        let descriptor = openat(directory, day + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw GoalongSiteExportError.invalid("Aucune donnée Santé enregistrée pour cette journée.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= 2 * 1024 * 1024 else {
            throw GoalongSiteExportError.invalid("Le fichier Santé local ne possède pas les protections attendues.")
        }
        guard let bytes = try handle.read(upToCount: 2 * 1024 * 1024 + 1), bytes.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw CocoaError(.fileReadCorruptFile) }
        try validate(bytes, expectedDay: day)
        return bytes
    }

    private static func validDay(_ day: String) -> Bool {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: day).map { formatter.string(from: $0) == day } ?? false
    }

    /// A reopened day must contain only fields visible in the Health preview.
    /// Reject extra fields instead of forwarding an edited local file verbatim.
    private static func validate(_ data: Data, expectedDay: String) throws {
        func require(_ condition: Bool) throws { if !condition { throw GoalongSiteExportError.invalid("Le fichier Santé local est invalide. Recréez l’aperçu depuis l’export Apple Santé.") } }
        func object(_ value: Any?, _ keys: Set<String>) throws -> [String: Any] {
            guard let value = value as? [String: Any], Set(value.keys) == keys else { try require(false); return [:] }
            return value
        }
        func number(_ value: Any?, maximum: Double, integer: Bool = false) -> Bool {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            let v = n.doubleValue
            return v.isFinite && v >= 0 && v <= maximum && (!integer || v.rounded() == v)
        }
        func label(_ value: Any?, maximum: Int = 100) -> Bool {
            guard let value = value as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= maximum && value.rangeOfCharacter(from: .controlCharacters) == nil
        }
        let envelope = try object(JSONSerialization.jsonObject(with: data), ["version", "source", "days"])
        try require(envelope["version"] as? Int == 2 && envelope["source"] as? String == "apple-health")
        let days = envelope["days"] as? [Any] ?? []
        try require(days.count == 1)
        let day = try object(days.first, ["date", "title", "summary", "outcomes", "activities", "telemetry", "health"])
        try require(day["date"] as? String == expectedDay && label(day["title"], maximum: 160) && day["summary"] as? String == "")
        try require((day["outcomes"] as? [Any])?.isEmpty == true && (day["activities"] as? [Any])?.isEmpty == true)
        let telemetry = try object(day["telemetry"], ["timezone", "receivedAt", "state", "devices", "websites", "agent"])
        let zone = (telemetry["timezone"] as? String).flatMap(TimeZone.init(identifier:))
        try require(zone != nil && ["completed", "in-progress"].contains(telemetry["state"] as? String ?? ""))
        let iso = ISO8601DateFormatter()
        try require((telemetry["receivedAt"] as? String).flatMap(iso.date(from:)) != nil)
        try require((telemetry["devices"] as? [Any])?.isEmpty == true && telemetry["websites"] is NSNull && telemetry["agent"] is NSNull)
        let health = try object(day["health"], ["version", "coverage", "metrics", "workouts"])
        try require(health["version"] as? Int == 1 && health["coverage"] as? String == "partial")
        guard let metrics = health["metrics"] as? [Any], let workouts = health["workouts"] as? [Any] else { try require(false); return }
        let contracts = GoalongHealthImport.metricContracts
        try require(metrics.count <= contracts.count && workouts.count <= 100 && (!metrics.isEmpty || !workouts.isEmpty))
        var seen = Set<String>()
        for value in metrics {
            let row = try object(value, ["key", "value", "unit", "source", "sampleCount", "aggregation"])
            guard let key = row["key"] as? String, let rule = contracts[key] else { try require(false); return }
            try require(seen.insert(key).inserted && number(row["value"], maximum: rule.maximum))
            try require(row["unit"] as? String == rule.unit && row["aggregation"] as? String == rule.aggregation && label(row["source"]))
            try require(number(row["sampleCount"], maximum: 500_000, integer: true) && (row["sampleCount"] as? Int ?? 0) > 0)
        }
        seen.removeAll()
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = zone; local.dateFormat = "yyyy-MM-dd"
        for value in workouts {
            let row = try object(value, ["id", "sport", "source", "startedAt", "endedAt", "durationSeconds", "distanceMeters", "energyKcal"])
            guard let id = row["id"] as? String, let sport = row["sport"] as? String,
                  let start = (row["startedAt"] as? String).flatMap(iso.date(from:)),
                  let end = (row["endedAt"] as? String).flatMap(iso.date(from:)) else { try require(false); return }
            try require(id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil && seen.insert(id).inserted)
            try require(sport.range(of: #"^HKWorkoutActivityType[A-Za-z]{1,70}$"#, options: .regularExpression) != nil && label(row["source"]))
            let elapsed = end.timeIntervalSince(start)
            try require(elapsed >= 0 && elapsed <= 604_800 && local.string(from: start) == expectedDay)
            try require(number(row["durationSeconds"], maximum: min(604_800, elapsed + 60)))
            try require(row["distanceMeters"] is NSNull || number(row["distanceMeters"], maximum: 2_000_000))
            try require(row["energyKcal"] is NSNull || number(row["energyKcal"], maximum: 50_000))
        }
    }
    private static func openDirectory(_ root: URL, create: Bool) throws -> Int32 {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw GoalongSiteExportError.invalid("Le dossier Goalong History n’est pas disponible.") }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, rootInfo.st_uid == getuid() else { throw CocoaError(.fileReadNoPermission) }
        if create, mkdirat(rootFD, "health", 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteNoPermission) }
        let fd = openat(rootFD, "health", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GoalongSiteExportError.invalid("Aucune donnée Santé locale. Importez d’abord votre export Apple Santé.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { close(fd); throw CocoaError(.fileReadNoPermission) }
        return fd
    }
}
