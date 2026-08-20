import XCTest
@testable import LocalHistoryCore

final class SemanticAndPrivacyTests: XCTestCase {
    func testSemanticReferenceRoundTripAndValidation() throws {
        let payload = fixtureSemanticPayload()
        let event = fixtureEvent(
            id: "semantic",
            sequence: 1,
            offset: 0,
            kind: .semanticSnapshot,
            semanticContext: payload.reference
        )
        XCTAssertTrue(SemanticContextValidator.issues(event: event, payload: payload).isEmpty)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryEvent.self, from: encoder.encode(event))
        XCTAssertEqual(decoded, event)
    }

    func testOlderEventsDecodeWithoutSemanticReference() throws {
        let JSON = """
        {"schemaVersion":3,"id":"legacy","sessionID":"s","timestamp":"2027-01-15T08:00:00Z","kind":"typingBurst"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(HistoryEvent.self, from: Data(JSON.utf8))
        XCTAssertNil(event.semanticContext)
        XCTAssertEqual(event.kind, .typingBurst)
    }

    func testSemanticValidationRejectsSuppressedSecureAndMismatchedPayloads() {
        let payload = fixtureSemanticPayload()
        let suppressed = fixtureEvent(
            id: "suppressed",
            sequence: 1,
            offset: 0,
            kind: .semanticSnapshot,
            suppression: .secureInput,
            semanticContext: payload.reference,
            secureElement: true
        )
        let issues = SemanticContextValidator.issues(event: suppressed, payload: payload)
        XCTAssertTrue(issues.contains(.suppressedEventReferenced))
        XCTAssertTrue(issues.contains(.secureElementReferenced))

        let otherPayload = fixtureSemanticPayload(id: "other", hash: "other-hash")
        let mismatch = SemanticContextValidator.issues(
            event: fixtureEvent(
                id: "semantic",
                sequence: 2,
                offset: 0,
                kind: .semanticSnapshot,
                semanticContext: payload.reference
            ),
            payload: otherPayload
        )
        XCTAssertTrue(mismatch.contains(.identifierMismatch))
        XCTAssertTrue(mismatch.contains(.hashMismatch))
    }

    func testSemanticValidationRecomputesPayloadHash() {
        let original = fixtureSemanticPayload(text: "abcd")
        let tampered = fixtureSemanticPayload(
            id: original.id,
            text: "wxyz",
            hash: original.contentSHA256
        )
        let event = fixtureEvent(
            id: "semantic-tamper",
            sequence: 9,
            offset: 0,
            kind: .semanticSnapshot,
            semanticContext: original.reference
        )
        XCTAssertTrue(
            SemanticContextValidator.issues(event: event, payload: tampered).contains(.hashMismatch)
        )
    }

    func testTypingBurstCannotCarryRawCharacterButShortcutMayCarryNamedKey() {
        let badTyping = fixtureEvent(
            id: "typing",
            sequence: 1,
            offset: 0,
            kind: .typingBurst,
            keyboard: KeyboardSnapshot(category: "typing", key: "a", modifiers: [], isRepeat: false)
        )
        XCTAssertTrue(
            PrivacyBoundaryValidator.violations(in: badTyping).contains(.rawCharacterAttachedToTypingBurst)
        )

        let badMetadata = fixtureEvent(
            id: "typing-metadata",
            sequence: 2,
            offset: 0.5,
            kind: .typingBurst,
            metadata: ["typed_text": "do not store me"]
        )
        XCTAssertTrue(
            PrivacyBoundaryValidator.violations(in: badMetadata)
                .contains(.rawTextMetadataAttachedToTypingBurst)
        )

        let shortcut = fixtureEvent(
            id: "shortcut",
            sequence: 2,
            offset: 1,
            kind: .keyboardShortcut,
            keyboard: KeyboardSnapshot(category: "shortcut", key: "C", modifiers: ["command"], isRepeat: false)
        )
        XCTAssertFalse(
            PrivacyBoundaryValidator.violations(in: shortcut).contains(.rawCharacterAttachedToTypingBurst)
        )
    }

    func testSuppressedEventCannotPersistDetailedOrSemanticContent() {
        let payload = fixtureSemanticPayload()
        let event = fixtureEvent(
            id: "private",
            sequence: 1,
            offset: 0,
            kind: .captureSuppressed,
            suppression: .privateBrowserWindow,
            metadata: ["analysis.semantic_text": "secret"],
            semanticContext: payload.reference,
            keyboard: KeyboardSnapshot(category: "shortcut", key: "C", modifiers: ["command"], isRepeat: false)
        )
        let violations = PrivacyBoundaryValidator.violations(in: event)
        XCTAssertTrue(violations.contains(.detailedContentDuringSuppression))
        XCTAssertTrue(violations.contains(.semanticContentDuringSuppression))
    }

    func testEveryEventKindSerializes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (index, kind) in EventKind.allCases.enumerated() {
            let event = fixtureEvent(
                id: "event-\(index)",
                sequence: UInt64(index + 1),
                offset: TimeInterval(index),
                kind: kind
            )
            XCTAssertEqual(try decoder.decode(HistoryEvent.self, from: encoder.encode(event)), event, "Failed \(kind)")
        }
    }
}
