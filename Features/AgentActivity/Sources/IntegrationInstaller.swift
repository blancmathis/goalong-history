import Darwin
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
    case configurationUnavailable(URL)
    case unsafeConfiguration(URL)
    case configurationTooLarge(URL, actualBytes: Int64, maximumBytes: Int64)
    case configurationChangedDuringRead(URL)
    case executableUnavailable
    case unmanagedOpenCodePlugin(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let url):
            return "The existing configuration at \(url.path) is not a JSON object. It was not changed."
        case .configurationUnavailable(let url):
            return "The existing configuration at \(url.path) is not readable. It was not changed."
        case .unsafeConfiguration(let url):
            return
                "The existing configuration at \(url.path) is not a regular file or is a symbolic link. It was not changed."
        case .configurationTooLarge(let url, let actualBytes, let maximumBytes):
            return
                "The existing configuration at \(url.path) is \(actualBytes) bytes and exceeds the \(maximumBytes)-byte safety limit. It was not changed."
        case .configurationChangedDuringRead(let url):
            return
                "The existing configuration at \(url.path) changed while it was being read. It was not changed by Goalong History."
        case .executableUnavailable:
            return "The Goalong History executable path is unavailable."
        case .unmanagedOpenCodePlugin(let url):
            return "A different file already exists at \(url.path). It was not overwritten."
        }
    }
}

