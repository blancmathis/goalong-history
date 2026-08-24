import Darwin
import Foundation
import LocalHistoryCore

public enum AgentDefaultSourceDiscovery {
    private struct DirectoryIdentity: Hashable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private enum SourceKey: Hashable {
        case physical(DirectoryIdentity)
        case path(String)
    }

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
        Candidate(
            name: "Gemini CLI local history", relativePath: ".gemini/tmp", provider: .gemini,
            mode: .transcriptsAndLogs),
        Candidate(
            name: "VS Code Copilot Chat history",
            relativePath: "Library/Application Support/Code/User/workspaceStorage",
            provider: .copilot,
            mode: .transcriptsAndLogs
        ),
    ]

    public static func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager _: FileManager = .default
    ) -> [AgentWatchedFolder] {
        var discovered: [AgentWatchedFolder] = []
        var physicalDirectories = Set<DirectoryIdentity>()
        for candidate in candidates {
            guard let secureDirectory = secureDirectory(
                homeDirectory: homeDirectory,
                relativePath: candidate.relativePath
            ), physicalDirectories.insert(secureDirectory.identity).inserted
            else { continue }
            discovered.append(AgentWatchedFolder(
                id: stableID(provider: candidate.provider, path: secureDirectory.url.path),
                displayName: candidate.name,
                path: secureDirectory.url.path,
                provider: candidate.provider,
                captureMode: candidate.mode
            ))
        }
        return discovered
    }

    public static func merging(
        configuration: AgentActivityConfiguration,
        discovered: [AgentWatchedFolder],
        reallowSuppressedSources: Bool = false
    ) -> AgentActivityConfiguration {
        var output = configuration.validated()
        let normalizedDiscovered = discovered.map { folder -> AgentWatchedFolder in
            var normalized = folder
            normalized.path = URL(fileURLWithPath: folder.path).standardizedFileURL.path
            normalized.id = stableID(provider: folder.provider, path: normalized.path)
            normalized.isEnabled = reallowSuppressedSources
            return normalized
        }
        let discoveredConsentIDs = Set(normalizedDiscovered.flatMap { consentIDs(for: $0) })
        let discoveredSourceKeys = Set(normalizedDiscovered.map(sourceKey))

        if reallowSuppressedSources {
            output.discoveryTombstones.removeAll { discoveredConsentIDs.contains($0.sourceID) }
            for index in output.watchedFolders.indices {
                let folder = output.watchedFolders[index]
                if discoveredSourceKeys.contains(sourceKey(for: folder)) {
                    output.watchedFolders[index].isEnabled = true
                }
            }
        }

        let suppressedIDs = Set(output.discoveryTombstones.map(\.sourceID))
        var sourceKeys = Set<SourceKey>()
        var folders: [AgentWatchedFolder] = []
        folders.reserveCapacity(output.watchedFolders.count + normalizedDiscovered.count)
        for folder in output.watchedFolders {
            guard sourceKeys.insert(sourceKey(for: folder)).inserted else { continue }
            folders.append(folder)
        }
        for folder in normalizedDiscovered
            .filter({ reallowSuppressedSources || suppressedIDs.isDisjoint(with: consentIDs(for: $0)) })
            .sorted(by: {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            })
        {
            guard sourceKeys.insert(sourceKey(for: folder)).inserted else { continue }
            folders.append(folder)
        }
        output.watchedFolders = folders
        return output.validated()
    }

    public static func stableID(provider: AgentProvider, path: String) -> String {
        AgentFolderIdentifier.persisted(provider: provider, path: path)
    }

    public static func consentIDs(for folder: AgentWatchedFolder) -> Set<String> {
        let canonical = URL(fileURLWithPath: folder.path).standardizedFileURL.path
        let current = stableID(provider: folder.provider, path: canonical)
        return Set([folder.id, current].filter(AgentDiscoveryTombstone.isValidSourceID))
    }

    public static func isAutoDiscovered(_ folder: AgentWatchedFolder) -> Bool {
        AgentDiscoveryTombstone.isValidSourceID(folder.id)
    }

    private static func sourceKey(for folder: AgentWatchedFolder) -> SourceKey {
        if let identity = directoryIdentity(at: folder.url) { return .physical(identity) }
        return .path(folder.url.standardizedFileURL.path)
    }

    private static func directoryIdentity(at url: URL) -> DirectoryIdentity? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR
        else { return nil }
        return DirectoryIdentity(status)
    }

    private static func secureDirectory(
        homeDirectory: URL,
        relativePath: String
    ) -> (url: URL, identity: DirectoryIdentity)? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }

        let root = homeDirectory.standardizedFileURL
        var descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        for component in components {
            let child = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { return nil }
            _ = Darwin.close(descriptor)
            descriptor = child
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR
        else { return nil }
        return (
            root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL,
            DirectoryIdentity(status)
        )
    }
}

public enum AgentSourceAccessAuthority {
    public static func allows(
        _ entry: AgentSourceIndexEntry,
        configuration: AgentActivityConfiguration
    ) -> Bool {
        let validated = configuration.validated()
        guard let folder = validated.watchedFolders.first(where: {
            $0.id == entry.watchedFolderID && $0.provider == entry.provider && $0.isEnabled
        }) else { return false }

        let tombstones = Set(validated.discoveryTombstones.map(\.sourceID))
        guard tombstones.isDisjoint(with: AgentDefaultSourceDiscovery.consentIDs(for: folder)) else {
            return false
        }
        return regularFileIsContained(entry.reference.path, beneath: folder.path)
    }

    private static func regularFileIsContained(_ path: String, beneath rootPath: String) -> Bool {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let source = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        let rootComponents = root.pathComponents
        let sourceComponents = source.pathComponents
        guard sourceComponents.count > rootComponents.count,
            Array(sourceComponents.prefix(rootComponents.count)) == rootComponents
        else { return false }
        let relativeComponents = sourceComponents.dropFirst(rootComponents.count)
        guard relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }

        var descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        for component in relativeComponents.dropLast() {
            let child = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { return false }
            _ = Darwin.close(descriptor)
            descriptor = child
        }

        guard let fileName = relativeComponents.last else { return false }
        let fileDescriptor = fileName.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(fileDescriptor) }
        var status = stat()
        return Darwin.fstat(fileDescriptor, &status) == 0
            && status.st_mode & S_IFMT == S_IFREG
    }
}
