#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    final class SemanticContextDeduplicationTests: XCTestCase {
        func testIdenticalPayloadIsInternedOnlyWithinTheSameInteraction() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "goalong-semantic-dedup-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = SemanticContextStore(
                semanticDirectory: directory,
                secureInputEnabled: { false }
            )
            let capture = AXRichContextCapture(
                text: "Visible editor state",
                source: "focused+visible",
                redacted: false,
                truncated: false,
                fingerprint: "capture-fingerprint"
            )
            let context = ContextSnapshot(
                app: AppSnapshot(
                    name: "Fixture",
                    bundleIdentifier: "test.fixture",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(
                    title: "Document",
                    role: "AXWindow",
                    subrole: nil
                ),
                focusedElement: ElementSnapshot(
                    role: "AXTextArea",
                    subrole: nil,
                    title: nil,
                    label: "Editor",
                    identifier: "editor",
                    isSecure: false
                ),
                url: URLSnapshot(
                    value: "https://example.com/document",
                    host: "example.com",
                    redactionApplied: true
                ),
                suppressionReason: nil
            )
            let firstTime = Date(timeIntervalSince1970: 1_788_048_000)
            let first = try store.append(
                capture: capture,
                context: context,
                timestamp: firstTime,
                deduplicationScope: "interaction-a"
            )
            let repeated = try store.append(
                capture: capture,
                context: context,
                timestamp: firstTime.addingTimeInterval(1),
                deduplicationScope: "interaction-a"
            )
            let otherInteraction = try store.append(
                capture: capture,
                context: context,
                timestamp: firstTime.addingTimeInterval(2),
                deduplicationScope: "interaction-b"
            )

            XCTAssertEqual(first.snapshotID, repeated.snapshotID)
            XCTAssertNotEqual(first.capturedAt, repeated.capturedAt)
            XCTAssertNotEqual(first.snapshotID, otherInteraction.snapshotID)

            let file = directory.appendingPathComponent(
                AppPaths.localDayString(for: firstTime) + ".semantic.jsonl"
            )
            let rows = try Data(contentsOf: file).split(separator: 0x0A)
            XCTAssertEqual(rows.count, 2)
            XCTAssertLessThan(
                try Data(contentsOf: file).count,
                2_000,
                "The bounded index should not expand identical interaction payloads."
            )
        }
    }
#endif