public final class AgentIntegrationInstaller: @unchecked Sendable {
    static let maximumConfigurationBytes: Int64 = 1 * 1_024 * 1_024
    static let maximumManagedBackupsPerConfiguration = 3

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
            installed = jsonFile(
                at: url,
                recursivelyContainsAll: [marker, executableURL.path]
            )
        case .openCodePlugin:
            let source: String?
            do {
                source = try readConfigurationIfPresent(at: url).flatMap {
                    String(data: $0, encoding: .utf8)
                }
            } catch {
                source = nil
            }
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
            guard let data = try readConfigurationIfPresent(at: url) else { return }
            guard let text = String(data: data, encoding: .utf8) else {
                throw AgentIntegrationInstallerError.unmanagedOpenCodePlugin(url)
            }
            guard text.contains(openCodeMarker) else {
                throw AgentIntegrationInstallerError.unmanagedOpenCodePlugin(url)
            }
            try backup(url, contents: data)
            try unlinkRegularConfiguration(at: url)
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
        removeGoalongHooks(from: &hooks)
        // Hooks only wake direct-source discovery. Keep them to durable session boundaries;
        // the shared 30-second metadata poll covers ordinary file edits without spawning a
        // Goalong process for every provider tool call.
        let events: [(name: String, matcher: String?)] = [
            ("PreCompact", nil),
            ("Stop", nil),
            ("SessionEnd", nil),
        ]
        for event in events {
            var definitions = hooks[event.name] as? [[String: Any]] ?? []
            var definition: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": hookCommand(provider: .codex, eventName: event.name),
                        "timeout": 3,
                    ]
                ]
            ]
            if let matcher = event.matcher {
                definition["matcher"] = matcher
            }
            definitions.append(definition)
            hooks[event.name] = definitions
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
        removeGoalongHooks(from: &hooks)
        let events: [(name: String, matcher: String?)] = [
            ("PreCompact", nil),
            ("Stop", nil),
            ("SessionEnd", nil),
        ]
        for event in events {
            var definitions = hooks[event.name] as? [[String: Any]] ?? []
            var definition: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": hookCommand(provider: .claudeCode, eventName: event.name),
                        "timeout": 3,
                    ]
                ]
            ]
            if let matcher = event.matcher {
                definition["matcher"] = matcher
            }
            definitions.append(definition)
            hooks[event.name] = definitions
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeClaudeHooks() throws {
        try removeNestedHooks(at: configurationURL(for: .claudeCodeHooks))
    }

    private func removeNestedHooks(at url: URL) throws {
        var root = try loadJSONObject(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        removeGoalongHooks(from: &hooks)
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeGoalongHooks(from hooks: inout [String: Any]) {
        for event in Array(hooks.keys) {
            guard let definitions = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = removingGoalongNestedHooks(from: definitions)
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
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
        removeGoalongHooks(from: &hooks)
        let events = ["preCompact", "stop", "sessionEnd"]
        for event in events {
            var definitions = hooks[event] as? [[String: Any]] ?? []
            definitions.append(["command": hookCommand(provider: .cursor, eventName: event)])
            hooks[event] = definitions
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeCursorHooks() throws {
        let url = configurationURL(for: .cursorHooks)
        var root = try loadJSONObject(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        removeGoalongHooks(from: &hooks)
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func installOpenCodePlugin() throws {
        let url = configurationURL(for: .openCodePlugin)
        let current: String?
        let currentData = try readConfigurationIfPresent(at: url)
        if let currentData {
            guard let existing = String(data: currentData, encoding: .utf8) else {
                throw AgentIntegrationInstallerError.unmanagedOpenCodePlugin(url)
            }
            guard existing.contains(openCodeMarker) else {
                throw AgentIntegrationInstallerError.unmanagedOpenCodePlugin(url)
            }
            current = existing
        } else {
            current = nil
        }
        let encodedPath = try jsonString(executableURL.path)
        let source = """
            // \(openCodeMarker)
            const GOALONG_EXECUTABLE = \(encodedPath)
            // The provider's own database remains canonical; these are coalesced wake-up hints only.
            const GOALONG_SIGNAL_EVENTS = new Set([
              "session.idle",
              "session.compacted",
              "session.deleted",
            ])
            const GOALONG_DEBOUNCE_MS = 1000
            const GOALONG_CHILD_TIMEOUT_MS = 3000
            let pendingEventName = null
            let debounceTimer = null
            let childInFlight = false

            function scheduleGoalongHistorySignal(eventName) {
              if (!GOALONG_SIGNAL_EVENTS.has(eventName)) return
              pendingEventName = eventName
              if (childInFlight) return
              if (debounceTimer !== null) clearTimeout(debounceTimer)
              debounceTimer = setTimeout(flushGoalongHistorySignal, GOALONG_DEBOUNCE_MS)
            }

            function flushGoalongHistorySignal() {
              debounceTimer = null
              if (pendingEventName === null || childInFlight) return
              const eventName = pendingEventName
              pendingEventName = null
              try {
                const child = Bun.spawn({
                  cmd: [GOALONG_EXECUTABLE, "--agent-hook-ingest", "openCode", eventName],
                  stdin: "ignore",
                  stdout: "ignore",
                  stderr: "ignore",
                })
                childInFlight = true
                const childTimeout = setTimeout(() => {
                  try { child.kill() } catch (_) {}
                }, GOALONG_CHILD_TIMEOUT_MS)
                Promise.resolve(child.exited).catch(() => {}).finally(() => {
                  clearTimeout(childTimeout)
                  childInFlight = false
                  if (pendingEventName !== null && debounceTimer === null) {
                    debounceTimer = setTimeout(flushGoalongHistorySignal, GOALONG_DEBOUNCE_MS)
                  }
                })
              } catch (_) {
                childInFlight = false
                // A discovery hint must never break OpenCode's agent loop.
              }
            }

            export const GoalongHistoryPlugin = async () => ({
              event: ({ event }) => {
                scheduleGoalongHistorySignal(event?.type)
              },
            })
            """
        guard current != source else {
            try pruneManagedBackups(for: url)
            return
        }
        if let currentData { try backup(url, contents: currentData) }
        try secureWrite(Data(source.utf8), to: url)
        try pruneManagedBackups(for: url)
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
        guard let data = try readConfigurationIfPresent(at: url) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIntegrationInstallerError.invalidConfiguration(url)
        }
        return object
    }

    private func writeJSONObject(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard Int64(data.count) <= Self.maximumConfigurationBytes else {
            throw AgentIntegrationInstallerError.configurationTooLarge(
                url,
                actualBytes: Int64(data.count),
                maximumBytes: Self.maximumConfigurationBytes
            )
        }
        if let currentData = try readConfigurationIfPresent(at: url) {
            if currentData == data {
                try pruneManagedBackups(for: url)
                return
            }
            try backup(url, contents: currentData)
        }
        try secureWrite(data, to: url)
        try pruneManagedBackups(for: url)
    }

    private func secureWrite(_ data: Data, to url: URL) throws {
        guard Int64(data.count) <= Self.maximumConfigurationBytes else {
            throw AgentIntegrationInstallerError.configurationTooLarge(
                url,
                actualBytes: Int64(data.count),
                maximumBytes: Self.maximumConfigurationBytes
            )
        }
        try validateWritableDestination(at: url)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func backup(_ url: URL, contents: Data) throws {
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        let suffix = UUID().uuidString.prefix(8)
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + ".goalong-backup-\(stamp)-\(suffix)",
            isDirectory: false
        )
        try secureWrite(contents, to: backup)
        do {
            try pruneManagedBackups(for: url, preserving: backup)
        } catch {
            try? unlinkRegularFile(at: backup)
            throw error
        }
    }

    private func jsonFile(at url: URL, recursivelyContainsAll needles: [String]) -> Bool {
        guard let data = try? readConfigurationIfPresent(at: url),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return needles.allSatisfy { Self.recursivelyContains(object, needle: $0) }
    }

    private struct FileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            byteCount = Int64(status.st_size)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    private func readConfigurationIfPresent(at url: URL) throws -> Data? {
        var pathStatus = stat()
        guard url.path.withCString({ lstat($0, &pathStatus) }) == 0 else {
            if errno == ENOENT { return nil }
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
        guard pathStatus.st_mode & S_IFMT == S_IFREG else {
            throw AgentIntegrationInstallerError.unsafeConfiguration(url)
        }

        let pathSnapshot = FileSnapshot(pathStatus)
        guard pathSnapshot.byteCount >= 0,
            pathSnapshot.byteCount <= Self.maximumConfigurationBytes
        else {
            throw AgentIntegrationInstallerError.configurationTooLarge(
                url,
                actualBytes: max(0, pathSnapshot.byteCount),
                maximumBytes: Self.maximumConfigurationBytes
            )
        }

        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw AgentIntegrationInstallerError.unsafeConfiguration(url) }
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            openedStatus.st_mode & S_IFMT == S_IFREG
        else {
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
        let openedSnapshot = FileSnapshot(openedStatus)
        guard openedSnapshot.device == pathSnapshot.device,
            openedSnapshot.inode == pathSnapshot.inode
        else {
            throw AgentIntegrationInstallerError.configurationChangedDuringRead(url)
        }
        guard openedSnapshot.byteCount >= 0,
            openedSnapshot.byteCount <= Self.maximumConfigurationBytes
        else {
            throw AgentIntegrationInstallerError.configurationTooLarge(
                url,
                actualBytes: max(0, openedSnapshot.byteCount),
                maximumBytes: Self.maximumConfigurationBytes
            )
        }

        var data = Data()
        data.reserveCapacity(Int(openedSnapshot.byteCount))
        let maximumReadCount = Int(Self.maximumConfigurationBytes) + 1
        do {
            while data.count < maximumReadCount {
                let count = min(64 * 1_024, maximumReadCount - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
        let finalSnapshot = FileSnapshot(finalStatus)
        if Int64(data.count) > Self.maximumConfigurationBytes
            || finalSnapshot.byteCount > Self.maximumConfigurationBytes
        {
            throw AgentIntegrationInstallerError.configurationTooLarge(
                url,
                actualBytes: max(Int64(data.count), finalSnapshot.byteCount),
                maximumBytes: Self.maximumConfigurationBytes
            )
        }
        guard openedSnapshot == finalSnapshot,
            finalSnapshot.byteCount == Int64(data.count)
        else {
            throw AgentIntegrationInstallerError.configurationChangedDuringRead(url)
        }
        return data
    }

    private func validateWritableDestination(at url: URL) throws {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { return }
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw AgentIntegrationInstallerError.unsafeConfiguration(url)
        }
    }

    private func pruneManagedBackups(
        for configurationURL: URL,
        preserving preservedBackup: URL? = nil
    ) throws {
        let directory = configurationURL.deletingLastPathComponent()
        let prefix = configurationURL.lastPathComponent + ".goalong-backup-"
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let backups = children.filter { child in
            isManagedBackupName(child.lastPathComponent, prefix: prefix)
                && isRegularFileWithoutFollowingLinks(child)
        }.sorted { lhs, rhs in
            if lhs == preservedBackup { return false }
            if rhs == preservedBackup { return true }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }

        let excessCount = max(0, backups.count - Self.maximumManagedBackupsPerConfiguration)
        for backup in backups.prefix(excessCount) {
            try unlinkRegularFile(at: backup)
        }
        for backup in backups.dropFirst(excessCount) {
            try setPrivatePermissionsWithoutFollowingLinks(at: backup)
        }
    }

    private func isManagedBackupName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        let pieces = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2,
            Int64(pieces[0]) != nil,
            pieces[1].count == 8
        else { return false }
        return pieces[1].allSatisfy { $0.isHexDigit }
    }

    private func isRegularFileWithoutFollowingLinks(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString({ lstat($0, &status) }) == 0
            && status.st_mode & S_IFMT == S_IFREG
    }

    private func setPrivatePermissionsWithoutFollowingLinks(at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
    }

    private func unlinkRegularConfiguration(at url: URL) throws {
        guard isRegularFileWithoutFollowingLinks(url) else {
            throw AgentIntegrationInstallerError.unsafeConfiguration(url)
        }
        try unlinkRegularFile(at: url)
    }

    private func unlinkRegularFile(at url: URL) throws {
        guard isRegularFileWithoutFollowingLinks(url) else {
            throw AgentIntegrationInstallerError.unsafeConfiguration(url)
        }
        guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw AgentIntegrationInstallerError.configurationUnavailable(url)
        }
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
