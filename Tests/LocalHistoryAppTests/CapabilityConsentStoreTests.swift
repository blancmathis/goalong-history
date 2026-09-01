#if os(macOS)
    import Foundation
    import AgentActivity
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class CapabilityConsentStoreTests: XCTestCase {
        func testMissingConsentFileFailsClosedWithoutCreatingOne() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("capability-consent.json")

            let store = GoalongCapabilityConsentStore(fileURL: file)

            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            for capability in GoalongCapability.allCases {
                XCTAssertFalse(store.isEnabled(capability), capability.rawValue)
            }
        }

        func testConsentIsExplicitAtomicAndMode600() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("capability-consent.json")
            let store = GoalongCapabilityConsentStore(fileURL: file)

            XCTAssertTrue(
                store.set(.appleScreenTime, enabled: true, surface: .onboarding)
            )
            XCTAssertTrue(store.isEnabled(.appleScreenTime))
            XCTAssertFalse(store.isEnabled(.aiConversations))

            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

            let reloaded = GoalongCapabilityConsentStore(fileURL: file)
            XCTAssertTrue(reloaded.isEnabled(.appleScreenTime))
            XCTAssertFalse(reloaded.isEnabled(.chatGPTAnalysis))
        }

        func testUnknownPolicyVersionFailsClosed() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("capability-consent.json")
            let payload = """
                {
                  "schemaVersion": 1,
                  "policyVersion": 999,
                  "capabilities": {
                    "localComputerHistory": {"enabled": true}
                  }
                }
                """
            try Data(payload.utf8).write(to: file)

            let store = GoalongCapabilityConsentStore(fileURL: file)

            XCTAssertFalse(store.isEnabled(.localComputerHistory))
        }

        func testRecorderDefaultsCollectNothingAndEnableNoTransport() {
            let config = RecorderConfig.default
            XCTAssertFalse(config.captureClicks)
            XCTAssertFalse(config.captureScroll)
            XCTAssertFalse(config.captureKeyboardActivity)
            XCTAssertFalse(config.captureShortcuts)
            XCTAssertFalse(config.captureWindowTitles)
            XCTAssertFalse(config.captureElementLabels)
            XCTAssertFalse(config.captureURLs)
            XCTAssertFalse(config.verificationEnabled == true)
            XCTAssertFalse(config.enableAppAttest == true)
        }

        func testAgentSourcesAreNotDiscoveredBeforeExplicitStart() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var discoveryCount = 0
            let runtime = try AgentActivityRuntime(
                rootDirectory: root.appendingPathComponent("agent-activity-v2"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                performInitialDiscovery: false,
                sourceDiscovery: {
                    discoveryCount += 1
                    return []
                },
                onCaptured: { _ in }
            )

            XCTAssertEqual(discoveryCount, 0)
            runtime.start()
            runtime.waitForPendingScansForTesting()
            XCTAssertEqual(discoveryCount, 1)
            runtime.stop()
        }

        private func makeTemporaryDirectory() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "goalong-consent-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }
#endif
