#if os(macOS)
    import Foundation
    import XCTest

    @testable import LocalHistoryQueryCLI

    final class GoalongCLIContractTests: XCTestCase {
        func testCanonicalCatalogHasUniqueCommandsAndAccurateEffects() throws {
            let commands = GoalongCLIContract.commands
            XCTAssertEqual(Set(commands.map(\.name)).count, commands.count)
            XCTAssertEqual(
                GoalongCLIContract.definition(named: "help")?.outputFormat,
                .text
            )
            XCTAssertEqual(
                GoalongCLIContract.definition(named: "screen-time")?.effect,
                .mayRefreshActiveScreenTimeRecord
            )
            XCTAssertEqual(
                GoalongCLIContract.definition(named: "ask")?.effect,
                .mayRefreshActiveScreenTimeRecord
            )
            XCTAssertEqual(
                GoalongCLIContract.definition(named: "export-proof")?.effect,
                .writesExplicitOutputFile
            )
            XCTAssertTrue(GoalongCLIContract.usageText.contains("`help --json`"))
            XCTAssertTrue(GoalongCLIContract.usageText.contains("nonzero exit status"))
            XCTAssertTrue(GoalongCLIContract.agentInstructions.contains("Screen Time `queryReady`"))
            XCTAssertTrue(GoalongCLIContract.agentInstructions.contains("`sourceAssurance`"))
            XCTAssertFalse(GoalongCLIContract.usageText.contains("All commands are read-only"))
            XCTAssertFalse(GoalongCLIContract.usageText.contains("identically signed"))
            for command in commands {
                XCTAssertTrue(
                    GoalongCLIContract.usageText.contains("  \(command.syntax)"),
                    "Missing syntax for \(command.name)"
                )
            }
        }

        func testCapabilitiesAndVersionAreMachineReadable() throws {
            let capabilities = try jsonObject(GoalongQueryCLI.capabilitiesPayload())
            XCTAssertEqual(capabilities["schemaVersion"] as? Int, GoalongCLIContract.schemaVersion)
            XCTAssertEqual(
                (capabilities["commands"] as? [[String: Any]])?.count,
                GoalongCLIContract.commands.count
            )
            XCTAssertEqual(capabilities["errorOutput"] as? String, "sorted JSON on stderr with a nonzero exit status")

            let version = try jsonObject(GoalongQueryCLI.versionPayload())
            XCTAssertEqual(version["name"] as? String, "goalong")
            XCTAssertEqual(version["cliContractSchemaVersion"] as? Int, GoalongCLIContract.schemaVersion)
            XCTAssertNotNil(version["appVersion"] as? String)
            XCTAssertNotNil(version["buildNumber"] as? String)
        }

        func testGlobalStatusIsMetadataOnlyAndDoesNotMutateEmptyRoot() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let before = try FileManager.default.contentsOfDirectory(atPath: root.path)

            let payload = try GoalongQueryCLI.statusPayload(rootDirectory: root)
            let after = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let json = try jsonObject(payload)
            let sources = try XCTUnwrap(json["sources"] as? [String: Any])

            XCTAssertEqual(before, after)
            XCTAssertEqual(json["schemaVersion"] as? Int, 2)
            XCTAssertEqual(json["overallState"] as? String, "setupRequired")
            XCTAssertNotNil(sources["computerHistory"])
            XCTAssertNotNil(sources["screenTime"])
            XCTAssertNotNil(sources["aiConversations"])
            XCTAssertNotNil(sources["dailyRecaps"])
            XCTAssertNotNil(sources["chatGPTAnalysis"])
            XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("messages"))
            XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("transcript"))
        }

        func testDocsAndParserContainEveryCanonicalCommand() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let parser = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift"),
                encoding: .utf8
            )
            let docs = try String(
                contentsOf: repositoryRoot.appendingPathComponent("docs/CLI.md"),
                encoding: .utf8
            )
            for command in GoalongCLIContract.commands {
                XCTAssertTrue(parser.contains("\"\(command.name)\""), "Parser omits \(command.name)")
                XCTAssertTrue(
                    docs.contains("`\(command.name)`") || docs.contains("goalong \(command.name)"),
                    "Docs omit \(command.name)"
                )
            }
        }

        private func jsonObject(_ data: Data) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private func temporaryRoot() throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("goalong-cli-contract-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }
#endif
