import Foundation
import LocalHistoryCore

public enum AgentDefaultSourceDiscovery {
    private struct Candidate {
        let name: String
        let relativePath: String
        let provider: AgentProvider
        let mode: AgentCaptureMode
    }

    private static let candidates: [Candidate] = [
        Candidate(name: "Codex local history", relativePath: ".codex", provider: .codex, mode: .transcriptsAndLogs),
        Candidate(
            name: "Claude Code local history", relativePath: ".claude", provider: .claudeCode, mode: .transcriptsAndLogs
        ),
        Candidate(name: "Cursor agent history", relativePath: ".cursor", provider: .cursor, mode: .transcriptsAndLogs),
        Candidate(
            name: "Cursor workspace agent state",
            relativePath: "Library/Application Support/Cursor/User/workspaceStorage",
            provider: .cursor,
            mode: .transcriptsAndLogs
        ),
        Candidate(
            name: "Cursor global agent state",
            relativePath: "Library/Application Support/Cursor/User/globalStorage",
            provider: .cursor,
            mode: .transcriptsAndLogs
        ),
        Candidate(
            name: "OpenCode local history", relativePath: ".local/share/opencode", provider: .openCode,
            mode: .transcriptsAndLogs),
    ]

    public static func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [AgentWatchedFolder] {
        candidates.compactMap { candidate in
            let url = homeDirectory.appendingPathComponent(candidate.relativePath, isDirectory: true)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return AgentWatchedFolder(
                id: stableID(provider: candidate.provider, path: url.path),
                displayName: candidate.name,
                path: url.path,
                provider: candidate.provider,
                captureMode: candidate.mode
            )
        }
    }

    public static func managedHookFolders(rootDirectory: URL) -> [AgentWatchedFolder] {
        AgentProvider.allCases
            .filter { $0 != .custom }
            .map { provider in
                let url =
                    rootDirectory
                    .appendingPathComponent("hook-inbox", isDirectory: true)
                    .appendingPathComponent(provider.rawValue, isDirectory: true)
                return AgentWatchedFolder(
                    id: "goalong-hook-inbox-\(provider.rawValue)",
                    displayName: "\(provider.displayName) live events",
                    path: url.path,
                    provider: provider,
                    isEnabled: true,
                    includeSubdirectories: true,
                    captureMode: .everyFile,
                    isManaged: true
                )
            }
    }

    public static func merging(
        configuration: AgentActivityConfiguration,
        discovered: [AgentWatchedFolder],
        managed: [AgentWatchedFolder]
    ) -> AgentActivityConfiguration {
        var output = configuration
        var byPath: [String: AgentWatchedFolder] = [:]
        for folder in configuration.validated().watchedFolders {
            let key = URL(fileURLWithPath: folder.path).standardizedFileURL.path.lowercased()
            if byPath[key] == nil { byPath[key] = folder }
        }

        for folder in discovered + managed {
            let key = URL(fileURLWithPath: folder.path).standardizedFileURL.path.lowercased()
            if let existing = byPath[key] {
                if folder.isManaged, !existing.isManaged {
                    var promoted = existing
                    promoted.isManaged = true
                    promoted.provider = folder.provider
                    promoted.displayName = folder.displayName
                    promoted.captureMode = .everyFile
                    promoted.isEnabled = true
                    byPath[key] = promoted
                }
            } else {
                byPath[key] = folder
            }
        }

        let originalOrder = configuration.watchedFolders.compactMap { folder -> AgentWatchedFolder? in
            let key = URL(fileURLWithPath: folder.path).standardizedFileURL.path.lowercased()
            return byPath.removeValue(forKey: key)
        }
        output.watchedFolders =
            originalOrder
            + byPath.values.sorted {
                if $0.isManaged != $1.isManaged { return !$0.isManaged }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        return output.validated()
    }

    public static func stableID(provider: AgentProvider, path: String) -> String {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        return "agent-source-" + String(SHA256Digest.hashHex("\(provider.rawValue)\u{0}\(canonical)").prefix(24))
    }
}
