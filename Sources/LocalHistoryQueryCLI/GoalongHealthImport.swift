import CryptoKit
import Darwin
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum GoalongHealthGroup: String, CaseIterable, Sendable, Identifiable {
    case sleep, heart, activity, workouts
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sleep: return "Sommeil"
        case .heart: return "Cœur et récupération"
        case .activity: return "Activité quotidienne"
        case .workouts: return "Courses et entraînements"
        }
    }
}

public struct GoalongHealthImportOptions: Sendable {
    public var from: Date
    public var through: Date
    public var timezone: TimeZone
    public var groups: Set<GoalongHealthGroup>
    public var preferredSources: [GoalongHealthGroup: String]
    public init(from: Date, through: Date, timezone: TimeZone = .current,
                groups: Set<GoalongHealthGroup> = Set(GoalongHealthGroup.allCases),
                preferredSources: [GoalongHealthGroup: String] = [:]) {
        self.from = from; self.through = through; self.timezone = timezone
        self.groups = groups; self.preferredSources = preferredSources
    }
}

public struct GoalongHealthImportResult: Sendable {
    public let payload: Data
    public let dayCount: Int
    public let metricCount: Int
    public let workoutCount: Int
    public let sources: [GoalongHealthGroup: [String]]
    public let warnings: [String]
}

/// Reads only the XML explicitly selected by the user. No HealthKit/iCloud discovery,
/// network access, source mutation, full archive retention or medical interpretation.
public enum GoalongHealthImport {
    static var metricContracts: [String: (unit: String, maximum: Double, aggregation: String)] {
        var values = Dictionary(uniqueKeysWithValues: HealthXMLReader.definitions.values.map {
            ($0.key, (unit: $0.unit, maximum: $0.maximum, aggregation: $0.mode == "mean" ? "sample-mean" : "sum-nonoverlapping"))
        })
        for key in ["sleepSeconds", "inBedSeconds", "awakeSeconds", "sleepUnspecifiedSeconds", "sleepCoreSeconds", "sleepDeepSeconds", "sleepREMSeconds"] {
            values[key] = ("s", 90_000, "interval-union")
        }
        values["heartRateMinBPM"] = ("bpm", 350, "sample-min")
        values["heartRateMaxBPM"] = ("bpm", 350, "sample-max")
        return values
    }

    public static func read(file: URL, options: GoalongHealthImportOptions) throws -> GoalongHealthImportResult {
        let input = try HealthFileStream(file)
        defer { input.close() }
        return try parse(stream: input, options: options, after: { try input.validateUnchanged() })
    }

    public static func read(data: Data, options: GoalongHealthImportOptions) throws -> GoalongHealthImportResult {
        guard data.count <= 32 * 1024 * 1024 else { throw invalid("Le fichier de contrôle est trop grand.") }
        return try parse(stream: InputStream(data: data), options: options, after: {})
    }

    private static func parse(stream: InputStream, options: GoalongHealthImportOptions,
                              after: () throws -> Void) throws -> GoalongHealthImportResult {
        let reader = try HealthXMLReader(options)
        let parser = XMLParser(stream: stream)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.failure == nil, reader.isHealthExport else {
            throw reader.failure ?? invalid("Choisissez export.xml issu de Santé. Le fichier XML est incomplet ou invalide.")
        }
        try after()
        return try reader.result()
    }

    fileprivate static func invalid(_ message: String) -> GoalongSiteExportError { .invalid(message) }
}

