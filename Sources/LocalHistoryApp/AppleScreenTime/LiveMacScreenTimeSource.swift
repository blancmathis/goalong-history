#if os(macOS)
    import AppleScreenTime
    import Foundation
    import LocalHistoryCore

    /// Builds an always-current Screen Time report for this Mac from LocalHistory's
    /// append-only foreground activity stream. No private Screen Time database or
    /// manual export is involved.
    final class LiveMacScreenTimeSource {
        let device: AppleScreenTimeDevice

        private struct AppCounter {
            var bundleIdentifier: String?
            var displayName: String?
            var duration: TimeInterval = 0
        }

        private struct HourBucket {
            let start: Date
            let end: Date
            var total: TimeInterval = 0
            var applications: [String: AppCounter] = [:]
        }

        private struct RuntimeState {
            var app: AppSnapshot?
            var suppression: SuppressionReason?
            var recorderRunning = false
            var paused = false
            var sessionActive = true
            var systemAwake = true

            mutating func apply(_ event: HistoryEvent) {
                if let eventApp = event.app {
                    app = eventApp
                    recorderRunning = true
                    if event.kind != .captureSuppressed && event.kind != .secureInputSuppressed {
                        suppression = event.suppressionReason
                    }
                }

                switch event.kind {
                case .recorderStarted:
                    recorderRunning = true
                    paused = false
                case .recorderStopped:
                    recorderRunning = false
                    app = nil
                case .recordingPaused:
                    paused = true
                    app = nil
                case .recordingResumed:
                    recorderRunning = true
                    paused = false
                    app = nil
                case .sessionLocked:
                    sessionActive = false
                    app = nil
                case .sessionUnlocked:
                    sessionActive = true
                    app = nil
                case .systemSleep:
                    systemAwake = false
                    app = nil
                case .systemWake:
                    systemAwake = true
                    app = nil
                case .captureSuppressed:
                    suppression = event.suppressionReason
                case .captureResumed:
                    suppression = nil
                case .secureInputSuppressed:
                    suppression = event.suppressionReason ?? .secureInput
                case .secureInputResumed:
                    suppression = nil
                default:
                    break
                }
            }

            var canMeasureScreenTime: Bool {
                guard recorderRunning, !paused, sessionActive, systemAwake, app != nil else {
                    return false
                }
                guard let suppression else { return true }
                return ![
                    SuppressionReason.manualPause,
                    .sessionUnavailable,
                    .accessibilityUnavailable,
                ].contains(suppression)
            }

            var canRevealApplication: Bool {
                canMeasureScreenTime && suppression == nil
            }
        }

        private let fileManager: FileManager
        private let decoder: JSONDecoder
        private let calendar: Calendar
        private let maximumUnconfirmedGap: TimeInterval = 90

        private var cachedDay: Date?
        private var cachedEvents: [HistoryEvent] = []
        private var cachedOffset: UInt64 = 0
        private var trailingData = Data()

        init(
            deviceID: String,
            deviceName: String? = Host.current().localizedName,
            fileManager: FileManager = .default,
            calendar: Calendar = .current
        ) {
            self.device = AppleScreenTimeDevice(
                id: "local-mac:\(deviceID)",
                name: deviceName ?? ProcessInfo.processInfo.hostName,
                kind: .mac
            )
            self.fileManager = fileManager
            self.calendar = calendar
            self.decoder = JSONDecoder()
            self.decoder.dateDecodingStrategy = .iso8601
        }

        func storedExport(for day: Date, now: Date = Date()) -> AppleScreenTimeStoredExport? {
            guard let dayInterval = calendar.dateInterval(of: .day, for: day) else { return nil }
            let effectiveNow = min(max(now, dayInterval.start), dayInterval.end)
            let report = makeReport(
                events: loadEvents(for: day),
                interval: dayInterval,
                now: effectiveNow
            )

            let info = Bundle.main.infoDictionary
            let provenance = AppleScreenTimeProvenance(
                api: "LocalHistory live foreground activity recorder",
                collectorBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                collectorVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                collectorPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let envelope = AppleScreenTimeExportEnvelope(
                requestedStart: dayInterval.start,
                requestedEnd: dayInterval.end,
                requestedScope: .macOnly,
                provenance: provenance,
                reports: [report]
            )
            return AppleScreenTimeStoredExport(
                importedAt: now,
                verification: .unsigned,
                envelope: envelope
            )
        }

        private func loadEvents(for day: Date) -> [HistoryEvent] {
            let normalizedDay = calendar.startOfDay(for: day)
            if cachedDay != normalizedDay {
                resetCache(for: normalizedDay)
            }

            let file = AppPaths.eventFileURL(for: normalizedDay)
            guard fileManager.fileExists(atPath: file.path) else {
                cachedOffset = 0
                trailingData.removeAll(keepingCapacity: true)
                cachedEvents = seedEvents(for: normalizedDay)
                return cachedEvents
            }

            let size = fileSize(file)
            if size < cachedOffset {
                resetCache(for: normalizedDay)
            }
            guard size > cachedOffset else { return cachedEvents }

            do {
                let handle = try FileHandle(forReadingFrom: file)
                try handle.seek(toOffset: cachedOffset)
                let chunk = try handle.readToEnd() ?? Data()
                try handle.close()
                cachedOffset += UInt64(chunk.count)
                decodeAppended(chunk)
            } catch {
                Diagnostics.write("Live Mac Screen Time could not tail \(file.lastPathComponent): \(error)")
            }

            return cachedEvents
        }

        private func resetCache(for day: Date) {
            cachedDay = day
            cachedEvents = seedEvents(for: day)
            cachedOffset = 0
            trailingData.removeAll(keepingCapacity: true)
        }

        private func seedEvents(for day: Date) -> [HistoryEvent] {
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day),
                  let event = lastEvent(in: AppPaths.eventFileURL(for: previousDay))
            else { return [] }
            return [event]
        }

        private func lastEvent(in file: URL) -> HistoryEvent? {
            guard fileManager.fileExists(atPath: file.path) else { return nil }
            let size = fileSize(file)
            guard size > 0 else { return nil }

            do {
                let handle = try FileHandle(forReadingFrom: file)
                let readSize = min(size, 128 * 1_024)
                try handle.seek(toOffset: size - readSize)
                let data = try handle.readToEnd() ?? Data()
                try handle.close()

                for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                    if let event = try? decoder.decode(HistoryEvent.self, from: Data(line)) {
                        return event
                    }
                }
            } catch {
                Diagnostics.write("Live Mac Screen Time could not read the previous day tail: \(error)")
            }
            return nil
        }

        private func decodeAppended(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            trailingData.append(chunk)
            guard let lastNewline = trailingData.lastIndex(of: 0x0A) else { return }

            let completeEnd = trailingData.index(after: lastNewline)
            let complete = trailingData[..<completeEnd]
            trailingData = Data(trailingData[completeEnd...])

            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let event = try? decoder.decode(HistoryEvent.self, from: Data(line)) else { continue }
                cachedEvents.append(event)
            }
            cachedEvents.sort { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id < rhs.id
            }
        }

        private func fileSize(_ file: URL) -> UInt64 {
            guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                  let number = attributes[.size] as? NSNumber
            else { return 0 }
            return number.uint64Value
        }

        private func makeReport(
            events: [HistoryEvent],
            interval: DateInterval,
            now: Date
        ) -> AppleScreenTimeDeviceReport {
            var state = RuntimeState()
            var buckets: [Int64: HourBucket] = [:]
            let ordered = events
                .filter { $0.timestamp < interval.end }
                .sorted { lhs, rhs in
                    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                    return lhs.id < rhs.id
                }

            for index in ordered.indices {
                let event = ordered[index]
                state.apply(event)
                guard state.canMeasureScreenTime else { continue }

                let naturalEnd = index + 1 < ordered.count ? ordered[index + 1].timestamp : now
                var end = min(min(naturalEnd, now), interval.end)
                let start = max(event.timestamp, interval.start)
                guard end > start else { continue }

                // A normal foreground state is confirmed by a heartbeat at least once per minute.
                // Suppressed states intentionally emit no heartbeat, so their explicit resume,
                // lock, sleep, or stop boundary is used instead.
                if state.suppression == nil,
                   end.timeIntervalSince(event.timestamp) > maximumUnconfirmedGap
                {
                    end = min(end, event.timestamp.addingTimeInterval(maximumUnconfirmedGap))
                }
                guard end > start else { continue }

                accumulate(
                    start: start,
                    end: end,
                    app: state.canRevealApplication ? state.app : nil,
                    dayInterval: interval,
                    buckets: &buckets
                )
            }

            let segments = buckets.values
                .sorted { $0.start < $1.start }
                .map { bucket in
                    let applications = bucket.applications.values
                        .map {
                            AppleScreenTimeApplicationUsage(
                                bundleIdentifier: $0.bundleIdentifier,
                                displayName: $0.displayName,
                                duration: $0.duration
                            )
                        }
                        .sorted {
                            if $0.duration != $1.duration { return $0.duration > $1.duration }
                            return $0.resolvedName.localizedCaseInsensitiveCompare($1.resolvedName) == .orderedAscending
                        }
                    return AppleScreenTimeSegment(
                        start: bucket.start,
                        end: bucket.end,
                        totalScreenOnDuration: min(bucket.total, bucket.end.timeIntervalSince(bucket.start)),
                        applications: applications
                    )
                }

            return AppleScreenTimeDeviceReport(
                device: device,
                lastUpdatedAt: min(interval.end, max(interval.start, now)),
                segments: segments
            )
        }

        private func accumulate(
            start: Date,
            end: Date,
            app: AppSnapshot?,
            dayInterval: DateInterval,
            buckets: inout [Int64: HourBucket]
        ) {
            var cursor = start
            while cursor < end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let bucketStart = max(hour.start, dayInterval.start)
                let bucketEnd = min(hour.end, dayInterval.end)
                let portionEnd = min(end, bucketEnd)
                guard portionEnd > cursor else { break }

                let key = Int64(hour.start.timeIntervalSince1970)
                var bucket = buckets[key] ?? HourBucket(start: bucketStart, end: bucketEnd)
                let duration = portionEnd.timeIntervalSince(cursor)
                bucket.total += duration

                if let app {
                    let appKey = app.bundleIdentifier ?? "name:\(app.name.lowercased())"
                    var counter = bucket.applications[appKey] ?? AppCounter(
                        bundleIdentifier: app.bundleIdentifier,
                        displayName: app.name
                    )
                    counter.duration += duration
                    bucket.applications[appKey] = counter
                }

                buckets[key] = bucket
                cursor = portionEnd
            }
        }
    }
#endif
