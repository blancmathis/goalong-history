import Foundation

public struct AgentIntegrationStatus: Equatable, Sendable {
    public var kind: AgentIntegrationKind
    public var isInstalled: Bool
    public var configurationPath: String

    public init(kind: AgentIntegrationKind, isInstalled: Bool, configurationPath: String) {
        self.kind = kind
        self.isInstalled = isInstalled
        self.configurationPath = configurationPath
    }
}

public enum AgentIntegrationInstallerError: Error, LocalizedError {
    case invalidConfiguration(URL)
    case executableUnavailable
    case unmanagedOpenCodePlugin(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let url):
            return "The existing configuration at \(url.path) is not a JSON object. It was not changed."
        case .executableUnavailable:
            return "The LocalHistory executable path is unavailable."
        case .unmanagedOpenCodePlugin(let url):
            return "A different file already exists at \(url.path). It was not overwritten."
        }
    }
}

public final class AgentIntegrationInstaller: @unchecked Sendable {
    public let executableURL: URL
    public let homeDirectory: URL

    private let fileManager: FileManager
    private let marker = "--agent-hook-ingest"
    private let openCodeMarker = "goalong-history-agent-hook-v1"

    public init(
        executableURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func status(for kind: AgentIntegrationKind) -> AgentIntegrationStatus {
        let url = configurationURL(for: kind)
        let installed: Bool
        switch kind {
        case .codexHooks, .claudeCodeHooks, .cursorHooks:
            installed =
                jsonFile(at: url, recursivelyContains: marker)
                && jsonFile(at: url, recursivelyContains: executableURL.path)
        case .openCodePlugin:
            let source = try? String(contentsOf: url, encoding: .utf8)
            let encodedPath = try? jsonString(executableURL.path)
            installed =
                source?.contains(openCodeMarker) == true
                && (source?.contains(executableURL.path) == true
                    || encodedPath.map { source?.contains($0) == true } == true)
        }
        return AgentIntegrationStatus(kind: kind, isInstalled: installed, configurationPath: url.path)
    }

    public func install(_ kind: AgentIntegrationKind) throws {
        guard !executableURL.path.isEmpty else { throw AgentIntegrationInstallerError.executableUnavailable }
        switch kind {
        case .codexHooks:
            try installCodexHooks()
        case .claudeCodeHooks:
            try installClaudeHooks()
        case .cursorHooks:
            try installCursorHooks()
        case .openCodePlugin:
            try installOpenCodePlugin()
        }
    }

    public func uninstall(_ kind: AgentIntegrationKind) throws {
        switch kind {
        case .codexHooks:
            try removeCodexHooks()
        case .claudeCodeHooks:
            try removeClaudeHooks()
        case .cursorHooks:
            try removeCursorHooks()
        case .openCodePlugin:
            let url = configurationURL(for: kind)
            guard fileManager.fileExists(atPath: url.path) else { return }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard text.contains(openCodeMarker) else {
                throw AgentIntegrationInstallerError.unmanagedOpenCodePlugin(url)
            }
            try backup(url)
            try fileManager.removeItem(at: url)
        }
    }

    public func configurationURL(for kind: AgentIntegrationKind) -> URL {
        switch kind {
        case .codexHooks:
            return homeDirectory.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        case .claudeCodeHooks:
            return homeDirectory.appendingPathComponent(".claude/settings.json", isDirectory: false)
        case .cursorHooks:
            return homeDirectory.appendingPathComponent(".cursor/hooks.json", isDirectory: false)
        case .openCodePlugin:
            return homeDirectory.appendingPathComponent(
                ".config/opencode/plugins/goalong-history.js",
                isDirectory: false
            )
        }
    }

    private func installCodexHooks() throws {
        let url = configurationURL(for: .codexHooks)
        var root = try loadJSONObject(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let events = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
            "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
        ]
        for event in events {
            var definitions = removingGoalongNestedHooks(
                from: hooks[event] as? [[String: Any]] ?? []
            )
            let command = hookCommand(provider: .codex, eventName: event)
            if !definitions.contains(where: { Self.recursivelyContains($0, needle: command) }) {
                definitions.append([
                    "hooks": [
                        [
                            "type": "command",
                            "command": command,
                            "timeout": event == "SessionEnd" ? 3 : 10,
                        ]
                    ]
                ])
            }
            hooks[event] = definitions
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeCodexHooks() throws {
        try removeNestedHooks(at: configurationURL(for: .codexHooks))
    }

    private func installClaudeHooks() throws {
        let url = configurationURL(for: .claudeCodeHooks)
        var root = try loadJSONObject(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let events = [
            "SessionStart", "Setup", "UserPromptSubmit", "UserPromptExpansion", "PreToolUse",
            "PermissionRequest", "PermissionDenied", "PostToolUse", "PostToolUseFailure",
            "PostToolBatch", "Notification", "MessageDisplay", "SubagentStart", "SubagentStop",
            "TaskCreated", "TaskCompleted", "Stop", "StopFailure", "TeammateIdle",
            "InstructionsLoaded", "ConfigChange", "CwdChanged", "DirectoryAdded", "FileChanged",
            "WorktreeCreate", "WorktreeRemove", "PreCompact", "PostCompact", "Elicitation",
            "ElicitationResult", "SessionEnd",
        ]
        for event in events {
            var definitions = removingGoalongNestedHooks(
                from: hooks[event] as? [[String: Any]] ?? []
            )
            let command = hookCommand(provider: .claudeCode, eventName: event)
            if !definitions.contains(where: { Self.recursivelyContains($0, needle: command) }) {
                definitions.append([
                    "hooks": [
                        [
                            "type": "command",
                            "command": command,
                            "timeout": 10,
                        ]
                    ]
                ])
            }
            hooks[event] = definitions
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeClaudeHooks() throws {
        try removeNestedHooks(at: configurationURL(for: .claudeCodeHooks))
    }

    private func removeNestedHooks(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try loadJSONObject(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard let definitions = value as? [[String: Any]] else { continue }
            let cleaned = removingGoalongNestedHooks(from: definitions)
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removingGoalongNestedHooks(
        from definitions: [[String: Any]]
    ) -> [[String: Any]] {
        definitions.compactMap { definition -> [String: Any]? in
            guard var nested = definition["hooks"] as? [[String: Any]] else {
                return Self.recursivelyContains(definition, needle: marker) ? nil : definition
            }
            nested.removeAll { Self.recursivelyContains($0, needle: marker) }
            guard !nested.isEmpty else { return nil }
            var output = definition
            output["hooks"] = nested
            return output
        }
    }

    private func installCursorHooks() throws {
        let url = configurationURL(for: .cursorHooks)
        var root = try loadJSONObject(url)
        root["version"] = 1
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let events = [
            "sessionStart", "sessionEnd", "workspaceOpen", "beforeSubmitPrompt", "preToolUse",
            "postToolUse", "postToolUseFailure", "beforeShellExecution", "afterShellExecution",
            "beforeMCPExecution", "afterMCPExecution", "beforeReadFile", "afterFileEdit",
            "beforeTabFileRead", "afterTabFileEdit", "subagentStart", "subagentStop", "preCompact",
            "afterAgentResponse", "afterAgentThought", "stop",
        ]
        for event in events {
            var definitions = hooks[event] as? [[String: Any]] ?? []
            definitions.removeAll { Self.recursivelyContains($0, needle: marker) }
            let command = hookCommand(provider: .cursor, eventName: event)
            if !definitions.contains(where: { Self.recursivelyContains($0, needle: command) }) {
                definitions.append(["command": command])
            }
            hooks[event] = definitions
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeCursorHooks() throws {
        let url = configurationURL(for: .cursorHooks)
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try loadJSONObject(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard var definitions = value as? [[String: Any]] else { continue }
            definitions.removeAll { Self.recursivelyContains($0, needle: marker) }
            if definitions.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = definitions }
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func installOpenCodePlugin() throws {
        let url = configurationURL(for: .openCodePlugin)
        if fileManager.fileExists(atPath: url.path) {
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard current.contains(openCodeMarker) else {
                throw AgentIntegrationInstallerError.unmanagedOpenCodePlugin(url)
            }
            try backup(url)
        }
        let encodedPath = try jsonString(executableURL.path)
        let source = """
            // \(openCodeMarker)
            const GOALONG_EXECUTABLE = \(encodedPath)

            function safeStringify(value) {
              const seen = new WeakSet()
              return JSON.stringify(value, (_key, item) => {
                if (typeof item === "bigint") return item.toString()
                if (item && typeof item === "object") {
                  if (seen.has(item)) return "[Circular]"
                  seen.add(item)
                }
                return item
              })
            }

            async function recordGoalongEvent(eventName, payload) {
              try {
                const child = Bun.spawn({
                  cmd: [GOALONG_EXECUTABLE, "--agent-hook-ingest", "openCode", eventName],
                  stdin: "pipe",
                  stdout: "ignore",
                  stderr: "ignore",
                })
                child.stdin.write(safeStringify(payload))
                child.stdin.end()
                await child.exited
              } catch (_) {
                // Collection must never break OpenCode's agent loop.
              }
            }

            export const GoalongHistoryPlugin = async ({ project, directory, worktree }) => ({
              event: async ({ event }) => {
                await recordGoalongEvent(event.type || "event", {
                  event,
                  context: { project, directory, worktree },
                })
              },
            })
            """
        try secureWrite(Data(source.utf8), to: url)
    }

    private func hookCommand(provider: AgentProvider, eventName: String) -> String {
        [
            Self.shellQuote(executableURL.path),
            marker,
            Self.shellQuote(provider.rawValue),
            Self.shellQuote(eventName),
        ].joined(separator: " ")
    }

    private func loadJSONObject(_ url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIntegrationInstallerError.invalidConfiguration(url)
        }
        return object
    }

    private func writeJSONObject(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if fileManager.fileExists(atPath: url.path) { try backup(url) }
        try secureWrite(data, to: url)
    }

    private func secureWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func backup(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        let suffix = UUID().uuidString.prefix(8)
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + ".goalong-backup-\(stamp)-\(suffix)",
            isDirectory: false
        )
        try fileManager.copyItem(at: url, to: backup)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private func jsonFile(at url: URL, recursivelyContains needle: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return Self.recursivelyContains(object, needle: needle)
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func recursivelyContains(_ value: Any, needle: String) -> Bool {
        if let string = value as? String { return string.contains(needle) }
        if let array = value as? [Any] { return array.contains { recursivelyContains($0, needle: needle) } }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { recursivelyContains($0, needle: needle) }
        }
        return false
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
