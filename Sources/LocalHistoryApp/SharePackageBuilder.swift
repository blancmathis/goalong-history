#if os(macOS)
    import Foundation
    import LocalHistoryCore

    struct ShareMinuteRow {
        let anchorSequence: UInt64
        let start: Date
        let end: Date
        let appSummary: String
        let categorySummary: String
        let canRevealDetails: Bool
        var level: ShareLevel
    }

    enum ShareBuildError: Error, CustomStringConvertible {
        case noSeals
        case brokenSeal(UInt64)
        case missingEvents(UInt64)
        case brokenEvent(String)
        case inconsistentDevice

        var description: String {
            switch self {
            case .noSeals: return "No sealed minutes are available for this day."
            case .brokenSeal(let sequence): return "Minute seal \(sequence) failed local integrity validation."
            case .missingEvents(let sequence): return "The detailed events for minute seal \(sequence) are no longer available. Use Completely private for that minute."
            case .brokenEvent(let root): return "Event \(root.prefix(12))… failed local integrity validation."
            case .inconsistentDevice: return "The selected day contains seals from inconsistent device identities."
            }
        }
    }

    final class SharePackageBuilder {
        private let decoder: JSONDecoder

        init() {
            decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
        }

        func minuteRows(for day: Date = Date()) throws -> [ShareMinuteRow] {
            let seals = try loadSeals(for: day)
            guard !seals.isEmpty else { throw ShareBuildError.noSeals }
            let events = loadEventsByRoot(for: day)

            return seals.map { seal in
                let available = seal.eventRoots.allSatisfy { events[$0] != nil }
                let minuteEvents = seal.eventRoots.compactMap { events[$0] }
                let apps = uniqueValues(minuteEvents.compactMap { openingFields($0, name: "application")?["name"] }.filter { !$0.isEmpty })
                let categories = uniqueValues(minuteEvents.compactMap { openingFields($0, name: "classification")?["category"] }.filter { !$0.isEmpty })
                return ShareMinuteRow(
                    anchorSequence: seal.anchorSequence,
                    start: seal.minuteStart,
                    end: seal.minuteEnd,
                    appSummary: apps.isEmpty ? "—" : apps.joined(separator: ", "),
                    categorySummary: categories.isEmpty ? "—" : categories.joined(separator: ", "),
                    canRevealDetails: available,
                    level: available ? .applicationOnly : .privateOnly
                )
            }
        }

        func build(for day: Date = Date(), levels: [UInt64: ShareLevel]) throws -> DaySharePackage {
            let seals = try loadSeals(for: day)
            guard let first = seals.first, let last = seals.last else { throw ShareBuildError.noSeals }
            guard seals.allSatisfy({ $0.deviceID == first.deviceID }) else { throw ShareBuildError.inconsistentDevice }

            let eventsByRoot = loadEventsByRoot(for: day)
            let receipts = loadReceiptsBySequence()
            let disclosures = try seals.map { seal in
                try makeDisclosure(
                    seal: seal,
                    level: levels[seal.anchorSequence] ?? .privateOnly,
                    eventsByRoot: eventsByRoot,
                    receipts: receipts
                )
            }

            // Boundary proofs prevent a user from silently dropping the first/last bad minutes of a calendar day.
            // They reveal only time + coverage for the immediately adjacent anchor, never its event structure.
            let all = loadAllSeals()
            let bySequence = Dictionary(uniqueKeysWithValues: all.map { ($0.anchorSequence, $0) })
            let boundaryBefore: MinuteDisclosure?
            if first.anchorSequence > 1, let seal = bySequence[first.anchorSequence - 1] {
                boundaryBefore = try makeDisclosure(seal: seal, level: .privateOnly, eventsByRoot: [:], receipts: receipts)
            } else {
                boundaryBefore = nil
            }
            let boundaryAfter: MinuteDisclosure?
            if let seal = bySequence[last.anchorSequence + 1] {
                boundaryAfter = try makeDisclosure(seal: seal, level: .privateOnly, eventsByRoot: [:], receipts: receipts)
            } else {
                boundaryAfter = nil
            }

            return DaySharePackage(
                deviceID: first.deviceID,
                localDay: AppPaths.localDayString(for: day),
                classifierVersion: LocalClassifier.version,
                boundaryBefore: boundaryBefore,
                boundaryAfter: boundaryAfter,
                minutes: disclosures
            )
        }

        func write(_ package: DaySharePackage, to url: URL) throws {
            let output = JSONEncoder()
            output.dateEncodingStrategy = .iso8601
            output.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try output.encode(package)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        private func makeDisclosure(
            seal: LocalMinuteSeal,
            level: ShareLevel,
            eventsByRoot: [String: HistoryEvent],
            receipts: [UInt64: AnchorReceipt]
        ) throws -> MinuteDisclosure {
            guard verifyLocalSeal(seal) else { throw ShareBuildError.brokenSeal(seal.anchorSequence) }

            let minuteFields = seal.minuteFields.map { field -> FieldDisclosure in
                let revealOpening: Bool
                switch field.name {
                case "time", "coverage":
                    revealOpening = true
                case "events_root", "event_count":
                    revealOpening = level != .privateOnly
                default:
                    revealOpening = false
                }
                return FieldDisclosure(
                    name: field.name,
                    commitmentHex: field.commitmentHex,
                    opening: revealOpening ? field.opening : nil
                )
            }

            var eventRoots: [String]? = nil
            var eventDisclosures: [EventDisclosure]? = nil
            if level != .privateOnly {
                var built: [EventDisclosure] = []
                for root in seal.eventRoots {
                    guard let event = eventsByRoot[root] else { throw ShareBuildError.missingEvents(seal.anchorSequence) }
                    guard verifyLocalEvent(event) else { throw ShareBuildError.brokenEvent(root) }

                    let commitments = event.integrity?.fieldCommitments ?? []
                    let fields = commitments.map { field -> FieldDisclosure in
                        let reveal: Bool
                        switch level {
                        case .everything:
                            reveal = true
                        case .applicationOnly:
                            reveal = ["time", "application", "coverage", "trust"].contains(field.name)
                        case .categoryOnly:
                            reveal = ["time", "classification", "coverage", "trust"].contains(field.name)
                        case .privateOnly:
                            reveal = false
                        }
                        return FieldDisclosure(
                            name: field.name,
                            commitmentHex: field.commitmentHex,
                            opening: reveal ? field.opening : nil
                        )
                    }
                    built.append(EventDisclosure(eventRoot: root, fieldCommitments: fields, rawEvent: nil))
                }
                eventRoots = seal.eventRoots
                eventDisclosures = built
            }

            let receipt = receipts[seal.anchorSequence]
            let disclosure = MinuteDisclosure(
                anchorSequence: seal.anchorSequence,
                minuteRoot: seal.minuteRoot,
                previousAnchorHash: seal.previousAnchorHash,
                anchorHash: seal.anchorHash,
                shareLevel: level,
                minuteFields: minuteFields,
                eventRoots: eventRoots,
                events: eventDisclosures,
                signatureBase64: seal.signatureBase64,
                signatureAlgorithm: seal.signatureAlgorithm,
                publicKeyBase64: seal.publicKeyBase64,
                deviceID: seal.deviceID,
                trustTier: receipt?.appAttestAccepted == true ? "app_attest" : seal.trustTier,
                liveReceiptID: receipt?.receiptID
            )
            guard disclosure.verifiesStructure() else { throw ShareBuildError.brokenSeal(seal.anchorSequence) }
            return disclosure
        }

        private func verifyLocalSeal(_ seal: LocalMinuteSeal) -> Bool {
            guard seal.minuteFields.allSatisfy({ $0.opening.commitmentHex() == $0.commitmentHex }) else { return false }
            let byName = Dictionary(uniqueKeysWithValues: seal.minuteFields.map { ($0.name, $0.commitmentHex) })
            let leaves = IntegrityDomains.minuteFieldOrder.compactMap { name -> (String, String)? in
                guard let value = byName[name] else { return nil }
                return (name, value)
            }
            guard leaves.count == IntegrityDomains.minuteFieldOrder.count else { return false }
            guard MerkleTree.root(labeledHexValues: leaves) == seal.minuteRoot else { return false }
            guard ChainHash.anchor(sequence: seal.anchorSequence, previous: seal.previousAnchorHash, minuteRoot: seal.minuteRoot) == seal.anchorHash else { return false }
            let eventsRoot = MerkleTree.root(labeledHexValues: seal.eventRoots.enumerated().map { ("event:\($0.offset)", $0.element) })
            guard let rootField = seal.minuteFields.first(where: { $0.name == "events_root" }),
                  rootField.opening.fields["events_root"] == eventsRoot,
                  let countField = seal.minuteFields.first(where: { $0.name == "event_count" }),
                  countField.opening.fields["count"] == String(seal.eventRoots.count)
            else { return false }
            return true
        }

        private func verifyLocalEvent(_ event: HistoryEvent) -> Bool {
            guard let integrity = event.integrity else { return false }
            guard integrity.fieldCommitments.allSatisfy({ $0.opening.commitmentHex() == $0.commitmentHex }) else { return false }
            let byName = Dictionary(uniqueKeysWithValues: integrity.fieldCommitments.map { ($0.name, $0.commitmentHex) })
            let leaves = IntegrityDomains.eventFieldOrder.compactMap { name -> (String, String)? in
                guard let value = byName[name] else { return nil }
                return (name, value)
            }
            guard leaves.count == IntegrityDomains.eventFieldOrder.count else { return false }
            guard MerkleTree.root(labeledHexValues: leaves) == integrity.eventRoot else { return false }
            return ChainHash.event(sequence: integrity.sequence, previous: integrity.previousEventHash, eventRoot: integrity.eventRoot) == integrity.eventHash
        }

        private func openingFields(_ event: HistoryEvent, name: String) -> [String: String]? {
            event.integrity?.fieldCommitments.first(where: { $0.name == name })?.opening.fields
        }

        private func loadSeals(for day: Date) throws -> [LocalMinuteSeal] {
            let file = AppPaths.sealFileURL(for: day)
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try decodeSealFile(file)
        }

        private func loadAllSeals() -> [LocalMinuteSeal] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.sealsDirectory, includingPropertiesForKeys: nil) else { return [] }
            return files
                .filter { $0.lastPathComponent.hasSuffix(".seals.jsonl") }
                .flatMap { (try? decodeSealFile($0)) ?? [] }
                .sorted { $0.anchorSequence < $1.anchorSequence }
        }

        private func decodeSealFile(_ file: URL) throws -> [LocalMinuteSeal] {
            let text = try String(contentsOf: file, encoding: .utf8)
            return text.split(separator: "\n").compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(LocalMinuteSeal.self, from: data)
            }.sorted { $0.anchorSequence < $1.anchorSequence }
        }

        private func loadEventsByRoot(for day: Date) -> [String: HistoryEvent] {
            let file = AppPaths.eventFileURL(for: day)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
            var result: [String: HistoryEvent] = [:]
            for line in text.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(HistoryEvent.self, from: data),
                      let root = event.integrity?.eventRoot
                else { continue }
                result[root] = event
            }
            return result
        }

        private func loadReceiptsBySequence() -> [UInt64: AnchorReceipt] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.receiptsDirectory, includingPropertiesForKeys: nil) else { return [:] }
            var result: [UInt64: AnchorReceipt] = [:]
            for file in files where file.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard let data = String(line).data(using: .utf8),
                          let receipt = try? decoder.decode(AnchorReceipt.self, from: data)
                    else { continue }
                    result[receipt.anchorSequence] = receipt
                }
            }
            return result
        }

        private func uniqueValues(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
    }
#endif
