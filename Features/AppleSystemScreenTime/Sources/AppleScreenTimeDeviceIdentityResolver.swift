#if os(macOS)
    import AppleScreenTime
    import Foundation

    struct AppleAccountDeviceMetadata: Equatable, Sendable {
        let name: String
        let model: String?
        let operatingSystem: String?
        let lastUpdatedAt: Date?

        var kind: AppleScreenTimeDeviceKind {
            AppleScreenTimeDeviceIdentityResolver.deviceKind(
                model: model,
                name: name,
                operatingSystem: operatingSystem
            )
        }
    }

    enum AppleScreenTimeDeviceIdentityResolver {
        private static let accountDeviceFreshness: TimeInterval = 366 * 24 * 60 * 60

        static func resolve(
            reports: [AppleScreenTimeDeviceReport],
            accountDevices: [AppleAccountDeviceMetadata],
            currentMacID: String,
            now: Date
        ) -> [AppleScreenTimeDeviceReport] {
            let candidates = activeAccountDevices(accountDevices, now: now)
            var usedCandidateIndexes = Set<Int>()
            var resolvedDevices: [String: AppleScreenTimeDevice] = [:]
            var unresolvedReports: [AppleScreenTimeDeviceReport] = []

            for report in reports {
                guard report.device.id != currentMacID else {
                    resolvedDevices[report.device.id] = report.device
                    continue
                }

                let inferred = inferredKind(for: report)
                if let index = exactModelCandidate(
                    for: report.device,
                    candidates: candidates,
                    excluding: usedCandidateIndexes
                ) ?? uniqueKindCandidate(
                    kind: inferred,
                    candidates: candidates,
                    excluding: usedCandidateIndexes
                ) {
                    usedCandidateIndexes.insert(index)
                    resolvedDevices[report.device.id] = resolvedDevice(
                        report.device,
                        metadata: candidates[index]
                    )
                } else if inferred == .appleWatch {
                    resolvedDevices[report.device.id] = stableFallbackDevice(
                        report.device,
                        inferredKind: .appleWatch
                    )
                } else {
                    unresolvedReports.append(report)
                }
            }

            let unusedCandidates = candidates.indices.filter { !usedCandidateIndexes.contains($0) }
            if unresolvedReports.count == 1, unusedCandidates.count == 1,
               let report = unresolvedReports.first,
               isCompatible(report.device, with: candidates[unusedCandidates[0]])
            {
                let index = unusedCandidates[0]
                resolvedDevices[report.device.id] = resolvedDevice(
                    report.device,
                    metadata: candidates[index]
                )
                unresolvedReports.removeAll()
            }

            for report in unresolvedReports {
                resolvedDevices[report.device.id] = stableFallbackDevice(
                    report.device,
                    inferredKind: inferredKind(for: report)
                )
            }

            return reports.map { report in
                AppleScreenTimeDeviceReport(
                    device: resolvedDevices[report.device.id] ?? report.device,
                    lastUpdatedAt: report.lastUpdatedAt,
                    segments: report.segments
                )
            }
        }

        /// Keeps devices selectable even on a day without usage, but only when the Biome peer
        /// can be associated conservatively with a trusted, recently updated Apple-account
        /// device. Activity-bearing reports always remain available for the historical day.
        static func selectableDevices(
            catalogDevices: [AppleScreenTimeDevice],
            reports: [AppleScreenTimeDeviceReport],
            accountDevices: [AppleAccountDeviceMetadata],
            currentMac: AppleScreenTimeDevice,
            now: Date
        ) -> [AppleScreenTimeDevice] {
            let candidates = activeAccountDevices(accountDevices, now: now)
            let consumedCandidateIndexes = Set(candidates.indices.filter { index in
                reports.contains { report in
                    report.device.kind == candidates[index].kind
                        && report.device.displayName.caseInsensitiveCompare(candidates[index].name) == .orderedSame
                }
            })
            let remainingCandidates = candidates.indices
                .filter { !consumedCandidateIndexes.contains($0) }
                .map { candidates[$0] }
            let reportedIDs = Set(reports.map(\.device.id))
            var devicesByID = [currentMac.id: currentMac]
            for report in reports {
                devicesByID[report.device.id] = report.device
            }

            let idlePeers = catalogDevices.filter {
                $0.id != currentMac.id && !reportedIDs.contains($0.id)
            }
            let peersByModel = Dictionary(grouping: idlePeers.compactMap { device -> (String, AppleScreenTimeDevice)? in
                guard let model = modelIdentifier(from: device) else { return nil }
                return (model.lowercased(), device)
            }, by: \.0)
            let candidatesByModel = Dictionary(grouping: remainingCandidates.compactMap {
                device -> (String, AppleAccountDeviceMetadata)? in
                guard let model = device.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !model.isEmpty
                else { return nil }
                return (model.lowercased(), device)
            }, by: \.0)
            let peersByKind = Dictionary(grouping: idlePeers.filter {
                inferredKind(for: $0) != .unknown && inferredKind(for: $0) != .mac
            }, by: { inferredKind(for: $0) })
            let candidatesByKind = Dictionary(grouping: remainingCandidates, by: \.kind)

            for peer in idlePeers {
                if let model = modelIdentifier(from: peer)?.lowercased(),
                   peersByModel[model]?.count == 1,
                   let matches = candidatesByModel[model],
                   matches.count == 1,
                   let metadata = matches.first?.1
                {
                    devicesByID[peer.id] = resolvedDevice(peer, metadata: metadata)
                    continue
                }

                let kind = inferredKind(for: peer)
                guard kind != .unknown, kind != .mac,
                      peersByKind[kind]?.count == 1,
                      let matches = candidatesByKind[kind],
                      matches.count == 1,
                      let metadata = matches.first
                else { continue }
                devicesByID[peer.id] = resolvedDevice(peer, metadata: metadata)
            }

            return Array(devicesByID.values)
        }

        static func deviceKind(
            model: String?,
            name: String? = nil,
            operatingSystem: String? = nil
        ) -> AppleScreenTimeDeviceKind {
            let values = [model, name, operatingSystem]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if values.contains(where: { $0.contains("iphone or ipad") }) { return .unknown }
            if values.contains(where: { $0.hasPrefix("iphone") || $0 == "ios-phone" }) { return .iPhone }
            if values.contains(where: { $0.hasPrefix("ipad") || $0 == "ipados" }) { return .iPad }
            if values.contains(where: { $0.hasPrefix("ipod") }) { return .iPod }
            if values.contains(where: { $0.hasPrefix("watch") || $0.contains("apple watch") || $0 == "watchos" }) {
                return .appleWatch
            }
            if values.contains(where: { $0.hasPrefix("appletv") || $0.contains("apple tv") || $0 == "tvos" }) {
                return .appleTV
            }
            if values.contains(where: { $0.hasPrefix("homepod") || $0.hasPrefix("audioaccessory") || $0 == "audioos" }) {
                return .homePod
            }
            if values.contains(where: {
                $0.hasPrefix("realitydevice") || $0.contains("vision pro") || $0 == "visionos"
            }) {
                return .visionPro
            }
            if values.contains(where: { $0.hasPrefix("mac") || $0 == "macos" }) { return .mac }
            return .unknown
        }

        static func hasWatchSignature(_ report: AppleScreenTimeDeviceReport) -> Bool {
            report.segments.contains { segment in
                segment.applications.contains { application in
                    let bundle = (application.bundleIdentifier ?? "").lowercased()
                    return bundle.hasPrefix("com.apple.carousel.")
                        || bundle.contains(".watchapp")
                        || bundle.contains(".watchkitapp")
                }
            }
        }

        static func stablePeerTag(_ id: String) -> String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(8)).uppercased()
        }

        private static func activeAccountDevices(
            _ devices: [AppleAccountDeviceMetadata],
            now: Date
        ) -> [AppleAccountDeviceMetadata] {
            var seenDevices = Set<String>()
            return devices
                .filter { device in
                    guard device.kind != .unknown, device.kind != .mac else { return false }
                    guard let updated = device.lastUpdatedAt else { return false }
                    return updated >= now.addingTimeInterval(-accountDeviceFreshness)
                        && updated <= now.addingTimeInterval(24 * 60 * 60)
                }
                .filter { device in
                    let key = [
                        device.kind.rawValue,
                        device.model?.lowercased() ?? "unknown-model",
                        device.name.lowercased(),
                    ].joined(separator: "|")
                    return seenDevices.insert(key).inserted
                }
        }

        private static func exactModelCandidate(
            for device: AppleScreenTimeDevice,
            candidates: [AppleAccountDeviceMetadata],
            excluding used: Set<Int>
        ) -> Int? {
            guard let model = modelIdentifier(from: device) else { return nil }
            let matches = candidates.indices.filter {
                !used.contains($0)
                    && candidates[$0].model?.caseInsensitiveCompare(model) == .orderedSame
            }
            return matches.count == 1 ? matches[0] : nil
        }

        private static func uniqueKindCandidate(
            kind: AppleScreenTimeDeviceKind,
            candidates: [AppleAccountDeviceMetadata],
            excluding used: Set<Int>
        ) -> Int? {
            guard kind != .unknown, kind != .mac else { return nil }
            let matches = candidates.indices.filter {
                !used.contains($0) && candidates[$0].kind == kind
            }
            return matches.count == 1 ? matches[0] : nil
        }

        private static func modelIdentifier(from device: AppleScreenTimeDevice) -> String? {
            let first = device.displayName
                .components(separatedBy: " · ")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard first.range(
                of: #"^(iPhone|iPad|iPod|Watch|Mac|AppleTV|HomePod|AudioAccessory|RealityDevice)[0-9]+,[0-9]+$"#,
                options: .regularExpression
            ) != nil
            else { return nil }
            return first
        }

        private static func inferredKind(
            for device: AppleScreenTimeDevice
        ) -> AppleScreenTimeDeviceKind {
            if device.kind != .unknown { return device.kind }
            return deviceKind(model: device.displayName)
        }

        private static func inferredKind(
            for report: AppleScreenTimeDeviceReport
        ) -> AppleScreenTimeDeviceKind {
            let fromName = inferredKind(for: report.device)
            if fromName != .unknown { return fromName }
            if hasWatchSignature(report) { return .appleWatch }
            return .unknown
        }

        private static func resolvedDevice(
            _ device: AppleScreenTimeDevice,
            metadata: AppleAccountDeviceMetadata
        ) -> AppleScreenTimeDevice {
            AppleScreenTimeDevice(
                id: device.id,
                name: metadata.name,
                kind: metadata.kind
            )
        }

        private static func stableFallbackDevice(
            _ device: AppleScreenTimeDevice,
            inferredKind: AppleScreenTimeDeviceKind
        ) -> AppleScreenTimeDevice {
            let tag = stablePeerTag(device.id)
            let current = device.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = current.components(separatedBy: " · ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base: String
            if inferredKind != .unknown {
                base = first.isEmpty || first.lowercased() == "apple device"
                    ? inferredKind.displayName
                    : first
            } else if first.lowercased().contains("iphone or ipad") {
                base = "iPhone or iPad"
            } else {
                base = "Apple device"
            }
            return AppleScreenTimeDevice(
                id: device.id,
                name: tag.isEmpty ? base : "\(base) · \(tag)",
                kind: inferredKind
            )
        }

        private static func isCompatible(
            _ device: AppleScreenTimeDevice,
            with metadata: AppleAccountDeviceMetadata
        ) -> Bool {
            let kind = device.kind == .unknown
                ? deviceKind(model: device.displayName)
                : device.kind
            return kind == .unknown || kind == metadata.kind
        }
    }
#endif