private final class HealthFileStream: InputStream {
    private let descriptor: Int32
    private var metadata: stat
    private var closed = false
    private var atEnd = false
    private var readError: Error?
    private var closingMetadata: stat?
    init(_ file: URL) throws {
        guard file.isFileURL, file.pathExtension.lowercased() == "xml" else {
            throw GoalongHealthImport.invalid("Décompressez l’export Santé sur votre Mac et choisissez export.xml.")
        }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GoalongHealthImport.invalid("Le fichier Santé sélectionné ne peut pas être ouvert.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 2 * 1024 * 1024 * 1024 else {
            Darwin.close(fd)
            throw GoalongHealthImport.invalid("Choisissez un fichier XML ordinaire de moins de 2 Go, sans lien symbolique.")
        }
        descriptor = fd; metadata = info
        super.init(data: Data())
    }
    override func open() {}
    override func close() {
        if !closed {
            var info = stat()
            if fstat(descriptor, &info) == 0 { closingMetadata = info }
            Darwin.close(descriptor); closed = true
        }
    }
    deinit { close() }
    override var hasBytesAvailable: Bool { !closed && !atEnd && readError == nil }
    override var streamStatus: Stream.Status { closed ? .closed : (readError != nil ? .error : (atEnd ? .atEnd : .open)) }
    override var streamError: Error? { readError }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard !closed else { return -1 }
        var count: Int
        repeat { count = Darwin.read(descriptor, buffer, len) } while count < 0 && errno == EINTR
        if count == 0 { atEnd = true }
        if count < 0 { readError = GoalongHealthImport.invalid("Lecture du fichier Santé interrompue.") }
        return count
    }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length len: UnsafeMutablePointer<Int>) -> Bool { false }
    func validateUnchanged() throws {
        var after = stat()
        let available: Bool
        if closed { if let closingMetadata { after = closingMetadata; available = true } else { available = false } }
        else { available = fstat(descriptor, &after) == 0 }
        guard available, metadata.st_size == after.st_size,
              metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw GoalongHealthImport.invalid("Le fichier Santé a changé pendant la lecture. Recommencez avec un export terminé.")
        }
    }
}

private struct HealthDefinition {
    let key: String, unit: String
    let group: GoalongHealthGroup
    let mode: String
    let maximum: Double
}

private struct HealthSample {
    let definition: HealthDefinition
    let source: String
    let start: Date, end: Date
    let value: Double
}

private final class HealthXMLReader: NSObject, XMLParserDelegate {
    let options: GoalongHealthImportOptions
    var calendar: Calendar
    let start: Date, end: Date
    let dateParser: DateFormatter
    let dayFormatter: DateFormatter
    var isHealthExport = false
    var failure: GoalongSiteExportError?
    var samples: [HealthSample] = []
    var workouts: [[String: Any]] = []
    var pendingWorkout: [String: Any]?
    var exportDate: Date?
    var sources: [GoalongHealthGroup: Set<String>] = [:]
    var warnings = Set<String>()
    var seen = Set<String>()
    var elementCount = 0
    var depth = 0

    static let definitions: [String: HealthDefinition] = [
        "StepCount": .init(key: "steps", unit: "count", group: .activity, mode: "sum", maximum: 300_000),
        "DistanceWalkingRunning": .init(key: "walkingRunningMeters", unit: "m", group: .activity, mode: "sum", maximum: 1_000_000),
        "DistanceCycling": .init(key: "cyclingMeters", unit: "m", group: .activity, mode: "sum", maximum: 2_000_000),
        "ActiveEnergyBurned": .init(key: "activeEnergyKcal", unit: "kcal", group: .activity, mode: "sum", maximum: 50_000),
        "AppleExerciseTime": .init(key: "exerciseSeconds", unit: "s", group: .activity, mode: "sum", maximum: 90_000),
        "AppleStandTime": .init(key: "standSeconds", unit: "s", group: .activity, mode: "sum", maximum: 90_000),
        "FlightsClimbed": .init(key: "flights", unit: "count", group: .activity, mode: "sum", maximum: 30_000),
        "HeartRate": .init(key: "heartRateBPM", unit: "bpm", group: .heart, mode: "mean", maximum: 350),
        "RestingHeartRate": .init(key: "restingHeartRateBPM", unit: "bpm", group: .heart, mode: "mean", maximum: 350),
        "WalkingHeartRateAverage": .init(key: "walkingHeartRateBPM", unit: "bpm", group: .heart, mode: "mean", maximum: 350),
        "HeartRateVariabilitySDNN": .init(key: "heartRateVariabilityMS", unit: "ms", group: .heart, mode: "mean", maximum: 3000),
        "RespiratoryRate": .init(key: "respiratoryRate", unit: "count/min", group: .heart, mode: "mean", maximum: 150),
        "OxygenSaturation": .init(key: "oxygenPercent", unit: "%", group: .heart, mode: "mean", maximum: 100),
        "VO2Max": .init(key: "vo2Max", unit: "mL/kg/min", group: .heart, mode: "mean", maximum: 150),
    ]

