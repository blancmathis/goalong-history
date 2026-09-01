#if os(macOS)
    import Darwin
    import Foundation
    import XCTest
    @testable import LocalHistoryQueryCLI

    final class GoalongReadOnlyQueryBrokerTests: XCTestCase {
        func testBrokerReturnsTransientScreenTimePayloadAndRemovesSocket() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let expected = Data("{\"schemaVersion\":1,\"status\":{\"kind\":\"ready\"}}\n".utf8)
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { day, macOnly in
                    XCTAssertEqual(day, "2026-08-31")
                    XCTAssertTrue(macOnly)
                    return expected
                }
            )

            try server.start()
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

            let actual = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: "2026-08-31",
                macOnly: true
            )
            XCTAssertEqual(actual, expected)

            server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        }

        func testBrokerRefusesToReplaceUnexpectedPath() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let marker = Data("do-not-replace".utf8)
            try marker.write(to: socketURL, options: .withoutOverwriting)
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _ in Data() }
            )

            XCTAssertThrowsError(try server.start())
            XCTAssertThrowsError(
                try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)
            )
            XCTAssertEqual(try Data(contentsOf: socketURL), marker)
        }

        func testConsentOffCleanupRemovesOnlyOwnedSocket() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _ in Data() }
            )
            try server.start()
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

            try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)

            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
            server.stop()
            XCTAssertNoThrow(
                try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)
            )
        }

        func testCapabilityConsentFailsClosedAndRequiresExactCurrentDocument() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertFalse(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )

            let consent = root.appendingPathComponent("capability-consent.json")
            try Data(
                """
                {"schemaVersion":1,"policyVersion":1,"capabilities":{"aiConversations":{"enabled":true}}}
                """.utf8
            ).write(to: consent)
            XCTAssertTrue(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )

            try Data(
                """
                {"schemaVersion":1,"policyVersion":999,"capabilities":{"aiConversations":{"enabled":true}}}
                """.utf8
            ).write(to: consent, options: .atomic)
            XCTAssertFalse(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )
        }

        private func temporaryRoot() throws -> URL {
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
                "goalong-broker-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }
#endif
