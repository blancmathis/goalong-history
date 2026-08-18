#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class DashboardDataReader {
        private let fileManager = FileManager.default

        func snapshot(for day: Date) -> DashboardDaySnapshot {
            let events = loadEvents(for: day).sorted { $0.timestamp < $1.timestamp }
            let seals = loadSeals(for: day).sorted { $0.anchorSequence < $1.anchorSequence }
            let receiptSequences = loadReceiptSequences()

            let activeMinuteKeys = Set(
                events
                    .filter(Self.isActivityEvent)
                    .map { Self.minuteKey($0.timestamp) }
            )
            let workMinuteKeys = Set(
                events
                    .filter { Self.isActivityEvent($0) && $0.classification?.isWork == true }
                    .map { Self.minuteKey($0.timestamp) }
            )

            var privateMinuteKeys = Set<Int64>()
            for seal in seals {
                let states = coverageStates(for: seal)
                if states.contains(where: { $0 != "captured" }) {
                    privateMinuteKeys.insert(Self.minuteKey(seal.minuteStart))
                }
            }
            for event in events where event.suppressionReason != nil {
                privateMinuteKeys.insert(Self.minuteKey(event.timestamp))
            }

            let sealsByMinute = Dictionary(grouping: seals, by: { Self.minuteKey($0.minuteStart) })
            let sealedMinuteKeys = Set(sealsByMinute.keys)
            let liveAnchoredMinuteKeys = Set(
                sealsByMinute.compactMap { key, values in
                    values.contains(where: { receiptSequences.contains($0.anchorSequence) }) ? key : nil
                }
            )

            let sessions = buildSessions(from: events)
            let trackedUsage = buildTrackedUsage(from: events, day: day)
            let appUsage = trackedUsage.compactMap { item -> AppUsage? in
                guard item.kind == .application, item.foregroundSeconds > 0 else { return nil }
                return AppUsage(
                    appName: item.name,
                    bundleIdentifier: item.bundleIdentifier,
                    activeMinutes: Int(ceil(item.foregroundSeconds / 60)),
                    eventCount: item.eventCount
                )
            }
            let timeline = buildTimeline(
                for: day,
                activeMinuteKeys: activeMinuteKeys,
                workMinuteKeys: workMinuteKeys,
                privateMinuteKeys: privateMinuteKeys,
                sealedMinuteKeys: sealedMinuteKeys
            )
            let softwareAttributedEvents = events.filter {
                $0.inputOrigin?.assessment == .softwareAttributed
            }.count

            return DashboardDaySnapshot(
                day: day,
                eventCount: events.count,
                activeMinutes: activeMinuteKeys.count,
                workMinutes: workMinuteKeys.count,
                sealedMinutes: sealedMinuteKeys.count,
                liveAnchoredMinutes: liveAnchoredMinuteKeys.count,
                privateMinutes: privateMinuteKeys.count,
                softwareAttributedEvents: softwareAttributedEvents,
                sessions: sessions,
                appUsage: appUsage,
                trackedUsage: trackedUsage,
                timeline: timeline,
                storageBytes: storageBytes(),
                availableDays: availableDays()
            )
        }

        private func loadEvents(for day: Date) -> [HistoryEvent] {
            decodeJSONLines(HistoryEvent.self, at: AppPaths.eventFileURL(for: day))
        }

        private func loadSeals(for day: Date) -> [LocalMinuteSeal] {
            decodeJSONLines(LocalMinuteSeal.self, at: AppPaths.sealFileURL(for: day))
        }

        private func loadReceiptSequences() -> Set<UInt64> {
            guard
                let files = try? fileManager.contentsOfDirectory(
                    at: AppPaths.receiptsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { return [] }

            var result = Set<UInt64>()
            for file in files where file.pathExtension == "jsonl" {
                for receipt in decodeJSONLines(AnchorReceipt.self, at: file) {
                    result.insert(receipt.anchorSequence)
                }
            }
            return result
        }

        private func decodeJSONLines<T: Decodable>(_ type: T.Type, at url: URL) -> [T] {
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                let text = String(data: data, encoding: .utf8)
            else { return [] }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n").compactMap { line in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(T.self, from: lineData)
            }
        }

        private func coverageStates(for seal: LocalMinuteSeal) -> [String] {
            guard let field = seal.minuteFields.first(where: { $0.name == "coverage" }),
                let raw = field.opening.fields["states"]
            else { return [] }
            return raw.split(separator: ",").map(String.init)
        }

        private func buildTrackedUsage(from events: [HistoryEvent], day: Date) -> [TrackedUsageItem] {
            struct Counter {
                var kind: TrackedSubjectKind
                var name: String
                var appName: String?
                var bundleIdentifier: String?
                var host: String?
                var foregroundSeconds: TimeInterval = 0
                var activeMinuteKeys = Set<Int64>()
                var eventCount = 0
                var categories: [String: Int] = [:]
                var identityProofAvailable = true
            }

            var counters: [String: Counter] = [:]
            let ordered = events.sorted { $0.timestamp < $1.timestamp }
            for (index, event) in ordered.enumerated() {
                guard event.suppressionReason == nil, let app = event.app else { continue }

                let nextTimestamp: Date = {
                    if index + 1 < ordered.count { return ordered[index + 1].timestamp }
                    if Calendar.current.isDateInToday(day) { return Date() }
                    return event.timestamp.addingTimeInterval(60)
                }()
                let observedSeconds = min(75, max(0, nextTimestamp.timeIntervalSince(event.timestamp)))
                let isInput = event.pointer != nil || event.keyboard != nil || event.scroll != nil
                let minute = Self.minuteKey(event.timestamp)
                let category = event.classification?.category

                let appKey = SharingSubjectKey.application(
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name
                )
                var appCounter = counters[appKey] ?? Counter(
                    kind: .application,
                    name: app.name,
                    appName: nil,
                    bundleIdentifier: app.bundleIdentifier,
                    host: nil
                )
                appCounter.foregroundSeconds += observedSeconds
                appCounter.eventCount += 1
                if isInput { appCounter.activeMinuteKeys.insert(minute) }
                if let category { appCounter.categories[category, default: 0] += 1 }
                counters[appKey] = appCounter

                guard let rawHost = event.url?.host else { continue }
                let host = SharingSubjectKey.normalizedHost(rawHost)
                guard !host.isEmpty else { continue }
                let siteKey = SharingSubjectKey.website(host: host)
                var siteCounter = counters[siteKey] ?? Counter(
                    kind: .website,
                    name: host,
                    appName: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    host: host
                )
                siteCounter.foregroundSeconds += observedSeconds
                siteCounter.eventCount += 1
                if isInput { siteCounter.activeMinuteKeys.insert(minute) }
                if let category { siteCounter.categories[category, default: 0] += 1 }
                if event.schemaVersion < 3 { siteCounter.identityProofAvailable = false }
                counters[siteKey] = siteCounter
            }

            return counters.map { key, value in
                let category = value.categories.max { left, right in
                    if left.value == right.value { return left.key > right.key }
                    return left.value < right.value
                }?.key
                return TrackedUsageItem(
                    id: key,
                    kind: value.kind,
                    name: value.name,
                    appName: value.appName,
                    bundleIdentifier: value.bundleIdentifier,
                    host: value.host,
                    category: category,
                    foregroundSeconds: value.foregroundSeconds,
                    activeMinutes: value.activeMinuteKeys.count,
                    eventCount: value.eventCount,
                    identityProofAvailable: value.identityProofAvailable
                )
            }
            .filter { $0.foregroundSeconds > 0 || $0.eventCount > 0 }
            .sorted {
                if $0.kind != $1.kind { return $0.kind == .application }
                if $0.foregroundSeconds == $1.foregroundSeconds { return $0.name < $1.name }
                return $0.foregroundSeconds > $1.foregroundSeconds
            }
        }

        private func buildSessions(from events: [HistoryEvent]) -> [ActivitySession] {
            struct Builder {
                let id: String
                var key: String
                var start: Date
                var end: Date
                var appName: String
                var bundleIdentifier: String?
                var windowTitle: String?
                var host: String?
                var category: String?
                var isWork: Bool?
                var confidence: Double?
                var suppressionReason: SuppressionReason?
                var eventCount: Int
                var inputEventCount: Int
                var softwareAttributedEventCount: Int
                var kindCounts: [String: Int]
                var latestMessage: String?

                mutating func add(_ event: HistoryEvent) {
                    end = max(end, event.timestamp)
                    eventCount += 1
                    kindCounts[event.kind.rawValue, default: 0] += 1
                    if event.pointer != nil || event.keyboard != nil || event.scroll != nil {
                        inputEventCount += 1
                    }
                    if event.inputOrigin?.assessment == .softwareAttributed {
                        softwareAttributedEventCount += 1
                    }
                    if let message = event.message, !message.isEmpty { latestMessage = message }
                    if windowTitle == nil { windowTitle = event.window?.title }
                    if host == nil { host = event.url?.host }
                    if category == nil { category = event.classification?.category }
                    if isWork == nil { isWork = event.classification?.isWork }
                    if confidence == nil { confidence = event.classification?.confidence }
                }

                func finish() -> ActivitySession {
                    ActivitySession(
                        id: id,
                        start: start,
                        end: end,
                        appName: appName,
                        bundleIdentifier: bundleIdentifier,
                        windowTitle: windowTitle,
                        host: host,
                        category: category,
                        isWork: isWork,
                        confidence: confidence,
                        suppressionReason: suppressionReason,
                        eventCount: eventCount,
                        inputEventCount: inputEventCount,
                        softwareAttributedEventCount: softwareAttributedEventCount,
                        kindCounts: kindCounts,
                        latestMessage: latestMessage
                    )
                }
            }

            var result: [ActivitySession] = []
            var current: Builder?

            for event in events where Self.isSessionEvent(event) {
                let appName = event.app?.name ?? Self.systemLabel(for: event)
                let bundleIdentifier = event.app?.bundleIdentifier
                let category = event.classification?.category
                let suppression = event.suppressionReason
                let key = [
                    suppression?.rawValue ?? "captured",
                    bundleIdentifier ?? appName,
                    event.window?.title ?? "",
                    event.url?.host ?? "",
                    category ?? "",
                ].joined(separator: "|")

                let shouldMerge: Bool
                if let current {
                    let gap = event.timestamp.timeIntervalSince(current.end)
                    shouldMerge = current.key == key && gap >= 0 && gap <= 180
                } else {
                    shouldMerge = false
                }

                if shouldMerge {
                    current?.add(event)
                } else {
                    if let current { result.append(current.finish()) }
                    var builder = Builder(
                        id: event.id,
                        key: key,
                        start: event.timestamp,
                        end: event.timestamp,
                        appName: appName,
                        bundleIdentifier: bundleIdentifier,
                        windowTitle: event.window?.title,
                        host: event.url?.host,
                        category: category,
                        isWork: event.classification?.isWork,
                        confidence: event.classification?.confidence,
                        suppressionReason: suppression,
                        eventCount: 0,
                        inputEventCount: 0,
                        softwareAttributedEventCount: 0,
                        kindCounts: [:],
                        latestMessage: nil
                    )
                    builder.add(event)
                    current = builder
                }
            }

            if let current { result.append(current.finish()) }
            return result.sorted { $0.start > $1.start }
        }

        private func buildTimeline(
            for day: Date,
            activeMinuteKeys: Set<Int64>,
            workMinuteKeys: Set<Int64>,
            privateMinuteKeys: Set<Int64>,
            sealedMinuteKeys: Set<Int64>
        ) -> [TimelineBucket] {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: day)
            let today = calendar.isDateInToday(day)
            let now = Date()

            return (0..<96).map { bucketIndex in
                let start = startOfDay.addingTimeInterval(TimeInterval(bucketIndex * 15 * 60))
                let end = start.addingTimeInterval(15 * 60)
                let keys = (0..<15).map { minute in
                    Self.minuteKey(start.addingTimeInterval(TimeInterval(minute * 60)))
                }
                let active = keys.filter(activeMinuteKeys.contains).count
                let work = keys.filter(workMinuteKeys.contains).count
                let hidden = keys.filter(privateMinuteKeys.contains).count
                let sealed = keys.filter(sealedMinuteKeys.contains).count

                let kind: TimelineBucketKind
                if today && start > now {
                    kind = .future
                } else if active == 0 && hidden == 0 && sealed == 0 {
                    kind = .noData
                } else if hidden > 0 && hidden >= max(active, work) {
                    kind = .privateOrSuppressed
                } else if work > 0 {
                    kind = .work
                } else if active > 0 {
                    kind = .active
                } else {
                    kind = .sealed
                }

                return TimelineBucket(
                    start: start,
                    end: end,
                    kind: kind,
                    activeMinutes: active,
                    workMinutes: work,
                    privateMinutes: hidden,
                    sealedMinutes: sealed
                )
            }
        }

        private func storageBytes() -> Int64 {
            guard
                let enumerator = fileManager.enumerator(
                    at: AppPaths.applicationSupportDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { return 0 }

            var total: Int64 = 0
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true
                else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }

        private func availableDays() -> [Date] {
            var names = Set<String>()
            for directory in [AppPaths.eventsDirectory, AppPaths.sealsDirectory] {
                guard
                    let files = try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                else { continue }
                for file in files {
                    let name = file.lastPathComponent
                    if let match = name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                        names.insert(String(name[match]))
                    }
                }
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return names.compactMap(formatter.date(from:)).sorted(by: >)
        }

        private static func minuteKey(_ date: Date) -> Int64 {
            Int64(floor(date.timeIntervalSince1970 / 60.0))
        }

        private static func isActivityEvent(_ event: HistoryEvent) -> Bool {
            switch event.kind {
            case .applicationActivated, .windowChanged, .urlChanged, .mouseClick,
                .keyboardShortcut, .keyPressed, .typingBurst, .scrollBurst:
                return event.suppressionReason == nil
            default:
                return false
            }
        }

        private static func isSessionEvent(_ event: HistoryEvent) -> Bool {
            switch event.kind {
            case .heartbeat, .focusChanged:
                return false
            default:
                return true
            }
        }

        private static func systemLabel(for event: HistoryEvent) -> String {
            switch event.kind {
            case .recordingPaused, .recordingResumed: return "Recording control"
            case .permissionStatus: return "Permissions"
            case .sessionLocked, .sessionUnlocked: return "Mac session"
            case .systemSleep, .systemWake: return "Mac power"
            case .historyCleared: return "Local data"
            default: return "LocalHistory"
            }
        }
    }
#endif
