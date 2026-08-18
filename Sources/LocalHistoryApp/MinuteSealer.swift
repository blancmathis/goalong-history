#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import Security

    final class MinuteSealer {
        private let queue = DispatchQueue(label: "ai.goalong.localhistory.minute-sealer")
        private let stateStore: IntegrityStateStore
        private let identity: DeviceIdentity
        private weak var uploader: CommitmentUploader?

        private var timer: DispatchSourceTimer?
        private var currentMinuteStart: Date
        private var currentEventRoots: [String] = []
        private var currentCoverageStates: Set<String> = ["captured"]
        private var carriedCoverageState = "captured"

        init(stateStore: IntegrityStateStore, identity: DeviceIdentity) {
            self.stateStore = stateStore
            self.identity = identity
            self.currentMinuteStart = Self.floorToMinute(Date())
        }

        func setUploader(_ uploader: CommitmentUploader?) {
            queue.async { [weak self] in self?.uploader = uploader }
        }

        func start() {
            queue.async { [weak self] in
                guard let self, self.timer == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.sealElapsedMinutes(now: Date()) }
                self.timer = timer
                timer.resume()
            }
        }

        func stopAndSeal() {
            queue.sync {
                timer?.cancel()
                timer = nil
                sealElapsedMinutes(now: Date())
                // Seal the current partial minute on clean shutdown so the last events are not orphaned.
                // A restart within the same wall-clock minute creates a second, independently chained seal.
                sealCurrentMinute()
                currentEventRoots = []
            }
        }

        func receive(_ event: HistoryEvent) {
            guard let root = event.integrity?.eventRoot else { return }
            queue.async { [weak self] in
                guard let self else { return }
                let eventMinute = Self.floorToMinute(event.timestamp)
                self.advance(to: eventMinute)
                if eventMinute == self.currentMinuteStart {
                    self.currentEventRoots.append(root)
                    self.observeCoverage(from: event)
                }
            }
        }

        private func observeCoverage(from event: HistoryEvent) {
            var state = event.suppressionReason?.rawValue ?? carriedCoverageState

            switch event.kind {
            case .recordingPaused:
                state = "manualPause"
            case .recordingResumed, .captureResumed, .sessionUnlocked, .systemWake:
                state = "captured"
            case .sessionLocked:
                state = "sessionUnavailable"
            case .systemSleep:
                state = "systemSleep"
            case .secureInputSuppressed:
                state = "secureInput"
            case .secureInputResumed:
                state = "captured"
            case .permissionStatus:
                if event.metadata?["accessibility"] == "false" || event.metadata?["input_monitoring"] == "false" {
                    state = "permissionsMissing"
                } else {
                    state = "captured"
                }
            default:
                if event.suppressionReason == nil, event.kind != .captureSuppressed {
                    state = carriedCoverageState == "privateBrowserWindow" ? "captured" : carriedCoverageState
                }
            }

            carriedCoverageState = state
            currentCoverageStates.insert(state)
        }

        private func sealElapsedMinutes(now: Date) {
            let nowMinute = Self.floorToMinute(now)
            advance(to: nowMinute)
        }

        private func advance(to targetMinute: Date) {
            guard targetMinute >= currentMinuteStart else { return }
            while currentMinuteStart < targetMinute {
                sealCurrentMinute()
                currentMinuteStart = currentMinuteStart.addingTimeInterval(60)
                currentEventRoots = []
                currentCoverageStates = [carriedCoverageState]
            }
        }

        private func sealCurrentMinute() {
            do {
                let position = stateStore.takeAnchorPosition()
                let minuteEnd = currentMinuteStart.addingTimeInterval(60)
                let eventsRoot = MerkleTree.root(
                    labeledHexValues: currentEventRoots.enumerated().map { ("event:\($0.offset)", $0.element) }
                )

                let minuteFields: [LocalFieldCommitment] = [
                    CommitmentBuilder.makeMinute(
                        name: "time",
                        fields: [
                            "start": Self.iso8601(currentMinuteStart),
                            "end": Self.iso8601(minuteEnd),
                            "local_day": AppPaths.localDayString(for: currentMinuteStart),
                            "timezone": TimeZone.current.identifier,
                            "utc_offset_seconds": String(TimeZone.current.secondsFromGMT(for: currentMinuteStart)),
                        ],
                        salt: Self.randomBytes(count: 32)
                    ),
                    CommitmentBuilder.makeMinute(
                        name: "events_root",
                        fields: ["events_root": eventsRoot],
                        salt: Self.randomBytes(count: 32)
                    ),
                    CommitmentBuilder.makeMinute(
                        name: "event_count",
                        fields: ["count": String(currentEventRoots.count)],
                        salt: Self.randomBytes(count: 32)
                    ),
                    CommitmentBuilder.makeMinute(
                        name: "coverage",
                        fields: ["states": currentCoverageStates.sorted().joined(separator: ",")],
                        salt: Self.randomBytes(count: 32)
                    ),
                ]

                let byName = Dictionary(uniqueKeysWithValues: minuteFields.map { ($0.name, $0.commitmentHex) })
                let leaves = IntegrityDomains.minuteFieldOrder.compactMap { name -> (String, String)? in
                    guard let value = byName[name] else { return nil }
                    return (name, value)
                }
                let minuteRoot = MerkleTree.root(labeledHexValues: leaves)
                let anchorHash = ChainHash.anchor(
                    sequence: position.sequence,
                    previous: position.previousHash,
                    minuteRoot: minuteRoot
                )
                let signingMessage = ChainHash.signingMessage(
                    deviceID: identity.info.deviceID,
                    sequence: position.sequence,
                    previous: position.previousHash,
                    minuteRoot: minuteRoot
                )
                let signature = try identity.sign(signingMessage)

                let seal = LocalMinuteSeal(
                    anchorSequence: position.sequence,
                    minuteStart: currentMinuteStart,
                    minuteEnd: minuteEnd,
                    minuteFields: minuteFields,
                    eventRoots: currentEventRoots,
                    minuteRoot: minuteRoot,
                    previousAnchorHash: position.previousHash,
                    anchorHash: anchorHash,
                    deviceID: identity.info.deviceID,
                    publicKeyBase64: identity.info.publicKeyBase64,
                    trustTier: identity.info.trustTier,
                    signatureBase64: signature.base64EncodedString(),
                    signatureAlgorithm: identity.info.algorithm
                )

                try Self.appendJSONLine(seal, to: AppPaths.sealFileURL(for: currentMinuteStart))
                stateStore.commitAnchor(sequence: position.sequence, anchorHash: anchorHash)
                uploader?.enqueue(seal)
            } catch {
                Diagnostics.write("Failed to seal minute: \(error)")
            }
        }

        private static func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
            try AppPaths.prepare()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(value)
            data.append(0x0A)

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        private static func floorToMinute(_ date: Date) -> Date {
            Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60.0) * 60.0)
        }

        private static func iso8601(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private static func randomBytes(count: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess {
                return Data(bytes)
            }
            return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
        }
    }
#endif
