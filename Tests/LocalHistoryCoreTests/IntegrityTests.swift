import Foundation
import XCTest

@testable import LocalHistoryCore

final class IntegrityTests: XCTestCase {
    func testSHA256KnownVector() {
        XCTAssertEqual(
            SHA256Digest.hashHex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testHexEncodingPreservesLeadingZeroesAndLowercase() {
        XCTAssertEqual(
            SHA256Digest.hex(Data([0x00, 0x01, 0x0F, 0x10, 0x7F, 0x80, 0xFE, 0xFF])),
            "00010f107f80feff"
        )
    }

    func testSaltedCommitmentDetectsModification() {
        let salt = Data(repeating: 7, count: 32)
        let commitment = CommitmentBuilder.make(
            name: "application",
            fields: ["name": "Visual Studio Code"],
            salt: salt
        )
        XCTAssertEqual(commitment.opening.commitmentHex(), commitment.commitmentHex)
        XCTAssertEqual(commitment.commitmentHex, "92674e10a952ccf3facb245a2040d6a55788ca2cbda72c48ce5831105f83d75e")

        let tampered = CommitmentOpening(
            domain: commitment.opening.domain,
            fields: ["name": "Safari"],
            saltBase64: commitment.opening.saltBase64
        )
        XCTAssertNotEqual(tampered.commitmentHex(), commitment.commitmentHex)
    }

    func testMerkleProofAndTampering() {
        let leaves = [
            ("a", SHA256Digest.hashHex("A")),
            ("b", SHA256Digest.hashHex("B")),
            ("c", SHA256Digest.hashHex("C")),
        ]
        let root = MerkleTree.root(labeledHexValues: leaves)
        let proof = MerkleTree.proof(labeledHexValues: leaves, index: 1)!
        XCTAssertTrue(MerkleTree.verify(label: "b", valueHex: leaves[1].1, proof: proof, expectedRoot: root))
        XCTAssertFalse(
            MerkleTree.verify(label: "b", valueHex: SHA256Digest.hashHex("fake"), proof: proof, expectedRoot: root))
    }

    func testApplicationOnlyDisclosureCanHideContext() {
        let fields = IntegrityDomains.eventFieldOrder.enumerated().map { index, name in
            CommitmentBuilder.make(
                name: name,
                fields: ["value": name == "application" ? "Visual Studio Code" : "secret-\(name)"],
                salt: Data(repeating: UInt8(index + 1), count: 32)
            )
        }
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.commitmentHex) })
        let root = MerkleTree.root(labeledHexValues: IntegrityDomains.eventFieldOrder.map { ($0, map[$0]!) })

        let disclosure = EventDisclosure(
            eventRoot: root,
            fieldCommitments: fields.map { field in
                FieldDisclosure(
                    name: field.name,
                    commitmentHex: field.commitmentHex,
                    opening: ["time", "application", "coverage", "trust"].contains(field.name) ? field.opening : nil
                )
            },
            rawEvent: nil
        )

