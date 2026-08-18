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
        XCTAssertFalse(MerkleTree.verify(label: "b", valueHex: SHA256Digest.hashHex("fake"), proof: proof, expectedRoot: root))
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
