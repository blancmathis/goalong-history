#if os(macOS)
    import AppKit
    import ApplicationServices
    import AppleScreenTime
    import Foundation

    protocol AppleSettingsScreenTimeOracleProviding: AnyObject {
        var lastFailureDescription: String? { get }

        func collect(
            dayInterval: DateInterval,
            currentMac: AppleScreenTimeDevice,
            now: Date,
            calendar: Calendar
        ) -> AppleSystemScreenTimeCollection?
    }

    struct AppleSettingsUsagePresentation: Equatable {
        struct Row: Equatable {
            let name: String
            let duration: TimeInterval
        }

        let total: TimeInterval
        let rows: [Row]
    }

    struct AppleSettingsDeviceUsagePresentation: Equatable {
        let name: String
        let usage: AppleSettingsUsagePresentation
    }

    struct AppleSettingsScreenTimePresentation: Equatable {
        let allDevices: AppleSettingsUsagePresentation
        let devices: [AppleSettingsDeviceUsagePresentation]
        let readAt: Date
    }

    protocol AppleSettingsScreenTimePresentationReading: AnyObject {
        func read(
            dayInterval: DateInterval,
            now: Date,
            calendar: Calendar
        ) throws -> AppleSettingsScreenTimePresentation
    }

    enum AppleSettingsScreenTimeOracleError: Error, CustomStringConvertible, Equatable {
        case accessibilityUnavailable
        case futureDay
        case dayOutsideBoundedHistory(Int)
        case activityViewUnavailable(String)
        case dateNavigationUnavailable(String)
        case deviceMenuUnavailable(String)
        case usageModeUnavailable(String)
        case usageUnavailable(String)

        var description: String {
            switch self {
            case .accessibilityUnavailable:
                return "Accessibility permission is unavailable."
            case .futureDay:
                return "Apple Screen Time cannot display a future day."
            case .dayOutsideBoundedHistory(let maximum):
                return "The requested day is more than \(maximum) days in the past."
            case .activityViewUnavailable(let detail):
                return "Apple’s App & Website Activity view could not be opened (\(detail))."
            case .dateNavigationUnavailable(let detail):
                return "Apple’s Screen Time date controls could not be read (\(detail))."
            case .deviceMenuUnavailable(let detail):
                return "Apple’s Screen Time device menu could not be read (\(detail))."
            case .usageModeUnavailable(let detail):
                return "Apple’s Screen Time application view could not be selected (\(detail))."
            case .usageUnavailable(let device):
                return "Apple’s visible usage rows could not be read for \(device)."
            }
        }
    }

    /// Reads the values that Apple itself currently renders in System Settings.
    ///
    /// This is deliberately a presentation oracle, not a private database reader. It performs
    /// bounded accessibility reads only while the Screen Time surface is requested, retains a
    /// small in-memory cache, and never stores screenshots or Apple transcript-like snapshots.
    final class AppleSettingsScreenTimeOracle: AppleSettingsScreenTimeOracleProviding {
        static let production = AppleSettingsScreenTimeOracle()

        private struct CacheKey: Hashable {
            let dayStart: Int64
            let timeZoneIdentifier: String
        }

        private struct CacheEntry {
            let presentation: AppleSettingsScreenTimePresentation
            let cachedAt: Date
        }

        private let reader: AppleSettingsScreenTimePresentationReading
        private let lock = NSLock()
        private var cache: [CacheKey: CacheEntry] = [:]
        private var failureDescription: String?
        private let maximumCachedDays: Int

        init(
            reader: AppleSettingsScreenTimePresentationReading = AppleSettingsAccessibilityReader(),
            maximumCachedDays: Int = 8
        ) {
            self.reader = reader
            self.maximumCachedDays = max(1, maximumCachedDays)
        }

        func collect(
            dayInterval: DateInterval,
            currentMac: AppleScreenTimeDevice,
            now: Date,
            calendar: Calendar
        ) -> AppleSystemScreenTimeCollection? {
            let key = CacheKey(
                dayStart: Int64(dayInterval.start.timeIntervalSince1970.rounded()),
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            let isToday = calendar.isDate(dayInterval.start, inSameDayAs: now)
            let freshness: TimeInterval = isToday ? 15 : 60
            if let cached = cachedPresentation(for: key, now: now, freshness: freshness) {
                setFailureDescription(nil)
                return makeCollection(
                    from: cached,
                    dayInterval: dayInterval,
                    currentMac: currentMac
                )
            }

            let readResult: Result<AppleSettingsScreenTimePresentation, Error>
            if Thread.isMainThread {
                readResult = readAndCachePresentation(
                    for: key,
                    dayInterval: dayInterval,
                    now: now,
                    calendar: calendar,
                    freshness: freshness
                )
            } else {
                readResult = DispatchQueue.main.sync {
                    self.readAndCachePresentation(
                        for: key,
                        dayInterval: dayInterval,
                        now: now,
                        calendar: calendar,
                        freshness: freshness
                    )
                }
            }
            let presentation: AppleSettingsScreenTimePresentation
            switch readResult {
            case .success(let value):
                presentation = value
            case .failure(let error):
                setFailureDescription("Apple Settings visible read failed: \(error)")
                return nil
            }

            let collection = makeCollection(
                from: presentation,
                dayInterval: dayInterval,
                currentMac: currentMac
            )
            setFailureDescription(nil)
            return collection
        }

        var lastFailureDescription: String? {
            lock.lock()
            defer { lock.unlock() }
            return failureDescription
        }

        var cachedDayCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return cache.count
        }

        private func readAndCachePresentation(
            for key: CacheKey,
            dayInterval: DateInterval,
            now: Date,
            calendar: Calendar,
            freshness: TimeInterval
        ) -> Result<AppleSettingsScreenTimePresentation, Error> {
            if let cached = cachedPresentation(for: key, now: now, freshness: freshness) {
                return .success(cached)
            }
            return Result {
                let presentation = try reader.read(
                    dayInterval: dayInterval,
                    now: now,
                    calendar: calendar
                )
                cachePresentation(presentation, for: key, at: now)
                return presentation
            }
        }

        private func cachedPresentation(
            for key: CacheKey,
            now: Date,
            freshness: TimeInterval
        ) -> AppleSettingsScreenTimePresentation? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = cache[key], now.timeIntervalSince(entry.cachedAt) <= freshness else {
                cache.removeValue(forKey: key)
                return nil
            }
            return entry.presentation
        }

        private func cachePresentation(
            _ presentation: AppleSettingsScreenTimePresentation,
            for key: CacheKey,
            at date: Date
        ) {
            lock.lock()
            cache[key] = CacheEntry(presentation: presentation, cachedAt: date)
            if cache.count > maximumCachedDays {
                let overflow = cache.count - maximumCachedDays
                let oldest = cache.sorted { $0.value.cachedAt < $1.value.cachedAt }.prefix(overflow)
                for item in oldest { cache.removeValue(forKey: item.key) }
            }
            lock.unlock()
        }

        private func setFailureDescription(_ value: String?) {
            lock.lock()
            failureDescription = value
            lock.unlock()
        }

        private func makeCollection(
            from presentation: AppleSettingsScreenTimePresentation,
            dayInterval: DateInterval,
            currentMac: AppleScreenTimeDevice
        ) -> AppleSystemScreenTimeCollection {
            var availableDevices: [AppleScreenTimeDevice] = []
            var reports: [AppleScreenTimeDeviceReport] = []
            var labels: [String: String] = [:]

            for deviceUsage in presentation.devices {
                let inferredKind = AppleScreenTimeDeviceIdentityResolver.deviceKind(
                    model: nil,
                    name: deviceUsage.name
                )
                let device: AppleScreenTimeDevice
                if inferredKind == .mac {
                    device = AppleScreenTimeDevice(
                        id: currentMac.id,
                        name: deviceUsage.name,
                        kind: .mac
                    )
                } else {
                    device = AppleScreenTimeDevice(
                        id: Self.deviceIdentifier(kind: inferredKind, name: deviceUsage.name),
                        name: deviceUsage.name,
                        kind: inferredKind
                    )
                }
                availableDevices.append(device)
                labels[device.id] = "Apple Settings · visible \(device.displayName) values"
                reports.append(
                    Self.report(
                        device: device,
                        usage: deviceUsage.usage,
                        dayInterval: dayInterval,
                        readAt: presentation.readAt
                    )
                )
            }

            let aggregateDevice = AppleScreenTimeDevice(
                id: AppleScreenTimeProvenance.appleSettingsAllDevicesReportID,
                name: "All Devices",
                kind: .unknown
            )
            reports.append(
                Self.report(
                    device: aggregateDevice,
                    usage: presentation.allDevices,
                    dayInterval: dayInterval,
                    readAt: presentation.readAt
                )
            )

            let info = Bundle.main.infoDictionary
            let provenance = AppleScreenTimeProvenance(
                api: AppleScreenTimeProvenance.appleSettingsAccessibilityAPI,
                collectorBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                collectorVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                collectorPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let stored = AppleScreenTimeStoredExport(
                importedAt: presentation.readAt,
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    createdAt: presentation.readAt,
                    requestedStart: dayInterval.start,
                    requestedEnd: dayInterval.end,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: reports
                )
            )
            return AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: availableDevices,
                status: AppleSystemScreenTimeStatus(
                    kind: .ready,
                    title: "Matches Apple Screen Time",
                    message: "Goalong read the values currently displayed by Apple System Settings for this day and every listed device. The read stayed local and no screenshot or Apple usage database was stored."
                ),
                deviceSourceLabels: labels,
                latestAppleUpdate: presentation.readAt,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0,
                screenTimeAppUsageIntervalCount: 0
            )
        }

        private static func report(
            device: AppleScreenTimeDevice,
            usage: AppleSettingsUsagePresentation,
            dayInterval: DateInterval,
            readAt: Date
        ) -> AppleScreenTimeDeviceReport {
            let maximumDuration = max(1, dayInterval.duration)
            let largestApplication = usage.rows.map(\.duration).max() ?? 0
            let segmentCount = max(
                1,
                Int(ceil(max(usage.total, largestApplication) / maximumDuration))
            )
            let applications = usage.rows.enumerated().map { index, row in
                AppleScreenTimeApplicationUsage(
                    bundleIdentifier: applicationIdentifier(
                        name: row.name,
                        deviceID: device.id,
                        rowIndex: index
                    ),
                    displayName: row.name,
                    duration: row.duration
                )
            }
            let segments = (0 ..< segmentCount).map { index in
                AppleScreenTimeSegment(
                    start: dayInterval.start,
                    end: dayInterval.end,
                    totalScreenOnDuration: chunk(
                        usage.total,
                        index: index,
                        maximum: maximumDuration
                    ),
                    applications: applications.compactMap { application in
                        let duration = chunk(
                            application.duration,
                            index: index,
                            maximum: maximumDuration
                        )
                        guard duration > 0 else { return nil }
                        return AppleScreenTimeApplicationUsage(
                            bundleIdentifier: application.bundleIdentifier,
                            displayName: application.displayName,
                            duration: duration
                        )
                    }
                )
            }
            return AppleScreenTimeDeviceReport(
                device: device,
                lastUpdatedAt: readAt,
                segments: segments
            )
        }

        private static func chunk(
            _ value: TimeInterval,
            index: Int,
            maximum: TimeInterval
        ) -> TimeInterval {
            min(maximum, max(0, value - (Double(index) * maximum)))
        }

        private static func applicationIdentifier(
            name: String,
            deviceID: String,
            rowIndex: Int
        ) -> String {
            let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.range(of: #"^[a-z0-9](?:[a-z0-9-]*\.)+[a-z]{2,}$"#, options: .regularExpression) != nil {
                return "website:\(lower)"
            }
            return "apple-settings:\(deviceID):row:\(rowIndex):\(stableTag(lower))"
        }

        private static func deviceIdentifier(
            kind: AppleScreenTimeDeviceKind,
            name: String
        ) -> String {
            "apple-settings:\(kind.rawValue):\(stableTag(name.lowercased()))"
        }

        private static func stableTag(_ value: String) -> String {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(format: "%016llx", hash)
        }
    }

    enum AppleSettingsScreenTimeParser {
        static func duration(from source: String, locale: Locale = .current) -> TimeInterval? {
            let normalized = source
                .lowercased(with: locale)
                .replacingOccurrences(of: "\u{202f}", with: " ")
                .replacingOccurrences(of: "\u{00a0}", with: " ")
            let unitValues = localizedUnitValues(locale: locale)
            guard let expression = try? NSRegularExpression(
                pattern: #"([0-9][0-9\s.,]*)\s*([\p{L}\p{M}.]+)"#,
                options: []
            ) else { return nil }
            let range = NSRange(normalized.startIndex ..< normalized.endIndex, in: normalized)
            var total: TimeInterval = 0
            var matched = false
            for match in expression.matches(in: normalized, options: [], range: range) {
                guard match.numberOfRanges == 3,
                      let numberRange = Range(match.range(at: 1), in: normalized),
                      let unitRange = Range(match.range(at: 2), in: normalized)
                else { continue }
                let digits = normalized[numberRange].filter(\.isNumber)
                guard let number = Double(digits) else { continue }
                let unit = normalizeUnit(String(normalized[unitRange]))
                guard let multiplier = unitValues[unit] else { continue }
                total += number * multiplier
                matched = true
            }
            return matched ? total : nil
        }

        static func usageRow(
            from source: String,
            locale: Locale = .current
        ) -> AppleSettingsUsagePresentation.Row? {
            let lines = source
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { return nil }
            for index in stride(from: lines.count - 1, through: 1, by: -1) {
                guard let duration = duration(from: lines[index], locale: locale) else { continue }
                let name = lines[..<index].joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return AppleSettingsUsagePresentation.Row(name: name, duration: duration)
            }
            return nil
        }

        private static func localizedUnitValues(locale: Locale) -> [String: TimeInterval] {
            var result: [String: TimeInterval] = [
                "d": 86_400, "day": 86_400, "days": 86_400,
                "jour": 86_400, "jours": 86_400,
                "h": 3_600, "hr": 3_600, "hrs": 3_600,
                "hour": 3_600, "hours": 3_600, "heure": 3_600, "heures": 3_600,
                "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
                "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
                "seconde": 1, "secondes": 1,
            ]
            let units: [(Calendar.Component, TimeInterval)] = [
                (.day, 86_400), (.hour, 3_600), (.minute, 60), (.second, 1),
            ]
            for (component, multiplier) in units {
                for quantity in [1, 2] {
                    var components = DateComponents()
                    components.setValue(quantity, for: component)
                    let formatter = DateComponentsFormatter()
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.unitsStyle = .full
                    formatter.allowedUnits = calendarUnit(for: component)
                    formatter.maximumUnitCount = 1
                    formatter.zeroFormattingBehavior = .dropAll
                    guard let rendered = formatter.string(from: components) else { continue }
                    let token = rendered
                        .lowercased(with: locale)
                        .components(separatedBy: CharacterSet.letters.inverted)
                        .filter { !$0.isEmpty }
                        .last
                    if let token { result[normalizeUnit(token)] = multiplier }
                }
            }
            return result
        }

        private static func calendarUnit(for component: Calendar.Component) -> NSCalendar.Unit {
            switch component {
            case .day: return .day
            case .hour: return .hour
            case .minute: return .minute
            default: return .second
            }
        }

        private static func normalizeUnit(_ value: String) -> String {
            value.trimmingCharacters(in: CharacterSet.letters.inverted)
        }
    }

    enum AppleSettingsScreenTimeDateParser {
        static func dayDistance(
            from source: String,
            now: Date,
            calendar: Calendar
        ) -> Int? {
            let normalized = source
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            if normalized.contains("today")
                || normalized.contains("aujourd'hui")
                || normalized.contains("aujourdhui")
                || normalized.contains("hoy")
                || normalized.contains("heute")
            {
                return 0
            }
            if normalized.contains("yesterday")
                || normalized.contains("hier")
                || normalized.contains("ayer")
                || normalized.contains("gestern")
            {
                return 1
            }

            let today = calendar.startOfDay(for: now)
            let currentYear = calendar.component(.year, from: today)
            let candidates = [
                source.trimmingCharacters(in: .whitespacesAndNewlines),
                String(source.drop(while: { !$0.isNumber })),
            ]
            .filter { !$0.isEmpty }
            let locales = [
                Locale.current,
                Locale(identifier: "en_GB"),
                Locale(identifier: "en_US"),
                Locale(identifier: "fr_FR"),
                Locale(identifier: "es_ES"),
                Locale(identifier: "de_DE"),
            ]
            let formats = [
                "EEEE d MMMM", "EEEE, d MMMM", "EEEE, d MMMM yyyy",
                "EEEE, d. MMMM", "EEEE, d. MMMM yyyy",
                "EEEE, d 'de' MMMM", "EEEE, d 'de' MMMM yyyy",
                "d MMMM", "d MMMM yyyy", "d. MMMM", "d. MMMM yyyy",
                "d 'de' MMMM", "d 'de' MMMM yyyy",
                "EEEE MMMM d", "EEEE, MMMM d", "EEEE, MMMM d, yyyy",
                "MMMM d", "MMMM d, yyyy", "M/d/yyyy", "dd/MM/yyyy", "yyyy-MM-dd",
            ]

            for locale in locales {
                for format in formats {
                    let formatter = DateFormatter()
                    formatter.calendar = calendar
                    formatter.locale = locale
                    formatter.timeZone = calendar.timeZone
                    formatter.isLenient = false
                    formatter.dateFormat = format
                    for candidate in candidates {
                        guard let parsed = formatter.date(from: candidate) else { continue }
                        let components = calendar.dateComponents([.year, .month, .day], from: parsed)
                        guard let month = components.month, let day = components.day else { continue }
                        let containsYear = format.contains("y")
                        var year = containsYear ? (components.year ?? currentYear) : currentYear
                        guard var resolved = calendar.date(
                            from: DateComponents(year: year, month: month, day: day)
                        ) else { continue }
                        if resolved > today, !containsYear {
                            year -= 1
                            guard let previousYear = calendar.date(
                                from: DateComponents(year: year, month: month, day: day)
                            ) else { continue }
                            resolved = previousYear
                        }
                        guard resolved <= today else { continue }
                        return calendar.dateComponents([.day], from: resolved, to: today).day
                    }
                }
            }
            return nil
        }
    }

    final class AppleSettingsAccessibilityReader: AppleSettingsScreenTimePresentationReading {
        private struct UsageModeRestoration {
            let title: String
            let index: Int
        }

        private enum Attribute {
            static let children = "AXChildren" as CFString
            static let windows = "AXWindows" as CFString
            static let parent = "AXParent" as CFString
            static let role = "AXRole" as CFString
            static let title = "AXTitle" as CFString
            static let value = "AXValue" as CFString
            static let description = "AXDescription" as CFString
            static let identifier = "AXIdentifier" as CFString
            static let position = "AXPosition" as CFString
            static let size = "AXSize" as CFString
        }

        private let bundleIdentifier = "com.apple.systempreferences"
        private let maximumHistoryDays: Int
        private let maximumNodes: Int
        private let launchTimeout: TimeInterval
        private let updateTimeout: TimeInterval

        init(
            maximumHistoryDays: Int = 35,
            maximumNodes: Int = 1_500,
            launchTimeout: TimeInterval = 10,
            updateTimeout: TimeInterval = 2
        ) {
            self.maximumHistoryDays = max(1, maximumHistoryDays)
            self.maximumNodes = max(100, maximumNodes)
            self.launchTimeout = max(1, launchTimeout)
            self.updateTimeout = max(0.2, updateTimeout)
        }

        func read(
            dayInterval: DateInterval,
            now: Date,
            calendar: Calendar
        ) throws -> AppleSettingsScreenTimePresentation {
            guard AXIsProcessTrusted() else {
                throw AppleSettingsScreenTimeOracleError.accessibilityUnavailable
            }
            let today = calendar.startOfDay(for: now)
            let requestedDay = calendar.startOfDay(for: dayInterval.start)
            guard requestedDay <= today else {
                throw AppleSettingsScreenTimeOracleError.futureDay
            }
            let dayDistance = calendar.dateComponents([.day], from: requestedDay, to: today).day ?? 0
            guard dayDistance <= maximumHistoryDays else {
                throw AppleSettingsScreenTimeOracleError.dayOutsideBoundedHistory(maximumHistoryDays)
            }

            let previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
            activateSystemSettings()
            defer {
                if let previousFrontmostApplication,
                   previousFrontmostApplication.bundleIdentifier != bundleIdentifier,
                   NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
                {
                    _ = previousFrontmostApplication.activate(options: [.activateIgnoringOtherApps])
                }
            }

            guard let application = ensureActivityApplication() else {
                throw AppleSettingsScreenTimeOracleError.activityViewUnavailable(
                    activityViewDiagnostic()
                )
            }
            let originalDeviceName = activityWindow(in: application)
                .flatMap { devicePopup(in: $0) }
                .flatMap { normalizedValue(of: $0) }
            let originalDayValue = activityWindow(in: application)
                .flatMap { datePopup(in: $0) }
                .flatMap { string($0, attribute: Attribute.value) }
            let originalDayDistance = originalDayValue.flatMap {
                AppleSettingsScreenTimeDateParser.dayDistance(
                    from: $0,
                    now: now,
                    calendar: calendar
                )
            }
            var restorationMenuTitles: [String] = []
            var usageModeRestoration: UsageModeRestoration?
            defer {
                if let originalDayValue {
                    try? restoreDate(
                        originalDayValue,
                        application: application,
                        now: now,
                        calendar: calendar
                    )
                }
                if let originalDeviceName,
                   let originalIndex = restorationMenuTitles.firstIndex(where: {
                       normalizedText($0) == originalDeviceName
                   })
                {
                    try? selectDevice(
                        at: originalIndex,
                        expectedTitle: restorationMenuTitles[originalIndex],
                        application: application
                    )
                }
                if let usageModeRestoration {
                    try? selectUsageMode(
                        at: usageModeRestoration.index,
                        expectedTitle: usageModeRestoration.title,
                        application: application
                    )
                }
            }
            if originalDayDistance != dayDistance {
                try navigateToToday(application: application)
                if dayDistance > 0 {
                    for _ in 0 ..< dayDistance {
                        try navigateBackwardOneDay(
                            application: application,
                            now: now,
                            calendar: calendar
                        )
                    }
                }
            }
            guard visibleDayDistance(application: application, now: now, calendar: calendar)
                == dayDistance
            else {
                let value = activityWindow(in: application)
                    .flatMap { datePopup(in: $0) }
                    .flatMap { string($0, attribute: Attribute.value) }
                    ?? "unknown"
                throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                    "expected day distance \(dayDistance), found \(value)"
                )
            }
            usageModeRestoration = try ensureApplicationsUsageMode(application: application)

            let menuTitles = try deviceMenuTitles(application: application)
            guard !menuTitles.isEmpty else {
                throw AppleSettingsScreenTimeOracleError.deviceMenuUnavailable("no menu title")
            }
            restorationMenuTitles = menuTitles

            try selectDevice(at: 0, expectedTitle: menuTitles[0], application: application)
            let allUsage = try readVisibleUsage(
                application: application,
                deviceName: menuTitles[0],
                minimumObservationInterval: 0.75
            )
            var devices: [AppleSettingsDeviceUsagePresentation] = []
            for index in menuTitles.indices.dropFirst() {
                let title = menuTitles[index]
                try selectDevice(at: index, expectedTitle: title, application: application)
                devices.append(
                    AppleSettingsDeviceUsagePresentation(
                        name: title,
                        usage: try readVisibleUsage(
                            application: application,
                            deviceName: title,
                            minimumObservationInterval: 0.75
                        )
                    )
                )
            }

            guard !devices.isEmpty else {
                throw AppleSettingsScreenTimeOracleError.deviceMenuUnavailable("no individual device")
            }
            return AppleSettingsScreenTimePresentation(
                allDevices: allUsage,
                devices: devices,
                readAt: Date()
            )
        }

        private func ensureActivityApplication() -> AXUIElement? {
            if let application = runningApplicationElement() {
                if activityWindow(in: application) != nil { return application }
                if pressActivityButton(in: application),
                   wait(until: { self.activityWindow(in: application) != nil })
                {
                    return application
                }
            }
            openScreenTimeActivityView()
            let deadline = Date().addingTimeInterval(launchTimeout)
            var activatedAfterLaunch = false
            var nextRootNavigationAttempt = Date()
            var reopenedDeepLink = false
            while Date() < deadline {
                if let application = runningApplicationElement() {
                    if !activatedAfterLaunch {
                        activateSystemSettings()
                        activatedAfterLaunch = true
                    }
                    if activityWindow(in: application) != nil { return application }
                    if Date() >= nextRootNavigationAttempt {
                        _ = pressActivityButton(in: application)
                        nextRootNavigationAttempt = Date().addingTimeInterval(0.75)
                    }
                }
                if !reopenedDeepLink,
                   deadline.timeIntervalSinceNow <= launchTimeout / 2
                {
                    openScreenTimeActivityView()
                    reopenedDeepLink = true
                }
                Thread.sleep(forTimeInterval: 0.10)
            }
            return nil
        }

        private func activateSystemSettings() {
            guard let settings = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first
            else { return }
            let activate = {
                _ = settings.activate(options: [.activateIgnoringOtherApps])
            }
            if Thread.isMainThread {
                activate()
            } else {
                DispatchQueue.main.sync(execute: activate)
            }
            _ = wait(timeout: min(1, launchTimeout)) {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == self.bundleIdentifier
            }
        }

        private func activityViewDiagnostic() -> String {
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            guard let process = running.first else { return "System Settings is not running" }
            let application = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(application, Float(min(2, updateTimeout)))
            let windows = applicationWindows(in: application)
            let titles = windows.compactMap { string($0, attribute: Attribute.title) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if windows.isEmpty {
                return "pid \(process.processIdentifier), no readable AX window"
            }
            if titles.isEmpty {
                return "pid \(process.processIdentifier), \(windows.count) AX window(s), no title"
            }
            return "pid \(process.processIdentifier), AX titles: \(titles.joined(separator: " | "))"
        }

        private func pressActivityButton(in application: AXUIElement) -> Bool {
            let buttons = applicationWindows(in: application)
                .flatMap { descendants(of: $0) }
                .filter { string($0, attribute: Attribute.role) == (kAXButtonRole as String) }
            guard let activity = buttons.first(where: { button in
                let label = [
                    string(button, attribute: Attribute.title),
                    string(button, attribute: Attribute.description),
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                let mentionsApplication = label.contains("app")
                    || label.contains("application")
                let mentionsWebsite = label.contains("website")
                    || label.contains("site")
                    || label.contains("web")
                let mentionsActivity = label.contains("activity")
                    || label.contains("activité")
                    || label.contains("actividad")
                    || label.contains("aktivität")
                return mentionsApplication && mentionsWebsite && mentionsActivity
            }) else { return false }
            return AXUIElementPerformAction(activity, kAXPressAction as CFString) == .success
        }

        private func openScreenTimeActivityView() {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension?Usage"
            ) else { return }
            let work = {
                guard let settingsURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: self.bundleIdentifier
                ) else {
                    NSWorkspace.shared.open(url)
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                configuration.promptsUserIfNeeded = false
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: settingsURL,
                    configuration: configuration
                )
            }
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.sync(execute: work)
            }
        }

        private func runningApplicationElement() -> AXUIElement? {
            guard let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first else { return nil }
            let element = AXUIElementCreateApplication(application.processIdentifier)
            // System Settings lazily materializes extension views. A 250 ms AX timeout made the
            // exact reader intermittently miss a view that was already visibly present.
            AXUIElementSetMessagingTimeout(element, Float(min(2, updateTimeout)))
            return element
        }

        private func activityWindow(in application: AXUIElement) -> AXUIElement? {
            let windows = applicationWindows(in: application)
            if let titled = windows.first(where: { window in
                let label = [
                    string(window, attribute: Attribute.title),
                    string(window, attribute: Attribute.description),
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .lowercased()
                let mentionsApplication = label.contains("app")
                    || label.contains("application")
                let mentionsWebsite = label.contains("website")
                    || label.contains("site")
                    || label.contains("web")
                let mentionsActivity = label.contains("activity")
                    || label.contains("activite")
                    || label.contains("actividad")
                    || label.contains("aktivitat")
                return mentionsApplication && mentionsWebsite && mentionsActivity
            }) {
                return titled
            }
            return windows.first { window in
                descendants(of: window).contains {
                    string($0, attribute: Attribute.identifier) == "usageHeaderView"
                }
            }
        }

        private func applicationWindows(in application: AXUIElement) -> [AXUIElement] {
            let explicitWindows = elements(application, attribute: Attribute.windows)
            if !explicitWindows.isEmpty { return explicitWindows }
            let childWindows = elements(application).filter {
                string($0, attribute: Attribute.role) == (kAXWindowRole as String)
            }
            if !childWindows.isEmpty { return childWindows }
            if let focusedWindow = element(
                application,
                attribute: kAXFocusedWindowAttribute as CFString
            ) {
                return [focusedWindow]
            }

            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, Float(min(2, updateTimeout)))
            if let focused = element(
                systemWide,
                attribute: kAXFocusedUIElementAttribute as CFString
            ), let window = windowAncestor(of: focused) {
                return [window]
            }
            for screen in NSScreen.screens {
                let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(
                    systemWide,
                    Float(point.x),
                    Float(point.y),
                    &hit
                ) == .success,
                    let hit,
                    let window = windowAncestor(of: hit)
                {
                    return [window]
                }
            }
            return []
        }

        private func windowAncestor(of element: AXUIElement) -> AXUIElement? {
            var candidate = element
            for _ in 0 ..< 16 {
                if string(candidate, attribute: Attribute.role) == (kAXWindowRole as String) {
                    return candidate
                }
                guard let parent = self.element(candidate, attribute: Attribute.parent) else {
                    return nil
                }
                candidate = parent
            }
            return nil
        }

        private func navigateToToday(application: AXUIElement) throws {
            guard wait(timeout: launchTimeout, until: {
                guard let window = self.activityWindow(in: application) else { return false }
                return self.datePopup(in: window) != nil && self.todayButton(in: window) != nil
            }),
                  let window = activityWindow(in: application),
                  let datePopup = datePopup(in: window),
                  let initialTodayButton = todayButton(in: window)
            else {
                throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                    "today controls are missing"
                )
            }
            if let value = string(datePopup, attribute: Attribute.value),
               relativeDayDistance(from: value) == 0
            {
                return
            }
            let reachedToday = {
                if let value = self.string(datePopup, attribute: Attribute.value),
                   self.relativeDayDistance(from: value) == 0
                {
                    return true
                }
                guard let nextWindow = self.activityWindow(in: application),
                      let nextPopup = self.datePopup(in: nextWindow),
                      let value = self.string(nextPopup, attribute: Attribute.value)
                else { return false }
                return self.relativeDayDistance(from: value) == 0
            }
            for strategy in 0 ..< 3 {
                activateSystemSettings()
                guard let nextWindow = activityWindow(in: application),
                      let button = strategy == 0
                        ? Optional(initialTodayButton)
                        : todayButton(in: nextWindow)
                else { continue }
                _ = AXUIElementPerformAction(nextWindow, kAXRaiseAction as CFString)
                switch strategy {
                case 0:
                    _ = AXUIElementPerformAction(
                        button,
                        kAXPressAction as CFString
                    )
                case 1:
                    _ = keyboardPress(button)
                default:
                    _ = click(button)
                }
                // Some Screen Time controls perform their action but report an AX failure.
                // Always observe the rendered date before trying another strategy, otherwise
                // a false-negative AX result can trigger the same navigation twice.
                if wait(timeout: max(updateTimeout, 4), until: reachedToday) { return }
            }
            let value = activityWindow(in: application)
                .flatMap { self.datePopup(in: $0) }
                .flatMap { string($0, attribute: Attribute.value) }
                ?? "unknown"
            throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                "Today did not change the date from \(value)"
            )
        }

        private func navigateBackwardOneDay(
            application: AXUIElement,
            now: Date,
            calendar: Calendar
        ) throws {
            guard wait(timeout: launchTimeout, until: {
                guard let window = self.activityWindow(in: application) else { return false }
                return self.datePopup(in: window) != nil
                    && self.descendants(of: window).contains(where: {
                        self.string($0, attribute: Attribute.identifier) == "chevron.backward"
                    })
            }),
                  let window = activityWindow(in: application),
                  let datePopup = datePopup(in: window),
                  let back = descendants(of: window).first(where: {
                      string($0, attribute: Attribute.identifier) == "chevron.backward"
                  })
            else {
                throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                    "Back control is missing"
                )
            }
            let previousValue = string(datePopup, attribute: Attribute.value)
            guard let previousValue,
                  let previousDistance = AppleSettingsScreenTimeDateParser.dayDistance(
                      from: previousValue,
                      now: now,
                      calendar: calendar
                  )
            else {
                throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                    "could not parse the current date before navigating backward"
                )
            }
            let expectedDistance = previousDistance + 1
            let reachedExpectedDate = {
                self.visibleDayDistance(
                    application: application,
                    now: now,
                    calendar: calendar
                ) == expectedDistance
            }
            for strategy in 0 ..< 3 {
                activateSystemSettings()
                guard let nextWindow = activityWindow(in: application),
                      let button = strategy == 0
                        ? Optional(back)
                        : descendants(of: nextWindow).first(where: {
                            string($0, attribute: Attribute.identifier) == "chevron.backward"
                        })
                else { continue }
                _ = AXUIElementPerformAction(nextWindow, kAXRaiseAction as CFString)
                switch strategy {
                case 0:
                    _ = AXUIElementPerformAction(
                        button,
                        kAXPressAction as CFString
                    )
                case 1:
                    _ = keyboardPress(button)
                default:
                    _ = click(button)
                }
                // Observe the date even when AX reports failure: on macOS Screen Time the
                // press can succeed visually while AXUIElementPerformAction returns an error.
                if wait(timeout: max(updateTimeout, 4), until: reachedExpectedDate) { return }
                let observedDistance = visibleDayDistance(
                    application: application,
                    now: now,
                    calendar: calendar
                )
                if let observedDistance, observedDistance != previousDistance {
                    throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                        "Back expected day distance \(expectedDistance) from \(previousValue), found \(observedDistance)"
                    )
                }
            }
            let observedDistance = visibleDayDistance(
                application: application,
                now: now,
                calendar: calendar
            )
            throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                "Back expected day distance \(expectedDistance) from \(previousValue), found \(observedDistance.map(String.init) ?? "unknown")"
            )
        }

        private func todayButton(in window: AXUIElement) -> AXUIElement? {
            guard let back = descendants(of: window).first(where: {
                string($0, attribute: Attribute.identifier) == "chevron.backward"
            }),
                let parent = element(back, attribute: Attribute.parent)
            else { return nil }
            let siblings = elements(parent)
            guard let backIndex = siblings.firstIndex(where: { CFEqual($0, back) }) else {
                return nil
            }
            return siblings.dropFirst(backIndex + 1).first(where: {
                string($0, attribute: Attribute.role) == (kAXButtonRole as String)
                    && string($0, attribute: Attribute.identifier) != "chevron.forward"
            })
        }

        private func restoreDate(
            _ expectedValue: String,
            application: AXUIElement,
            now: Date,
            calendar: Calendar
        ) throws {
            let expected = normalizedText(expectedValue)
            if let window = activityWindow(in: application),
               let popup = datePopup(in: window),
               normalizedValue(of: popup) == expected
            {
                return
            }
            try navigateToToday(application: application)
            if let window = activityWindow(in: application),
               let popup = datePopup(in: window),
               normalizedValue(of: popup) == expected
            {
                return
            }
            for _ in 0 ..< maximumHistoryDays {
                try navigateBackwardOneDay(
                    application: application,
                    now: now,
                    calendar: calendar
                )
                if let window = activityWindow(in: application),
                   let popup = datePopup(in: window),
                   normalizedValue(of: popup) == expected
                {
                    return
                }
            }
            throw AppleSettingsScreenTimeOracleError.dateNavigationUnavailable(
                "could not restore \(expectedValue)"
            )
        }

        private func datePopup(in window: AXUIElement) -> AXUIElement? {
            let popups = screenTimeHeaderPopups(in: window)
            guard popups.count >= 2 else { return nil }
            return popups[1]
        }

        private func devicePopup(in window: AXUIElement) -> AXUIElement? {
            let popups = screenTimeHeaderPopups(in: window)
            guard !popups.isEmpty else { return nil }
            return popups.first(where: { element in
                let label = [
                    string(element, attribute: Attribute.title),
                    string(element, attribute: Attribute.description),
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .lowercased()
                return label.contains("device")
                    || label.contains("appareil")
                    || label.contains("gerat")
                    || label.contains("dispositivo")
            }) ?? popups[0]
        }

        private func screenTimeHeaderPopups(in window: AXUIElement) -> [AXUIElement] {
            descendants(of: window).filter { element in
                guard string(element, attribute: Attribute.role) == (kAXPopUpButtonRole as String)
                else { return false }
                let identifier = string(element, attribute: Attribute.identifier) ?? ""
                return !identifier.lowercased().contains("mostused")
            }
        }

        private func relativeDayDistance(from value: String) -> Int? {
            let normalized = value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            if normalized.contains("today")
                || normalized.contains("aujourd'hui")
                || normalized.contains("aujourdhui")
                || normalized.contains("hoy")
                || normalized.contains("heute")
            {
                return 0
            }
            if normalized.contains("yesterday")
                || normalized.contains("hier")
                || normalized.contains("ayer")
                || normalized.contains("gestern")
            {
                return 1
            }
            return nil
        }

        private func visibleDayDistance(
            application: AXUIElement,
            now: Date,
            calendar: Calendar
        ) -> Int? {
            guard let window = activityWindow(in: application),
                  let popup = datePopup(in: window),
                  let value = string(popup, attribute: Attribute.value)
            else { return nil }
            return AppleSettingsScreenTimeDateParser.dayDistance(
                from: value,
                now: now,
                calendar: calendar
            )
        }

        private func deviceMenuTitles(application: AXUIElement) throws -> [String] {
            guard let window = activityWindow(in: application),
                  let popup = devicePopup(in: window)
            else { throw AppleSettingsScreenTimeOracleError.deviceMenuUnavailable("device popup missing") }

            if openMenu(popup),
               let menuItems = waitForMenuItems(application: application, popup: popup)
            {
                let titles = menuItems.compactMap { string($0, attribute: Attribute.title) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !titles.isEmpty {
                    _ = AXUIElementPerformAction(menuItems[0], kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.08)
                    return titles
                }
            }

            dismissOpenMenu()
            guard let titles = deviceMenuTitlesByKeyboard(application: application, popup: popup),
                  !titles.isEmpty
            else {
                throw AppleSettingsScreenTimeOracleError.deviceMenuUnavailable(
                    "menu items hidden from AX and bounded keyboard enumeration failed"
                )
            }
            return titles
        }

        private func ensureApplicationsUsageMode(
            application: AXUIElement
        ) throws -> UsageModeRestoration? {
            guard let window = activityWindow(in: application),
                  let popup = usageModePopup(in: window),
                  let originalTitle = string(popup, attribute: Attribute.value)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !originalTitle.isEmpty
            else {
                throw AppleSettingsScreenTimeOracleError.usageModeUnavailable(
                    "view selector is missing"
                )
            }
            if isApplicationsUsageMode(originalTitle) { return nil }

            if openMenu(popup),
               let menuItems = waitForMenuItems(application: application, popup: popup)
            {
                let titledItems = menuItems.compactMap { item -> (AXUIElement, String)? in
                    guard let title = string(item, attribute: Attribute.title)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !title.isEmpty
                    else { return nil }
                    return (item, title)
                }
                guard let applicationIndex = titledItems.firstIndex(where: {
                    isApplicationsUsageMode($0.1)
                }),
                    let originalIndex = titledItems.firstIndex(where: {
                        normalizedText($0.1) == normalizedText(originalTitle)
                    }),
                    AXUIElementPerformAction(
                        titledItems[applicationIndex].0,
                        kAXPressAction as CFString
                    ) == .success
                else {
                    dismissOpenMenu()
                    throw AppleSettingsScreenTimeOracleError.usageModeUnavailable(
                        "application row is missing"
                    )
                }
                let expectedTitle = titledItems[applicationIndex].1
                guard wait(until: {
                    guard let nextWindow = self.activityWindow(in: application),
                          let nextPopup = self.usageModePopup(in: nextWindow)
                    else { return false }
                    return self.normalizedValue(of: nextPopup)
                        == self.normalizedText(expectedTitle)
                }) else {
                    throw AppleSettingsScreenTimeOracleError.usageModeUnavailable(
                        "application view did not become active"
                    )
                }
                return UsageModeRestoration(title: originalTitle, index: originalIndex)
            }

            dismissOpenMenu()
            guard selectPopupIndexByKeyboard(
                0,
                expectedTitle: nil,
                application: application,
                popup: popup
            ),
                let nextWindow = activityWindow(in: application),
                let nextPopup = usageModePopup(in: nextWindow),
                let applicationTitle = string(nextPopup, attribute: Attribute.value),
                isApplicationsUsageMode(applicationTitle)
            else {
                throw AppleSettingsScreenTimeOracleError.usageModeUnavailable(
                    "bounded keyboard selection failed"
                )
            }
            return UsageModeRestoration(title: originalTitle, index: 1)
        }

        private func selectUsageMode(
            at index: Int,
            expectedTitle: String,
            application: AXUIElement
        ) throws {
            guard let window = activityWindow(in: application),
                  let popup = usageModePopup(in: window)
            else {
                throw AppleSettingsScreenTimeOracleError.usageModeUnavailable(
                    "view selector disappeared"
                )
            }
            if normalizedValue(of: popup) == normalizedText(expectedTitle) { return }
            var selected = false
            if openMenu(popup),
               let menuItems = waitForMenuItems(application: application, popup: popup),
               let item = menuItems.first(where: {
                   normalizedText(string($0, attribute: Attribute.title) ?? "")
                       == normalizedText(expectedTitle)
               }),
               AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            {
                selected = true
            } else {
                dismissOpenMenu()
                selected = selectPopupIndexByKeyboard(
                    index,
                    expectedTitle: expectedTitle,
                    application: application,
                    popup: popup
                )
            }
            guard selected,
                  wait(until: {
                      guard let nextWindow = self.activityWindow(in: application),
                            let nextPopup = self.usageModePopup(in: nextWindow)
                      else { return false }
                      return self.normalizedValue(of: nextPopup)
                          == self.normalizedText(expectedTitle)
                  })
            else {
                throw AppleSettingsScreenTimeOracleError.usageModeUnavailable(
                    "could not restore \(expectedTitle)"
                )
            }
        }

        private func usageModePopup(in window: AXUIElement) -> AXUIElement? {
            descendants(of: window).first {
                guard string($0, attribute: Attribute.role) == (kAXPopUpButtonRole as String)
                else { return false }
                // macOS 26 has shipped both identifiers for the same Apps/Categories picker.
                // Accept only those exact Apple identifiers so another popup cannot be mistaken
                // for the usage-mode selector.
                let identifier = string($0, attribute: Attribute.identifier)
                return identifier == "mostUsedTablePicker"
                    || identifier == "mostUsedTablePickerItem"
            }
        }

        private func isApplicationsUsageMode(_ value: String) -> Bool {
            let normalized = value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return normalized.contains("app")
                || normalized.contains("application")
                || normalized.contains("aplicacion")
                || normalized.contains("anwendung")
        }

        private func selectDevice(
            at index: Int,
            expectedTitle: String,
            application: AXUIElement
        ) throws {
            guard let window = activityWindow(in: application),
                  let popup = devicePopup(in: window)
            else { throw AppleSettingsScreenTimeOracleError.deviceMenuUnavailable("device popup disappeared") }
            if normalizedValue(of: popup) == normalizedText(expectedTitle) { return }
            var selected = false
            if openMenu(popup),
               let menuItems = waitForMenuItems(application: application, popup: popup),
               menuItems.indices.contains(index),
               AXUIElementPerformAction(menuItems[index], kAXPressAction as CFString) == .success
            {
                selected = true
            } else {
                dismissOpenMenu()
                selected = selectPopupIndexByKeyboard(
                    index,
                    expectedTitle: expectedTitle,
                    application: application,
                    popup: popup
                )
            }
            guard selected else {
                throw AppleSettingsScreenTimeOracleError.deviceMenuUnavailable(
                    "could not select row \(index) named \(expectedTitle)"
                )
            }
            guard wait(until: {
                guard let nextWindow = self.activityWindow(in: application),
                      let nextPopup = self.devicePopup(in: nextWindow)
                else { return false }
                return self.normalizedValue(of: nextPopup) == self.normalizedText(expectedTitle)
            }) else {
                throw AppleSettingsScreenTimeOracleError.deviceMenuUnavailable(
                    "row \(index) did not publish value \(expectedTitle)"
                )
            }
        }

        private func deviceMenuTitlesByKeyboard(
            application: AXUIElement,
            popup: AXUIElement
        ) -> [String]? {
            var titles: [String] = []
            for index in 0 ..< 16 {
                guard selectPopupIndexByKeyboard(
                    index,
                    expectedTitle: nil,
                    application: application,
                    popup: popup
                ),
                    let window = activityWindow(in: application),
                    let refreshedPopup = devicePopup(in: window),
                    let value = string(refreshedPopup, attribute: Attribute.value)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else { return titles.isEmpty ? nil : titles }
                if titles.contains(value) { break }
                titles.append(value)
            }
            guard !titles.isEmpty else { return nil }
            guard let window = activityWindow(in: application),
                  let refreshedPopup = devicePopup(in: window),
                  selectPopupIndexByKeyboard(
                      0,
                      expectedTitle: titles[0],
                      application: application,
                      popup: refreshedPopup
                  )
            else { return nil }
            return titles
        }

        private func selectPopupIndexByKeyboard(
            _ index: Int,
            expectedTitle: String?,
            application: AXUIElement,
            popup: AXUIElement
        ) -> Bool {
            guard index >= 0 else { return false }
            for interaction in 0 ..< 2 {
                let opened: Bool
                if interaction == 0 {
                    opened = openMenu(popup)
                } else {
                    dismissOpenMenu()
                    opened = click(popup)
                }
                guard opened else { continue }
                Thread.sleep(forTimeInterval: 0.08)
                guard postKey(code: 126, count: 16),
                      postKey(code: 125, count: index),
                      postKey(code: 36)
                else { continue }
                Thread.sleep(forTimeInterval: 0.12)
                guard let window = activityWindow(in: application),
                      let refreshedPopup = devicePopup(in: window),
                      let value = normalizedValue(of: refreshedPopup)
                else { continue }
                if expectedTitle == nil || value == normalizedText(expectedTitle ?? "") { return true }
            }
            return false
        }

        private func dismissOpenMenu() {
            _ = postKey(code: 53)
            Thread.sleep(forTimeInterval: 0.04)
        }

        private func normalizedValue(of element: AXUIElement) -> String? {
            string(element, attribute: Attribute.value).map(normalizedText)
        }

        private func normalizedText(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func click(_ element: AXUIElement) -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
            else { return false }
            guard let frame = frame(of: element) else { return false }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let move = CGEvent(
                      mouseEventSource: source,
                      mouseType: .mouseMoved,
                      mouseCursorPosition: point,
                      mouseButton: .left
                  ),
                  let down = CGEvent(
                      mouseEventSource: source,
                      mouseType: .leftMouseDown,
                      mouseCursorPosition: point,
                      mouseButton: .left
                  ),
                  let up = CGEvent(
                      mouseEventSource: source,
                      mouseType: .leftMouseUp,
                      mouseCursorPosition: point,
                      mouseButton: .left
                  )
            else { return false }
            move.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.08)
            return true
        }

        private func keyboardPress(_ element: AXUIElement) -> Bool {
            let focus = {
                AXUIElementSetAttributeValue(
                    element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                ) == .success
            }
            let focused = Thread.isMainThread
                ? focus()
                : DispatchQueue.main.sync(execute: focus)
            guard focused
            else { return false }
            Thread.sleep(forTimeInterval: 0.03)
            return postKey(code: 49)
        }

        @discardableResult
        private func postKey(code: CGKeyCode) -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
            else { return false }
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            else { return false }
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            return true
        }

        private func postKey(code: CGKeyCode, count: Int) -> Bool {
            for _ in 0 ..< max(0, count) {
                guard postKey(code: code) else { return false }
            }
            return true
        }

        private func openMenu(_ popup: AXUIElement) -> Bool {
            var names: CFArray?
            if AXUIElementCopyActionNames(popup, &names) == .success,
               let actions = names as? [String],
               actions.contains("AXShowMenu"),
               AXUIElementPerformAction(popup, "AXShowMenu" as CFString) == .success
            {
                return true
            }
            return AXUIElementPerformAction(popup, kAXPressAction as CFString) == .success
        }

        private func waitForMenuItems(
            application: AXUIElement,
            popup: AXUIElement
        ) -> [AXUIElement]? {
            let deadline = Date().addingTimeInterval(updateTimeout)
            while Date() < deadline {
                var roots = [popup, application]
                let systemWide = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(systemWide, 0.10)
                if let focusedApplication = element(
                    systemWide,
                    attribute: kAXFocusedApplicationAttribute as CFString
                ) {
                    roots.append(focusedApplication)
                    if let focusedWindow = element(
                        focusedApplication,
                        attribute: kAXFocusedWindowAttribute as CFString
                    ) {
                        roots.append(focusedWindow)
                    }
                }
                if let focused = element(
                    systemWide,
                    attribute: kAXFocusedUIElementAttribute as CFString
                ) {
                    roots.append(focused)
                    var ancestor = focused
                    for _ in 0 ..< 4 {
                        guard let parent = element(ancestor, attribute: Attribute.parent) else { break }
                        roots.append(parent)
                        ancestor = parent
                    }
                }
                for root in roots {
                    let values = descendants(of: root, limit: 96).filter {
                        string($0, attribute: Attribute.role) == (kAXMenuItemRole as String)
                    }
                    if !values.isEmpty { return values }
                }
                if let values = menuItemsAtPopupPosition(popup), !values.isEmpty {
                    return values
                }
                Thread.sleep(forTimeInterval: 0.04)
            }
            return nil
        }

        private func menuItemsAtPopupPosition(_ popup: AXUIElement) -> [AXUIElement]? {
            guard let frame = frame(of: popup) else { return nil }
            let systemWide = AXUIElementCreateSystemWide()
            let x = Float(frame.midX)
            // AX frame coordinates and CGEvent coordinates can use opposite vertical origins
            // depending on the display arrangement. Scan a small bounded band on both sides of
            // the popup instead of assuming the menu always grows toward increasing Y.
            let minimumY = Int(floor(frame.minY - 520))
            let maximumY = Int(ceil(frame.maxY + 520))
            for y in stride(from: minimumY, through: maximumY, by: 8) where y >= 0 {
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(
                    systemWide,
                    x,
                    Float(y),
                    &hit
                ) == .success,
                    var candidate = hit
                else { continue }
                for _ in 0 ..< 6 {
                    if string(candidate, attribute: Attribute.role) == (kAXMenuItemRole as String) {
                        if let menu = element(candidate, attribute: Attribute.parent) {
                            let items = descendants(of: menu, limit: 96).filter {
                                string($0, attribute: Attribute.role) == (kAXMenuItemRole as String)
                            }
                            if !items.isEmpty { return items }
                        }
                        return [candidate]
                    }
                    guard let parent = element(candidate, attribute: Attribute.parent) else { break }
                    candidate = parent
                }
            }
            return nil
        }

        private func readVisibleUsage(
            application: AXUIElement,
            deviceName: String,
            minimumObservationInterval: TimeInterval
        ) throws -> AppleSettingsUsagePresentation {
            let startedAt = Date()
            let requiredStableInterval = min(0.75, updateTimeout / 2)
            let minimumObservation = max(0, minimumObservationInterval)
            let deadline = startedAt.addingTimeInterval(
                max(updateTimeout, minimumObservation + requiredStableInterval)
            )
            var best: AppleSettingsUsagePresentation?
            var bestAllUsageRow: AppleSettingsUsagePresentation.Row?
            var lastRows: [AppleSettingsUsagePresentation.Row]?
            var stableSince: Date?

            repeat {
                if let window = activityWindow(in: application),
                   let header = descendants(of: window).first(where: {
                       string($0, attribute: Attribute.identifier) == "usageHeaderView"
                   }),
                   let headerText = textCandidates(for: header).first(where: {
                       AppleSettingsScreenTimeParser.duration(from: $0) != nil
                   }),
                   let headerDuration = AppleSettingsScreenTimeParser.duration(from: headerText),
                   let table = descendants(of: window).first(where: {
                       string($0, attribute: Attribute.identifier) == "mostUsedTable"
                   })
                {
                    let exposedRows = elements(
                        table,
                        attribute: kAXRowsAttribute as CFString
                    )
                    let rowElements = exposedRows.isEmpty
                        ? descendants(of: table).filter {
                            string($0, attribute: Attribute.role) == (kAXRowRole as String)
                        }
                        : exposedRows
                    let parsedRows = rowElements
                        .compactMap { row in
                            AppleSettingsScreenTimeParser.usageRow(from: flattenedText(row))
                        }
                    if let allUsage = parsedRows.first,
                       abs(allUsage.duration - headerDuration) <= 1
                    {
                        let rows = Array(parsedRows.dropFirst())
                        let candidate = AppleSettingsUsagePresentation(
                            total: headerDuration,
                            rows: rows
                        )
                        if best == nil || rows.count >= (best?.rows.count ?? 0) {
                            best = candidate
                            bestAllUsageRow = allUsage
                        }
                        if rows == lastRows {
                            if let stableSince,
                               Date().timeIntervalSince(startedAt) >= minimumObservation,
                               Date().timeIntervalSince(stableSince) >= requiredStableInterval
                            {
                                let chosen = best ?? candidate
                                return AppleSettingsUsagePresentation(
                                    total: chosen.total,
                                    rows: readAllUsageRows(
                                        application: application,
                                        initialRows: chosen.rows,
                                        allUsageRow: bestAllUsageRow ?? allUsage
                                    )
                                )
                            }
                        } else {
                            lastRows = rows
                            stableSince = Date()
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline

            guard let best else {
                throw AppleSettingsScreenTimeOracleError.usageUnavailable(deviceName)
            }
            return AppleSettingsUsagePresentation(
                total: best.total,
                rows: readAllUsageRows(
                    application: application,
                    initialRows: best.rows,
                    allUsageRow: bestAllUsageRow
                )
            )
        }

        private func readAllUsageRows(
            application: AXUIElement,
            initialRows: [AppleSettingsUsagePresentation.Row],
            allUsageRow: AppleSettingsUsagePresentation.Row?
        ) -> [AppleSettingsUsagePresentation.Row] {
            guard let window = activityWindow(in: application),
                  let table = descendants(of: window).first(where: {
                      string($0, attribute: Attribute.identifier) == "mostUsedTable"
                  }),
                  let scrollBar = scrollBarControlling(table)
            else { return initialRows }

            let originalValue = numericValue(of: scrollBar)
            defer {
                if let originalValue {
                    _ = setNumericValue(originalValue, of: scrollBar)
                }
            }

            var accumulated = initialRows
            for position in [0.5, 1.0] {
                guard setNumericValue(position, of: scrollBar) else { break }
                Thread.sleep(forTimeInterval: 0.15)
                guard let refreshedWindow = activityWindow(in: application),
                      let refreshedTable = descendants(of: refreshedWindow).first(where: {
                          string($0, attribute: Attribute.identifier) == "mostUsedTable"
                      })
                else { continue }
                let pageRows = parsedUsageRows(in: refreshedTable).filter { row in
                    guard let allUsageRow else { return true }
                    return row != allUsageRow
                }
                accumulated = mergeUsageRows(accumulated, with: pageRows)
            }
            return accumulated
        }

        private func parsedUsageRows(
            in table: AXUIElement
        ) -> [AppleSettingsUsagePresentation.Row] {
            let exposedRows = elements(table, attribute: kAXRowsAttribute as CFString)
            let rowElements = exposedRows.isEmpty
                ? descendants(of: table).filter {
                    string($0, attribute: Attribute.role) == (kAXRowRole as String)
                }
                : exposedRows
            return rowElements.compactMap { row in
                AppleSettingsScreenTimeParser.usageRow(from: flattenedText(row))
            }
        }

        private func mergeUsageRows(
            _ existing: [AppleSettingsUsagePresentation.Row],
            with following: [AppleSettingsUsagePresentation.Row]
        ) -> [AppleSettingsUsagePresentation.Row] {
            guard !following.isEmpty else { return existing }
            if existing == following { return existing }
            let maximumOverlap = min(existing.count, following.count)
            if maximumOverlap > 0 {
                for overlap in stride(from: maximumOverlap, through: 1, by: -1)
                where Array(existing.suffix(overlap)) == Array(following.prefix(overlap)) {
                    return existing + following.dropFirst(overlap)
                }
            }
            return existing + following
        }

        private func scrollBarControlling(_ element: AXUIElement) -> AXUIElement? {
            var candidate = element
            for _ in 0 ..< 12 {
                guard let parent = self.element(candidate, attribute: Attribute.parent) else {
                    return nil
                }
                if let direct = elements(parent).first(where: {
                    string($0, attribute: Attribute.role) == (kAXScrollBarRole as String)
                }) {
                    return direct
                }
                if string(parent, attribute: Attribute.role) == (kAXScrollAreaRole as String),
                   let nested = descendants(of: parent, limit: 256).first(where: {
                       string($0, attribute: Attribute.role) == (kAXScrollBarRole as String)
                   })
                {
                    return nested
                }
                candidate = parent
            }
            return nil
        }

        private func numericValue(of element: AXUIElement) -> Double? {
            (copyValue(element, attribute: Attribute.value) as? NSNumber)?.doubleValue
        }

        private func setNumericValue(_ value: Double, of element: AXUIElement) -> Bool {
            AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                NSNumber(value: value)
            ) == .success
        }

        private func flattenedText(_ element: AXUIElement) -> String {
            var values: [String] = []
            for candidate in textCandidates(for: element) where !values.contains(candidate) {
                values.append(candidate)
            }
            for child in descendants(of: element, limit: 48).dropFirst() {
                for candidate in textCandidates(for: child) where !values.contains(candidate) {
                    values.append(candidate)
                }
            }
            return values.joined(separator: "\n")
        }

        private func textCandidates(for element: AXUIElement) -> [String] {
            [Attribute.title, Attribute.value, Attribute.description]
                .compactMap { string(element, attribute: $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        private func wait(
            timeout: TimeInterval? = nil,
            until predicate: () -> Bool
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout ?? updateTimeout)
            while Date() < deadline {
                if predicate() { return true }
                Thread.sleep(forTimeInterval: 0.04)
            }
            return predicate()
        }

        private func descendants(of root: AXUIElement, limit: Int? = nil) -> [AXUIElement] {
            let maximum = min(maximumNodes, max(1, limit ?? maximumNodes))
            var queue: [AXUIElement] = [root]
            var index = 0
            while index < queue.count, queue.count < maximum {
                let current = queue[index]
                index += 1
                let remaining = maximum - queue.count
                queue.append(contentsOf: elements(current).prefix(remaining))
            }
            return queue
        }

        private func copyValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
                return nil
            }
            return value
        }

        private func string(_ element: AXUIElement, attribute: CFString) -> String? {
            copyValue(element, attribute: attribute) as? String
        }

        private func element(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
            guard let value = copyValue(element, attribute: attribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            return (value as! AXUIElement)
        }

        private func elements(
            _ element: AXUIElement,
            attribute: CFString = Attribute.children
        ) -> [AXUIElement] {
            copyValue(element, attribute: attribute) as? [AXUIElement] ?? []
        }

        private func frame(of element: AXUIElement) -> CGRect? {
            guard let positionValue = copyValue(element, attribute: Attribute.position),
                  let sizeValue = copyValue(element, attribute: Attribute.size),
                  CFGetTypeID(positionValue) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else { return nil }
            let positionAX = positionValue as! AXValue
            let sizeAX = sizeValue as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionAX, .cgPoint, &position),
                  AXValueGetValue(sizeAX, .cgSize, &size)
            else { return nil }
            return CGRect(origin: position, size: size)
        }
    }
#endif