    init(_ options: GoalongHealthImportOptions) throws {
        self.options = options
        var cal = Calendar(identifier: .gregorian); cal.timeZone = options.timezone
        calendar = cal; start = cal.startOfDay(for: options.from)
        guard let finish = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: options.through)),
              finish > start, cal.dateComponents([.day], from: start, to: finish).day! <= 366,
              !options.groups.isEmpty else { throw GoalongHealthImport.invalid("Choisissez des données et une période de 1 à 366 jours.") }
        end = finish
        dateParser = DateFormatter(); dateParser.locale = Locale(identifier: "en_US_POSIX")
        dateParser.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; dateParser.isLenient = false
        dayFormatter = DateFormatter(); dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = cal; dayFormatter.timeZone = options.timezone; dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    func fail(_ parser: XMLParser, _ message: String) { failure = GoalongHealthImport.invalid(message); parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, "Les déclarations d’entités XML personnalisées ne sont pas acceptées.")
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, "Les références XML externes ne sont pas acceptées.")
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, "Les références XML externes ne sont pas acceptées."); return nil
    }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String]) {
        depth += 1; elementCount += 1
        if Task<Never, Never>.isCancelled { fail(parser, "Lecture annulée. Aucune donnée n’a été envoyée."); return }
        guard depth <= 32, elementCount <= 12_000_000, samples.count + workouts.count < 500_000,
              a.values.allSatisfy({ $0.utf8.count <= 16_384 }) else {
            fail(parser, "Cet export dépasse les limites de lecture. Réduisez la période sélectionnée."); return
        }
        if depth == 1 { isHealthExport = element == "HealthData"; if !isHealthExport { fail(parser, "Ce fichier n’est pas un export Apple Santé.") }; return }
        if depth == 2, element == "ExportDate" { exportDate = a["value"].flatMap(dateParser.date(from:)); return }
        if depth == 3, element == "WorkoutStatistics", pendingWorkout != nil {
            if a["type"] == "HKQuantityTypeIdentifierActiveEnergyBurned", let n = converted(a["sum"], a["unit"], to: "kcal"), n <= 50_000 { pendingWorkout?["energyKcal"] = n }
            if ["HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierDistanceCycling", "HKQuantityTypeIdentifierDistanceSwimming"].contains(a["type"] ?? ""), let n = converted(a["sum"], a["unit"], to: "m"), n <= 2_000_000 { pendingWorkout?["distanceMeters"] = n }
            return
        }
        if element == "Record" {
            let type = a["type"] ?? ""
            let group = type == "HKCategoryTypeIdentifierSleepAnalysis" ? GoalongHealthGroup.sleep : Self.definitions[type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")]?.group
            guard let group, options.groups.contains(group) else { return }
        }
        guard depth == 2, element == "Record" || element == "Workout",
              let from = a["startDate"].flatMap(dateParser.date(from:)),
              let through = a["endDate"].flatMap(dateParser.date(from:)), through >= from,
              from < end, through >= start, through.timeIntervalSince(from) <= 7 * 86_400 else { return }
        var name = String(String.UnicodeScalarView((a["sourceName"] ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        // The exchange contract bounds UTF-16 length, including emoji in device names.
        while name.utf16.count > 100 { name.removeLast() }
        let source = name.isEmpty ? "Source non précisée" : name
        if element == "Workout" {
            guard options.groups.contains(.workouts), from >= start,
                  let duration = converted(a["duration"], a["durationUnit"], to: "s"), duration <= 604_800,
                  duration <= through.timeIntervalSince(from) + 60 else { return }
            sources[.workouts, default: []].insert(source)
            let reportedSport = a["workoutActivityType"] ?? "HKWorkoutActivityTypeOther"
            let sport = reportedSport.range(of: #"^HKWorkoutActivityType[A-Za-z]{1,70}$"#, options: .regularExpression) != nil
                ? reportedSport : "HKWorkoutActivityTypeOther"
            let identity = "\(source)|\(sport)|\(from.timeIntervalSince1970)|\(through.timeIntervalSince1970)"
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert("workout:" + digest).inserted else { return }
            pendingWorkout = ["id": digest, "sport": sport, "source": source,
                "startedAt": ISO8601DateFormatter().string(from: from), "endedAt": ISO8601DateFormatter().string(from: through),
                "durationSeconds": duration, "distanceMeters": boundedWorkoutValue(a["totalDistance"], a["totalDistanceUnit"], to: "m", maximum: 2_000_000) as Any? ?? NSNull(),
                "energyKcal": boundedWorkoutValue(a["totalEnergyBurned"], a["totalEnergyBurnedUnit"], to: "kcal", maximum: 50_000) as Any? ?? NSNull(),
                "date": dayFormatter.string(from: from)]
            return
        }
        let type = a["type"] ?? ""
        let definition: HealthDefinition
        let value: Double
        if type == "HKCategoryTypeIdentifierSleepAnalysis" {
            let stages = ["HKCategoryValueSleepAnalysisInBed": "inBedSeconds", "HKCategoryValueSleepAnalysisAwake": "awakeSeconds",
                "HKCategoryValueSleepAnalysisAsleep": "sleepUnspecifiedSeconds", "HKCategoryValueSleepAnalysisAsleepUnspecified": "sleepUnspecifiedSeconds",
                "HKCategoryValueSleepAnalysisAsleepCore": "sleepCoreSeconds", "HKCategoryValueSleepAnalysisAsleepDeep": "sleepDeepSeconds", "HKCategoryValueSleepAnalysisAsleepREM": "sleepREMSeconds"]
            guard let key = stages[a["value"] ?? ""], through > from else { return }
            definition = .init(key: key, unit: "s", group: .sleep, mode: "union", maximum: 90_000); value = 0
        } else {
            guard let d = Self.definitions[type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")],
                  let n = converted(a["value"], a["unit"], to: d.unit), n <= d.maximum else { return }
            definition = d; value = n
        }
        guard options.groups.contains(definition.group) else { return }
        sources[definition.group, default: []].insert(source)
        let identity = "\(type)|\(a["value"] ?? "")|\(source)|\(from.timeIntervalSince1970)|\(through.timeIntervalSince1970)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        guard seen.insert(hash).inserted else { return }
        samples.append(.init(definition: definition, source: source, start: from, end: through, value: value))
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName qName: String?) {
        if element == "Workout", let workout = pendingWorkout { workouts.append(workout); pendingWorkout = nil }
        depth -= 1
    }

    func converted(_ raw: String?, _ unit: String?, to target: String) -> Double? {
        guard let raw, let n = Double(raw), n.isFinite, n >= 0, let unit else { return nil }
        let factors: [String: [String: Double]] = ["count": ["count": 1], "s": ["s": 1, "min": 60, "hr": 3600],
            "m": ["m": 1, "km": 1000, "mi": 1609.344], "kcal": ["kcal": 1, "kJ": 1 / 4.184, "cal": 0.001],
            "bpm": ["count/min": 1], "count/min": ["count/min": 1], "ms": ["ms": 1, "s": 1000],
            "%": ["%": 100], "mL/kg/min": ["mL/min·kg": 1, "ml/kg*min": 1, "mL/kg/min": 1]]
        guard let factor = factors[target]?[unit] else { warnings.insert("Certaines unités inconnues ont été ignorées."); return nil }
        let result = n * factor
        return result.isFinite ? result : nil
    }

    func boundedWorkoutValue(_ raw: String?, _ unit: String?, to target: String, maximum: Double) -> Double? {
        guard let value = converted(raw, unit, to: target) else { return nil }
        guard value <= maximum else {
            warnings.insert("Une distance ou une énergie d’entraînement hors limites a été ignorée.")
            return nil
        }
        return value
    }

    func result() throws -> GoalongHealthImportResult {
        var byDay: [String: [HealthSample]] = [:]
        for sample in samples {
            if sample.definition.mode == "union" {
                var cursor = max(start, sample.start)
                while cursor < min(end, sample.end) {
                    let next = min(calendar.dateInterval(of: .day, for: cursor)!.end, sample.end, end)
                    byDay[dayFormatter.string(from: cursor), default: []].append(.init(definition: sample.definition,
                        source: sample.source, start: cursor, end: next, value: next.timeIntervalSince(cursor)))
                    cursor = next
                }
            } else if sample.start >= start {
                // Cumulative samples crossing midnight cannot be split without inventing
                // timing. Exclude them and make the loss visible rather than prorating.
                let dayEnd = calendar.dateInterval(of: .day, for: sample.start)!.end
                if sample.definition.mode == "sum", sample.end > dayEnd {
                    warnings.insert("Des mesures cumulées chevauchant minuit ont été ignorées."); continue
                }
                byDay[dayFormatter.string(from: sample.start), default: []].append(sample)
            }
        }
        let dates = Set(byDay.keys).union(workouts.compactMap { $0["date"] as? String }).sorted()
        var metricCount = 0, workoutCount = 0
        let days: [[String: Any]] = try dates.compactMap { day in
            let entries = byDay[day] ?? []
            var metrics: [[String: Any]] = []
            for group in GoalongHealthGroup.allCases where group != .workouts {
                let grouped = entries.filter { $0.definition.group == group }
                let counts = Dictionary(grouping: grouped, by: \.source).mapValues(\.count)
                let source = options.preferredSources[group] ?? counts.keys.sorted { counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! > counts[$1]! }.first
                let chosen = grouped.filter { $0.source == source }
                if counts.count > 1 { warnings.insert("Une seule source est retenue par groupe et par jour pour éviter le double comptage. Vous pouvez choisir la source.") }
                var keyed = Dictionary(grouping: chosen, by: { $0.definition.key })
                let asleep = chosen.filter { $0.definition.key.hasPrefix("sleep") }
                if !asleep.isEmpty { keyed["sleepSeconds"] = asleep }
                for key in keyed.keys.sorted() {
                    let values = keyed[key]!.sorted { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
                    let definition = values[0].definition
                    var number = 0.0
                    if definition.mode == "mean" { number = values.map(\.value).reduce(0, +) / Double(values.count) }
                    else {
                        var last: Date?
                        for sample in values {
                            if definition.mode == "union" {
                                number += max(0, sample.end.timeIntervalSince(max(sample.start, last ?? sample.start)))
                                last = max(last ?? sample.end, sample.end)
                            } else if let last, sample.start < last {
                                warnings.insert("Des mesures cumulées qui se chevauchent ont été ignorées.")
                            } else { number += sample.value; last = sample.end }
                        }
                    }
                    guard number.isFinite, number <= definition.maximum else { throw GoalongHealthImport.invalid("Un total Santé dépasse les limites. Sélectionnez une autre source.") }
                    metrics.append(["key": key, "value": rounded(number), "unit": definition.unit,
                        "source": source ?? "Source non précisée", "sampleCount": values.count,
                        "aggregation": definition.mode == "union" ? "interval-union" : (definition.mode == "mean" ? "sample-mean" : "sum-nonoverlapping")])
                    if key == "heartRateBPM" {
                        for (extra, v) in [("heartRateMinBPM", values.map(\.value).min()!), ("heartRateMaxBPM", values.map(\.value).max()!)] {
                            metrics.append(["key": extra, "value": rounded(v), "unit": "bpm", "source": source!, "sampleCount": values.count, "aggregation": extra.contains("Min") ? "sample-min" : "sample-max"])
                        }
                    }
                }
            }
            var dayWorkouts = workouts.filter { $0["date"] as? String == day }
            if let preferred = options.preferredSources[.workouts] { dayWorkouts = dayWorkouts.filter { $0["source"] as? String == preferred } }
            else {
                let counts = Dictionary(grouping: dayWorkouts, by: { $0["source"] as! String }).mapValues(\.count)
                let selected = counts.keys.sorted { counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! > counts[$1]! }.first
                dayWorkouts = dayWorkouts.filter { $0["source"] as? String == selected }
                if counts.count > 1 { warnings.insert("Une seule source d’entraînements est retenue par jour ; choisissez-la si nécessaire.") }
            }
            guard dayWorkouts.count <= 100 else { throw GoalongHealthImport.invalid("Plus de 100 entraînements dans une journée. Sélectionnez une autre source.") }
            dayWorkouts = dayWorkouts.map { var w = $0; w.removeValue(forKey: "date"); return w }
            guard !metrics.isEmpty || !dayWorkouts.isEmpty else { return nil }
            metricCount += metrics.count; workoutCount += dayWorkouts.count
            return ["date": day, "title": "Santé et activité du \(day)", "summary": "", "outcomes": [], "activities": [],
                "health": ["version": 1, "coverage": "partial", "metrics": metrics, "workouts": dayWorkouts],
                "telemetry": ["timezone": options.timezone.identifier, "receivedAt": ISO8601DateFormatter().string(from: exportDate ?? entries.map(\.end).max() ?? end),
                    "state": day < dayFormatter.string(from: Date()) ? "completed" : "in-progress", "devices": [], "websites": NSNull(), "agent": NSNull()]]
        }
        guard !days.isEmpty else { throw GoalongHealthImport.invalid("Aucune donnée compatible pour ces dates et ces sources. Vérifiez votre sélection et l’export Santé.") }
        let payload = try JSONSerialization.data(withJSONObject: ["version": 2, "source": "apple-health", "days": days], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        guard payload.count <= 2 * 1024 * 1024 else { throw GoalongHealthImport.invalid("L’aperçu dépasse 2 Mo. Réduisez la période sélectionnée.") }
        return .init(payload: payload, dayCount: days.count, metricCount: metricCount, workoutCount: workoutCount,
                     sources: sources.mapValues { $0.sorted() }, warnings: warnings.sorted())
    }
    func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