        XCTAssertTrue(disclosure.verifiesRoot())
        XCTAssertNotNil(disclosure.fieldCommitments.first(where: { $0.name == "application" })?.opening)
        XCTAssertNil(disclosure.fieldCommitments.first(where: { $0.name == "context" })?.opening)
    }

    func testPrivateMinuteVerifiesWithoutRevealingEvents() {
        let minuteFields = IntegrityDomains.minuteFieldOrder.enumerated().map { index, name in
            CommitmentBuilder.makeMinute(
                name: name,
                fields: ["value": "hidden-\(name)"],
                salt: Data(repeating: UInt8(index + 11), count: 32)
            )
        }
        let map = Dictionary(uniqueKeysWithValues: minuteFields.map { ($0.name, $0.commitmentHex) })
        let minuteRoot = MerkleTree.root(labeledHexValues: IntegrityDomains.minuteFieldOrder.map { ($0, map[$0]!) })
        let previous = String(repeating: "0", count: 64)
        let anchorHash = ChainHash.anchor(sequence: 1, previous: previous, minuteRoot: minuteRoot)

        let disclosure = MinuteDisclosure(
            anchorSequence: 1,
            minuteRoot: minuteRoot,
            previousAnchorHash: previous,
            anchorHash: anchorHash,
            shareLevel: .privateOnly,
            minuteFields: minuteFields.map { field in
                FieldDisclosure(
                    name: field.name,
                    commitmentHex: field.commitmentHex,
                    opening: ["time", "coverage"].contains(field.name) ? field.opening : nil
                )
            },
            eventRoots: nil,
            events: nil,
            signatureBase64: nil,
            signatureAlgorithm: nil,
            publicKeyBase64: nil,
            deviceID: "device",
            trustTier: "local",
            liveReceiptID: nil
        )

        XCTAssertTrue(disclosure.verifiesStructure())
        XCTAssertNil(disclosure.minuteFields.first(where: { $0.name == "events_root" })?.opening)
        XCTAssertNil(disclosure.minuteFields.first(where: { $0.name == "event_count" })?.opening)
    }

    func testV3WebsiteDisclosureRevealsHostWithoutOpeningContext() {
        let fields = IntegrityDomains.eventFieldOrderV3.enumerated().map { index, name in
            let values: [String: String]
            switch name {
            case "website": values = ["host": "example.com", "redacted": "true"]
            case "context": values = ["url": "https://example.com/private/path", "window_title": "Private title"]
            default: values = ["value": name]
            }
            return CommitmentBuilder.make(
                name: name,
                fields: values,
                salt: Data(repeating: UInt8(index + 21), count: 32)
            )
        }
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.commitmentHex) })
        let root = MerkleTree.root(
            labeledHexValues: IntegrityDomains.eventFieldOrderV3.map { ($0, map[$0]!) }
        )

        let disclosure = EventDisclosure(
            eventRoot: root,
            fieldCommitments: fields.map { field in
                FieldDisclosure(
                    name: field.name,
                    commitmentHex: field.commitmentHex,
                    opening: ["time", "website", "coverage", "trust"].contains(field.name)
                        ? field.opening : nil
                )
            },
            rawEvent: nil,
            schemaVersion: 3,
            shareLevel: .applicationOnly
        )

        XCTAssertTrue(disclosure.verifiesRoot())
        XCTAssertEqual(
            disclosure.fieldCommitments.first(where: { $0.name == "website" })?.opening?.fields["host"],
            "example.com"
        )
        XCTAssertNil(disclosure.fieldCommitments.first(where: { $0.name == "context" })?.opening)
        XCTAssertNil(disclosure.fieldCommitments.first(where: { $0.name == "application" })?.opening)
    }

    func testSchemaV5EventPersistsOnlySaltsAndRehydratesFullCommitments() throws {
        let timestamp = Date(timeIntervalSince1970: 1_787_480_000)
        let uniqueWindowTitle = "Unique compact integrity window"
        let base = HistoryEvent(
            schemaVersion: 5,
            id: "event-v5",
            sessionID: "session-v5",
            timestamp: timestamp,
            kind: .mouseClick,
            app: AppSnapshot(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                processIdentifier: 42
            ),
            window: WindowSnapshot(
                title: uniqueWindowTitle,
                role: "AXWindow",
                subrole: "AXStandardWindow"
            ),
            element: ElementSnapshot(
                role: "AXButton",
                subrole: nil,
                title: "Save",
                label: "Save document",
                identifier: "save-button",
                isSecure: false
            ),
            url: URLSnapshot(
                value: "https://example.com/document/42",
                host: "example.com",
                redactionApplied: false
            ),
            pointer: PointerSnapshot(button: "left", x: 120, y: 80, clickCount: 1),
            inputOrigin: InputOriginSnapshot(
                sourceProcessIdentifier: nil,
                sourceUserIdentifier: nil,
                sourceStateID: nil,
                sourceProcessName: nil,
                sourceBundleIdentifier: nil,
                assessment: .hidLike
            ),
            classification: LocalClassification(
                category: "work",
                isWork: true,
                confidence: 0.95,
                classifierVersion: "fixture"
            )
        )
        let order = IntegrityDomains.eventFieldOrder(for: base.schemaVersion)
        let commitments = EventIntegrityMaterial.makeFieldCommitments(
            for: base,
            salts: order.indices.map { Data(repeating: UInt8($0 + 1), count: 32) }
        )
        let byName = Dictionary(
            uniqueKeysWithValues: commitments.map { ($0.name, $0.commitmentHex) }
        )
        let root = MerkleTree.root(
            labeledHexValues: order.map { ($0, byName[$0]!) }
        )
        let previous = String(repeating: "0", count: 64)
        let compactIntegrity = EventIntegrity(
            sequence: 1,
            previousEventHash: previous,
            eventRoot: root,
            eventHash: ChainHash.event(sequence: 1, previous: previous, eventRoot: root),
            fieldCommitments: commitments,
            storageFormat: .compactSalts
        )
        let compactEvent = base.replacingIntegrity(compactIntegrity)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let compactData = try encoder.encode(compactEvent)
        let compactJSON = String(decoding: compactData, as: UTF8.self)
        XCTAssertTrue(compactJSON.contains("\"format\":\"salts-v1\""))
        XCTAssertTrue(compactJSON.contains("\"fieldSalts\""))
        XCTAssertFalse(compactJSON.contains("\"fieldCommitments\""))
        XCTAssertEqual(
            compactJSON.components(separatedBy: uniqueWindowTitle).count - 1,
            1,
            "The event field must not be copied into its persisted integrity envelope."
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryEvent.self, from: compactData)
        XCTAssertEqual(decoded, compactEvent)
        let decodedIntegrity = try XCTUnwrap(decoded.integrity)
        XCTAssertEqual(decodedIntegrity.storageFormat, .compactSalts)
        XCTAssertEqual(decodedIntegrity.fieldCommitments.count, order.count)
        XCTAssertTrue(
            decodedIntegrity.fieldCommitments.allSatisfy {
                $0.opening.commitmentHex() == $0.commitmentHex
            }
        )
        XCTAssertEqual(
            MerkleTree.root(
                labeledHexValues: order.map { name in
                    (name, decodedIntegrity.fieldCommitments.first { $0.name == name }!.commitmentHex)
                }
            ),
            root
        )

        let tamperedJSON = compactJSON.replacingOccurrences(
            of: uniqueWindowTitle,
            with: "Tampered compact integrity window"
        )
        let tampered = try decoder.decode(
            HistoryEvent.self,
            from: Data(tamperedJSON.utf8)
        )
        let tamperedIntegrity = try XCTUnwrap(tampered.integrity)
        let tamperedByName = Dictionary(
            uniqueKeysWithValues: tamperedIntegrity.fieldCommitments.map {
                ($0.name, $0.commitmentHex)
            }
        )
        XCTAssertNotEqual(
            MerkleTree.root(
                labeledHexValues: order.map { ($0, tamperedByName[$0]!) }
            ),
            tamperedIntegrity.eventRoot,
            "Changing a persisted event field must still break its stored integrity root."
        )

        let fullEvent = base.replacingIntegrity(
            EventIntegrity(
                sequence: compactIntegrity.sequence,
                previousEventHash: compactIntegrity.previousEventHash,
                eventRoot: compactIntegrity.eventRoot,
                eventHash: compactIntegrity.eventHash,
                fieldCommitments: commitments
            )
        )
        let fullData = try encoder.encode(fullEvent)
        XCTAssertLessThan(compactData.count * 2, fullData.count)

        let legacyDecoded = try decoder.decode(HistoryEvent.self, from: fullData)
        XCTAssertEqual(legacyDecoded, fullEvent)
        XCTAssertEqual(legacyDecoded.integrity?.storageFormat, .fullCommitments)
    }

    func testSchemaV2MinuteSealPersistsOnlySaltsAndRehydratesFullCommitments() throws {
        let minuteStart = Date(timeIntervalSince1970: 1_787_480_000)
        let minuteEnd = minuteStart.addingTimeInterval(60)
        let eventRoots = [SHA256Digest.hashHex("event-1"), SHA256Digest.hashHex("event-2")]
        let coverageFields = ["states": "captured"]
        let order = IntegrityDomains.minuteFieldOrder
        let commitments = MinuteIntegrityMaterial.makeFieldCommitments(
            minuteStart: minuteStart,
            minuteEnd: minuteEnd,
            localDay: "2026-08-23",
            timeZone: "Europe/Paris",
            utcOffsetSeconds: "7200",
            eventRoots: eventRoots,
            coverageFields: coverageFields,
            salts: order.indices.map { Data(repeating: UInt8($0 + 31), count: 32) }
        )
        let byName = Dictionary(
            uniqueKeysWithValues: commitments.map { ($0.name, $0.commitmentHex) }
        )
        let minuteRoot = MerkleTree.root(
            labeledHexValues: order.map { ($0, byName[$0]!) }
        )
        let previous = String(repeating: "0", count: 64)
        let compactSeal = LocalMinuteSeal(
            schemaVersion: 2,
            anchorSequence: 1,
            minuteStart: minuteStart,
            minuteEnd: minuteEnd,
            minuteFields: commitments,
            eventRoots: eventRoots,
            minuteRoot: minuteRoot,
            previousAnchorHash: previous,
            anchorHash: ChainHash.anchor(
                sequence: 1,
                previous: previous,
                minuteRoot: minuteRoot
            ),
            deviceID: "fixture-device",
            publicKeyBase64: Data("fixture-public-key".utf8).base64EncodedString(),
            trustTier: "local",
            signatureBase64: Data("fixture-signature".utf8).base64EncodedString(),
            signatureAlgorithm: "fixture",
            storageFormat: .compactSalts
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let compactData = try encoder.encode(compactSeal)
        let compactJSON = String(decoding: compactData, as: UTF8.self)
        XCTAssertTrue(compactJSON.contains("\"minuteIntegrity\""))
        XCTAssertTrue(compactJSON.contains("\"format\":\"salts-v1\""))
        XCTAssertFalse(compactJSON.contains("\"minuteFields\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LocalMinuteSeal.self, from: compactData)
        XCTAssertEqual(decoded, compactSeal)
        XCTAssertEqual(decoded.storageFormat, .compactSalts)
        XCTAssertEqual(decoded.minuteFields.map(\.name), order)
        XCTAssertTrue(
            decoded.minuteFields.allSatisfy {
                $0.opening.commitmentHex() == $0.commitmentHex
            }
        )
        let decodedByName = Dictionary(
            uniqueKeysWithValues: decoded.minuteFields.map {
                ($0.name, $0.commitmentHex)
            }
        )
        XCTAssertEqual(
            MerkleTree.root(labeledHexValues: order.map { ($0, decodedByName[$0]!) }),
            minuteRoot
        )

        let tamperedJSON = compactJSON.replacingOccurrences(
            of: "captured",
            with: "paused"
        )
        let tampered = try decoder.decode(
            LocalMinuteSeal.self,
            from: Data(tamperedJSON.utf8)
        )
        let tamperedByName = Dictionary(
            uniqueKeysWithValues: tampered.minuteFields.map {
                ($0.name, $0.commitmentHex)
            }
        )
        XCTAssertNotEqual(
            MerkleTree.root(labeledHexValues: order.map { ($0, tamperedByName[$0]!) }),
            tampered.minuteRoot
        )

        let legacySeal = LocalMinuteSeal(
            anchorSequence: compactSeal.anchorSequence,
            minuteStart: compactSeal.minuteStart,
            minuteEnd: compactSeal.minuteEnd,
            minuteFields: commitments,
            eventRoots: compactSeal.eventRoots,
            minuteRoot: compactSeal.minuteRoot,
            previousAnchorHash: compactSeal.previousAnchorHash,
            anchorHash: compactSeal.anchorHash,
            deviceID: compactSeal.deviceID,
            publicKeyBase64: compactSeal.publicKeyBase64,
            trustTier: compactSeal.trustTier,
            signatureBase64: compactSeal.signatureBase64,
            signatureAlgorithm: compactSeal.signatureAlgorithm
        )
        let legacyData = try encoder.encode(legacySeal)
        XCTAssertLessThan(compactData.count, legacyData.count)
        let legacyDecoded = try decoder.decode(LocalMinuteSeal.self, from: legacyData)
        XCTAssertEqual(legacyDecoded, legacySeal)
        XCTAssertEqual(legacyDecoded.storageFormat, .fullCommitments)
        print(
            "MinuteSeal schema-v2 row_bytes=\(compactData.count) "
                + "full_openings_bytes=\(legacyData.count) "
                + "saved=\(legacyData.count - compactData.count)"
        )
    }

    func testMixedMinuteCanKeepOneEventFullyOpaque() {
        func eventDisclosure(seed: UInt8, level: ShareLevel, revealCategory: Bool) -> EventDisclosure {
            let fields = IntegrityDomains.eventFieldOrder.enumerated().map { index, name in
                CommitmentBuilder.make(
                    name: name,
                    fields: ["value": name],
                    salt: Data(repeating: seed + UInt8(index), count: 32)
                )
            }
            let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.commitmentHex) })
            let root = MerkleTree.root(
                labeledHexValues: IntegrityDomains.eventFieldOrder.map { ($0, map[$0]!) }
            )
            return EventDisclosure(
                eventRoot: root,
                fieldCommitments: fields.map { field in
                    FieldDisclosure(
                        name: field.name,
                        commitmentHex: field.commitmentHex,
                        opening: revealCategory && ["time", "classification", "coverage", "trust"].contains(field.name)
                            ? field.opening : nil
                    )
                },
                rawEvent: nil,
                schemaVersion: 2,
                shareLevel: level
            )
        }

        let visible = eventDisclosure(seed: 41, level: .categoryOnly, revealCategory: true)
        let hidden = eventDisclosure(seed: 61, level: .privateOnly, revealCategory: false)
        let eventRoots = [visible.eventRoot, hidden.eventRoot]
        let eventsRoot = MerkleTree.root(
            labeledHexValues: eventRoots.enumerated().map { ("event:\($0.offset)", $0.element) }
        )
        let minuteFields = IntegrityDomains.minuteFieldOrder.enumerated().map { index, name in
            let values: [String: String]
            switch name {
            case "events_root": values = ["events_root": eventsRoot]
            case "event_count": values = ["count": String(eventRoots.count)]
            default: values = ["value": name]
            }
            return CommitmentBuilder.makeMinute(
                name: name,
                fields: values,
                salt: Data(repeating: UInt8(index + 81), count: 32)
            )
        }
        let map = Dictionary(uniqueKeysWithValues: minuteFields.map { ($0.name, $0.commitmentHex) })
        let minuteRoot = MerkleTree.root(
            labeledHexValues: IntegrityDomains.minuteFieldOrder.map { ($0, map[$0]!) }
        )
        let previous = String(repeating: "0", count: 64)
        let disclosure = MinuteDisclosure(
            anchorSequence: 8,
            minuteRoot: minuteRoot,
            previousAnchorHash: previous,
            anchorHash: ChainHash.anchor(sequence: 8, previous: previous, minuteRoot: minuteRoot),
            shareLevel: .mixed,
            minuteFields: minuteFields.map {
                FieldDisclosure(name: $0.name, commitmentHex: $0.commitmentHex, opening: $0.opening)
            },
            eventRoots: eventRoots,
            events: [visible, hidden],
            signatureBase64: nil,
            signatureAlgorithm: nil,
            publicKeyBase64: nil,
            deviceID: "device",
            trustTier: "local",
            liveReceiptID: nil
        )

        XCTAssertTrue(disclosure.verifiesStructure())
        XCTAssertTrue(hidden.fieldCommitments.allSatisfy { $0.opening == nil })
    }

    func testDaySharePackageCanDeclareAVisibleIdentityRotation() throws {
        let package = DaySharePackage(
            schemaVersion: 4,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "old-device",
            deviceIDs: ["old-device", "new-device"],
            localDay: "2026-08-18",
            classifierVersion: "test",
            minutes: []
        )

        let encoded = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(DaySharePackage.self, from: encoded)

        XCTAssertEqual(decoded, package)
        XCTAssertEqual(decoded.deviceIDs, ["old-device", "new-device"])
    }
}
