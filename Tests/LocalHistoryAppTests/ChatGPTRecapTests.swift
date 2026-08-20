#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class ChatGPTRecapTests: XCTestCase {
        func testChatGPTExportParserKeepsDatedUserAndAssistantMessages() throws {
            let fixture: [String: Any] = [
                "conversations": [[
                    "id": "conversation-1",
                    "title": "Launch plan",
                    "create_time": 1_700_000_000.0,
                    "mapping": [
                        "node-user": [
                            "message": [
                                "id": "message-user",
                                "author": ["role": "user"],
                                "create_time": 1_700_000_001.0,
                                "content": ["parts": ["Draft the launch plan"]],
                            ]
                        ],
                        "node-assistant": [
                            "message": [
                                "id": "message-assistant",
                                "author": ["role": "assistant"],
                                "create_time": 1_700_000_002.0,
                                "content": ["parts": ["Start with the target audience."]],
                            ]
                        ],
                        "node-system": [
                            "message": [
                                "id": "message-system",
                                "author": ["role": "system"],
                                "create_time": 1_700_000_000.0,
                                "content": ["parts": ["Hidden system text"]],
                            ]
                        ],
                    ],
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: fixture)
            let parsed = try ChatGPTHistoryStore.parseConversations(data: data)

            XCTAssertEqual(parsed.conversationIDs, ["conversation-1"])
            XCTAssertEqual(parsed.messages.map(\.role).sorted(), ["assistant", "user"])
            XCTAssertEqual(parsed.messages.count, 2)
        }

        func testChatGPTExportParserRedactsCommonSecrets() throws {
            let fixture: [[String: Any]] = [[
                "id": "conversation-1",
                "title": "Credential check",
                "mapping": [
                    "node-user": [
                        "message": [
                            "id": "message-user",
                            "author": ["role": "user"],
                            "create_time": 1_700_000_001.0,
                            "content": ["parts": ["api_key=sk-abcdefghijklmnopqrstuvwxyz123456"]],
                        ]
                    ]
                ],
            ]]
            let data = try JSONSerialization.data(withJSONObject: fixture)
            let parsed = try ChatGPTHistoryStore.parseConversations(data: data)

            XCTAssertEqual(parsed.messages.count, 1)
            XCTAssertFalse(parsed.messages[0].text.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
            XCTAssertTrue(parsed.messages[0].text.contains("REDACTED"))
        }

        func testCodexHomeUsesRestrictedAppManagedPermissionProfile() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }

            try CodexAppServerSession.prepareCodexHome(at: directory)
            let configURL = directory.appendingPathComponent("config.toml")
            let config = try String(contentsOf: configURL, encoding: .utf8)

            XCTAssertTrue(config.contains("default_permissions = \"goalong-recap\""))
            XCTAssertTrue(config.contains("\":minimal\" = \"read\""))
            XCTAssertTrue(config.contains("\":workspace_roots\" = \"read\""))
            XCTAssertTrue(config.contains("[permissions.goalong-recap.network]"))
            XCTAssertTrue(config.contains("enabled = false"))
            XCTAssertFalse(config.contains("workspaceWrite"))
            XCTAssertFalse(config.contains("readOnlyAccess"))
        }

        func testCodexEnvironmentDropsSecretsAndCredentialSources() {
            let home = URL(fileURLWithPath: "/tmp/goalong-codex-home", isDirectory: true)
            let environment = CodexAppServerSession.codexEnvironment(
                inheriting: [
                    "HOME": "/Users/test",
                    "PATH": "/usr/bin:/bin",
                    "LANG": "en_US.UTF-8",
                    "OPENAI_API_KEY": "secret",
                    "AWS_SECRET_ACCESS_KEY": "secret",
                    "HTTPS_PROXY": "https://user:password@example.com",
                    "SSH_AUTH_SOCK": "/tmp/agent.sock",
                    "SHELL": "/tmp/malicious-shell",
                    "CODEX_HOME": "/tmp/other-home",
                ],
                codexHomeURL: home
            )

            XCTAssertEqual(environment["HOME"], "/Users/test")
            XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
            XCTAssertEqual(environment["CODEX_HOME"], home.path)
            XCTAssertNil(environment["OPENAI_API_KEY"])
            XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
            XCTAssertNil(environment["HTTPS_PROXY"])
            XCTAssertNil(environment["SSH_AUTH_SOCK"])
            XCTAssertEqual(environment["SHELL"], "/bin/zsh")
        }

        func testCodexLocatorHonorsExplicitExecutableOverride() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let executable = directory.appendingPathComponent("codex")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            let located = CodexExecutableLocator.locate(
                environment: ["GOALONG_CODEX_PATH": executable.path],
                fileManager: .default,
                bundle: .main
            )
            XCTAssertEqual(located?.standardizedFileURL, executable.standardizedFileURL)
        }
    }
#endif
