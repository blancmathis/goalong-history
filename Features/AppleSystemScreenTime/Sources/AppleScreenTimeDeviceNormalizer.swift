#if os(macOS)
    import AppleScreenTime
    import Foundation

    public enum AppleScreenTimeDeviceNormalizer {
        public static func normalize(
            _ collection: AppleSystemScreenTimeCollection,
            currentMac: AppleScreenTimeDevice
        ) -> AppleSystemScreenTimeCollection {
            guard let stored = collection.storedExport else {
                let displayedDevices = presentedDevices(
                    collection.availableDevices + [currentMac],
                    currentMacID: currentMac.id
                )
                return AppleSystemScreenTimeCollection(
                    storedExport: nil,
                    availableDevices: displayedDevices,
                    status: brandedStatus(collection.status),
                    deviceSourceLabels: Dictionary(uniqueKeysWithValues: displayedDevices.map { device in
                        (
                            device.id,
                            collection.deviceSourceLabels[device.id]
                                ?? (device.id == currentMac.id ? "Apple system usage" : "Apple iCloud sync")
                        )
                    }),
                    latestAppleUpdate: collection.latestAppleUpdate,
                    knowledgeIntervalCount: collection.knowledgeIntervalCount,
                    biomeIntervalCount: collection.biomeIntervalCount,
                    screenTimeAppUsageIntervalCount: collection.screenTimeAppUsageIntervalCount,
                    storageState: collection.storageState
                )
            }

            if stored.envelope.provenance.usesAppleSettingsObservablePresentation {
                let displayedDevices = presentedDevices(
                    collection.availableDevices,
                    currentMacID: currentMac.id
                )
                let devicesByID = Dictionary(uniqueKeysWithValues: displayedDevices.map { ($0.id, $0) })
                let displayedReports = stored.envelope.reports.map { report in
                    AppleScreenTimeDeviceReport(
                        device: devicesByID[report.device.id] ?? report.device,
                        lastUpdatedAt: report.lastUpdatedAt,
                        segments: report.segments
                    )
                }
                let normalizedStored = AppleScreenTimeStoredExport(
                    importedAt: stored.importedAt,
                    verification: stored.verification,
                    envelope: AppleScreenTimeExportEnvelope(
                        schemaVersion: stored.envelope.schemaVersion,
                        createdAt: stored.envelope.createdAt,
                        requestedStart: stored.envelope.requestedStart,
                        requestedEnd: stored.envelope.requestedEnd,
                        requestedScope: stored.envelope.requestedScope,
                        provenance: stored.envelope.provenance,
                        reports: displayedReports
                    )
                )
                return AppleSystemScreenTimeCollection(
                    storedExport: normalizedStored,
                    availableDevices: displayedDevices,
                    status: brandedStatus(collection.status),
                    deviceSourceLabels: Dictionary(uniqueKeysWithValues: displayedDevices.map { device in
                        (device.id, collection.deviceSourceLabels[device.id] ?? "Apple Settings")
                    }),
                    latestAppleUpdate: collection.latestAppleUpdate,
                    knowledgeIntervalCount: 0,
                    biomeIntervalCount: 0,
                    screenTimeAppUsageIntervalCount: 0,
                    storageState: collection.storageState
                )
            }

            // The source has already filtered idle catalogue peers to conservative matches with
            // recent trusted Apple-account devices. Preserve those choices here, while collapsing
            // duplicate aliases that Apple emitted for the same activity.
            let reports = deduplicatedReports(stored.envelope.reports, currentMacID: currentMac.id)
            let rawAvailable = uniqueDevices(
                collection.availableDevices + reports.map(\.device) + [currentMac]
            )
            let displayedDevices = presentedDevices(rawAvailable, currentMacID: currentMac.id)
            let devicesByID = Dictionary(uniqueKeysWithValues: displayedDevices.map { ($0.id, $0) })
            let displayedReports = reports.map { report in
                AppleScreenTimeDeviceReport(
                    device: devicesByID[report.device.id] ?? report.device,
                    lastUpdatedAt: report.lastUpdatedAt,
                    segments: report.segments
                )
            }

            let envelope = AppleScreenTimeExportEnvelope(
                schemaVersion: stored.envelope.schemaVersion,
                createdAt: stored.envelope.createdAt,
                requestedStart: stored.envelope.requestedStart,
                requestedEnd: stored.envelope.requestedEnd,
                requestedScope: stored.envelope.requestedScope,
                provenance: stored.envelope.provenance,
                reports: displayedReports
            )
            let normalizedStored = AppleScreenTimeStoredExport(
                importedAt: stored.importedAt,
                verification: stored.verification,
                envelope: envelope
            )

            var labels: [String: String] = [:]
            for device in displayedDevices {
                labels[device.id] = collection.deviceSourceLabels[device.id]
                    ?? (device.id == currentMac.id ? "Apple system usage" : "Apple iCloud sync")
            }

            return AppleSystemScreenTimeCollection(
                storedExport: normalizedStored,
                availableDevices: displayedDevices,
                status: brandedStatus(collection.status),
                deviceSourceLabels: labels,
                latestAppleUpdate: collection.latestAppleUpdate,
                knowledgeIntervalCount: collection.knowledgeIntervalCount,
                biomeIntervalCount: collection.biomeIntervalCount,
                screenTimeAppUsageIntervalCount: collection.screenTimeAppUsageIntervalCount,
                storageState: collection.storageState
            )
        }

        static func deduplicatedReports(
            _ reports: [AppleScreenTimeDeviceReport],
            currentMacID: String
        ) -> [AppleScreenTimeDeviceReport] {
            var output: [AppleScreenTimeDeviceReport] = []
            var indexByIdentityAndFingerprint: [String: Int] = [:]
            var indexByFingerprint: [String: Int] = [:]

            let ordered = reports.sorted {
                reportPriority($0, currentMacID: currentMacID)
                    > reportPriority($1, currentMacID: currentMacID)
            }

            for report in ordered {
                let fingerprint = reportFingerprint(report)
                let exactKey = normalizedIdentity(report.device, currentMacID: currentMacID) + "|" + fingerprint

                if let index = indexByIdentityAndFingerprint[exactKey] {
                    if reportPriority(report, currentMacID: currentMacID)
                        > reportPriority(output[index], currentMacID: currentMacID)
                    {
                        output[index] = report
                    }
                    continue
                }

                // A generic Apple peer and a named iPhone/iPad peer with exactly the same usage
                // are aliases, not two devices. Never apply this shortcut to the current Mac.
                if let index = indexByFingerprint[fingerprint],
                   output[index].device.id != currentMacID,
                   report.device.id != currentMacID,
                   (isGeneric(output[index].device) || isGeneric(report.device))
                {
                    if reportPriority(report, currentMacID: currentMacID)
                        > reportPriority(output[index], currentMacID: currentMacID)
                    {
                        let previous = output[index]
                        indexByIdentityAndFingerprint.removeValue(
                            forKey: normalizedIdentity(previous.device, currentMacID: currentMacID) + "|" + fingerprint
                        )
                        output[index] = report
                        indexByIdentityAndFingerprint[exactKey] = index
                    }
                    continue
                }

                let index = output.count
                output.append(report)
                indexByIdentityAndFingerprint[exactKey] = index
                indexByFingerprint[fingerprint] = index
            }

            return output.sorted { lhs, rhs in
                if lhs.device.id == currentMacID { return true }
                if rhs.device.id == currentMacID { return false }
                if lhs.device.kind.rawValue != rhs.device.kind.rawValue {
                    return lhs.device.kind.rawValue < rhs.device.kind.rawValue
                }
                return lhs.device.displayName.localizedCaseInsensitiveCompare(rhs.device.displayName) == .orderedAscending
            }
        }

        static func presentedDevices(
            _ devices: [AppleScreenTimeDevice],
            currentMacID: String
        ) -> [AppleScreenTimeDevice] {
            let unique = uniqueDevices(devices)
            let bases = Dictionary(uniqueKeysWithValues: unique.map {
                ($0.id, baseName(for: $0, currentMacID: currentMacID))
            })
            let totals = Dictionary(grouping: unique, by: {
                (bases[$0.id] ?? $0.displayName).lowercased()
            }).mapValues(\.count)

            return unique
                .sorted { lhs, rhs in
                    if lhs.id == currentMacID { return true }
                    if rhs.id == currentMacID { return false }
                    let left = bases[lhs.id] ?? lhs.displayName
                    let right = bases[rhs.id] ?? rhs.displayName
                    let comparison = left.localizedCaseInsensitiveCompare(right)
                    return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
                }
                .map { device in
                    let base = bases[device.id] ?? device.displayName
                    let key = base.lowercased()
                    let needsStableTag = device.id != currentMacID
                        && (isGeneric(device) || (totals[key] ?? 0) > 1)
                    let name = needsStableTag
                        ? stableTaggedName(base, deviceID: device.id)
                        : base
                    return AppleScreenTimeDevice(
                        id: device.id,
                        name: name,
                        kind: inferredKind(for: device)
                    )
                }
        }

        private static func uniqueDevices(_ devices: [AppleScreenTimeDevice]) -> [AppleScreenTimeDevice] {
            var seen = Set<String>()
            return devices.filter { seen.insert($0.id).inserted }
        }

        private static func reportPriority(
            _ report: AppleScreenTimeDeviceReport,
            currentMacID: String
        ) -> Int {
            var value = report.device.id == currentMacID ? 1_000 : 0
            if inferredKind(for: report.device) != .unknown { value += 100 }
            if !isGeneric(report.device) { value += 10 }
            value += min(9, report.segments.count)
            return value
        }

        private static func normalizedIdentity(
            _ device: AppleScreenTimeDevice,
            currentMacID: String
        ) -> String {
            if device.id == currentMacID { return "current-mac:\(currentMacID)" }
            let cleaned = device.displayName
                .components(separatedBy: " · ")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? device.displayName.lowercased()
            return "\(inferredKind(for: device).rawValue):\(cleaned)"
        }

        private static func reportFingerprint(_ report: AppleScreenTimeDeviceReport) -> String {
            report.segments.map { segment in
                let apps = segment.applications
                    .sorted { $0.id < $1.id }
                    .map { "\($0.id)=\(Int($0.duration.rounded()))" }
                    .joined(separator: ",")
                return [
                    String(Int(segment.start.timeIntervalSince1970.rounded())),
                    String(Int(segment.end.timeIntervalSince1970.rounded())),
                    String(Int(segment.totalScreenOnDuration.rounded())),
                    apps,
                ].joined(separator: ":")
            }.joined(separator: "|")
        }

        private static func baseName(
            for device: AppleScreenTimeDevice,
            currentMacID: String
        ) -> String {
            let cleaned = device.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if device.id == currentMacID {
                return cleaned.isEmpty ? "This Mac" : cleaned
            }
            return cleaned.isEmpty ? inferredKind(for: device).displayName : cleaned
        }

        private static func inferredKind(for device: AppleScreenTimeDevice) -> AppleScreenTimeDeviceKind {
            guard device.kind == .unknown else { return device.kind }
            let lower = device.displayName.lowercased()
            if lower.contains("ipad") && !lower.contains("iphone or ipad") { return .iPad }
            if lower.contains("iphone") && !lower.contains("iphone or ipad") { return .iPhone }
            if lower.contains("ipod") { return .iPod }
            if lower.contains("watch") { return .appleWatch }
            if lower.contains("apple tv") || lower.contains("appletv") { return .appleTV }
            if lower.contains("homepod") { return .homePod }
            if lower.contains("vision pro") || lower.contains("realitydevice") { return .visionPro }
            if lower.contains("mac") { return .mac }
            return .unknown
        }

        private static func stableTaggedName(_ name: String, deviceID: String) -> String {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.contains(" · ") { return cleaned }
            let tag = AppleScreenTimeDeviceIdentityResolver.stablePeerTag(deviceID)
            guard !tag.isEmpty else { return cleaned }
            return "\(cleaned) · \(tag)"
        }

        private static func isGeneric(_ device: AppleScreenTimeDevice) -> Bool {
            let normalized = device.displayName
                .components(separatedBy: " · ")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                ?? device.displayName.lowercased()
            return inferredKind(for: device) == .unknown
                || normalized == "apple device"
                || normalized == "unknown device"
                || normalized == "iphone or ipad"
        }

        private static func brandedStatus(_ status: AppleSystemScreenTimeStatus) -> AppleSystemScreenTimeStatus {
            AppleSystemScreenTimeStatus(
                kind: status.kind,
                title: status.title.replacingOccurrences(of: "LocalHistory", with: "Goalong History"),
                message: status.message.replacingOccurrences(of: "LocalHistory", with: "Goalong History")
            )
        }
    }
#endif
