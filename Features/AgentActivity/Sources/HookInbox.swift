import Darwin
import Dispatch
import Foundation

/// Discards hook stdin without decoding or retaining it, with hard time and byte limits.
public enum AgentHookInputDrainer {
    public static let maximumInputBytes = 1 * 1_024 * 1_024
    public static let maximumDrainMilliseconds: Int32 = 500

    private static let readChunkBytes = 64 * 1_024

    @discardableResult
    public static func discard(
        fromFileDescriptor fileDescriptor: Int32,
        maximumBytes requestedMaximumBytes: Int = maximumInputBytes,
        timeoutMilliseconds requestedTimeoutMilliseconds: Int32 = maximumDrainMilliseconds
    ) -> Int64 {
        guard fileDescriptor >= 0 else { return 0 }
        let maximumBytes = min(max(0, requestedMaximumBytes), Self.maximumInputBytes)
        let timeoutMilliseconds = min(
            max(0, requestedTimeoutMilliseconds),
            Self.maximumDrainMilliseconds
        )
        guard maximumBytes > 0, timeoutMilliseconds > 0 else { return 0 }

        let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var discardedBytes = 0
        var buffer = [UInt8](repeating: 0, count: min(Self.readChunkBytes, maximumBytes))
        defer {
            buffer.withUnsafeMutableBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    Darwin.memset(baseAddress, 0, rawBuffer.count)
                }
            }
        }

        while discardedBytes < maximumBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = Int32(
                min(
                    UInt64(Int32.max),
                    max(1, (remainingNanoseconds + 999_999) / 1_000_000)
                )
            )
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if pollResult < 0, errno == EINTR {
                continue
            }
            guard pollResult > 0 else { break }
            guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { break }
            guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { break }

            let requestedBytes = min(buffer.count, maximumBytes - discardedBytes)
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, requestedBytes)
            }
            if readCount < 0, errno == EINTR || errno == EAGAIN {
                continue
            }
            guard readCount > 0 else { break }
            buffer.withUnsafeMutableBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    Darwin.memset(baseAddress, 0, min(readCount, rawBuffer.count))
                }
            }
            discardedBytes += readCount
        }

        return Int64(discardedBytes)
    }
}

/// Hooks are wake-up hints only. Their stdin is discarded by the app executable and never persisted.
public enum AgentHookSignalWriter {
    private static let allowedEventNames: Set<String> = [
        "event",
        // Codex and Claude Code hook names.
        "SessionStart", "Setup", "UserPromptSubmit", "UserPromptExpansion", "PreToolUse",
        "PermissionRequest", "PermissionDenied", "PostToolUse", "PostToolUseFailure",
        "PostToolBatch", "Notification", "MessageDisplay", "SubagentStart", "SubagentStop",
        "TaskCreated", "TaskCompleted", "Stop", "StopFailure", "TeammateIdle",
        "InstructionsLoaded", "ConfigChange", "CwdChanged", "DirectoryAdded", "FileChanged",
        "WorktreeCreate", "WorktreeRemove", "PreCompact", "PostCompact", "Elicitation",
        "ElicitationResult", "SessionEnd",
        // Cursor hook names.
        "sessionStart", "sessionEnd", "workspaceOpen", "beforeSubmitPrompt", "preToolUse",
        "postToolUse", "postToolUseFailure", "beforeShellExecution", "afterShellExecution",
        "beforeMCPExecution", "afterMCPExecution", "beforeReadFile", "afterFileEdit",
        "beforeTabFileRead", "afterTabFileEdit", "subagentStart", "subagentStop", "preCompact",
        "afterAgentResponse", "afterAgentThought", "stop",
        // OpenCode event discriminator values. Unknown future events still wake discovery as `event`.
        "message.updated", "message.removed", "message.part.updated", "message.part.removed",
        "session.status", "session.idle", "session.compacted", "session.created", "session.updated",
        "session.deleted", "session.diff", "session.error", "file.edited", "file.watcher.updated",
        "permission.updated", "permission.replied", "project.updated", "server.connected",
        "server.instance.disposed", "command.executed", "tui.prompt.append", "tui.command.execute",
        "tui.toast.show", "tui.session.select", "installation.updated", "installation.update-available",
        "lsp.updated", "lsp.client.diagnostics", "mcp.tools.changed", "pty.created", "pty.updated",
        "pty.exited", "pty.deleted", "todo.updated",
    ]
    private static let maximumDiscardedPayloadBytes = Int64(AgentHookInputDrainer.maximumInputBytes)
    private static let maximumSignalFileBytes = 16 * 1_024

    @discardableResult
    public static func write(
        rootDirectory: URL,
        provider: AgentProvider,
        eventName: String,
        discardedPayloadBytes: Int64,
        processIdentifier: Int32,
        signaledAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("signals", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(directoryDescriptor) }
        try secureDescriptor(directoryDescriptor, expectedType: S_IFDIR, permissions: 0o700)

        let lockDescriptor = ".writer.lock".withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard lockDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(lockDescriptor) }
        try secureDescriptor(lockDescriptor, expectedType: S_IFREG, permissions: 0o600)
        guard flock(lockDescriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(lockDescriptor, LOCK_UN) }

        let destinationName = "\(provider.rawValue).json"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = try readPreviousSignal(
            named: destinationName,
            directoryDescriptor: directoryDescriptor,
            decoder: decoder
        )
        let event = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        let signal = AgentHookSignal(
            provider: provider,
            eventName: allowedEventNames.contains(event) ? event : "event",
            signaledAt: monotonicTimestamp(
                requested: signaledAt,
                after: previous?.provider == provider ? previous?.signaledAt : nil
            ),
            processIdentifier: max(0, processIdentifier),
            discardedPayloadBytes: min(max(0, discardedPayloadBytes), maximumDiscardedPayloadBytes)
        )
        try atomicWrite(
            encoder.encode(signal),
            named: destinationName,
            directoryDescriptor: directoryDescriptor
        )
        return directory.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
    }

    private static func readPreviousSignal(
        named name: String,
        directoryDescriptor: Int32,
        decoder: JSONDecoder
    ) throws -> AgentHookSignal? {
        let descriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { Darwin.close(descriptor) }
        try secureDescriptor(descriptor, expectedType: S_IFREG, permissions: 0o600)
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_size >= 0,
            status.st_size <= maximumSignalFileBytes
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG))
        }
        var data = Data(count: Int(status.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { break }
                throw posixError()
            }
            offset += count
        }
        data.count = offset
        return try? decoder.decode(AgentHookSignal.self, from: data)
    }

    private static func atomicWrite(
        _ data: Data,
        named name: String,
        directoryDescriptor: Int32
    ) throws {
        var destinationStatus = stat()
        let destinationResult = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &destinationStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if destinationResult == 0 {
            guard destinationStatus.st_mode & S_IFMT == S_IFREG else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
        } else if errno != ENOENT {
            throw posixError()
        }

        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard temporaryDescriptor >= 0 else { throw posixError() }
        var renamed = false
        defer {
            Darwin.close(temporaryDescriptor)
            if !renamed {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }
        try secureDescriptor(temporaryDescriptor, expectedType: S_IFREG, permissions: 0o600)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(
                    temporaryDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError() }
            offset += count
        }
        guard Darwin.fsync(temporaryDescriptor) == 0 else { throw posixError() }
        let renameResult = temporaryName.withCString { temporaryPointer in
            name.withCString { destinationPointer in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    destinationPointer
                )
            }
        }
        guard renameResult == 0 else { throw posixError() }
        renamed = true

        let destinationDescriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard destinationDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(destinationDescriptor) }
        try secureDescriptor(destinationDescriptor, expectedType: S_IFREG, permissions: 0o600)
        _ = Darwin.fsync(directoryDescriptor)
    }

    private static func secureDescriptor(
        _ descriptor: Int32,
        expectedType: mode_t,
        permissions: mode_t
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == expectedType,
            Darwin.fchmod(descriptor, permissions) == 0,
            Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == expectedType,
            status.st_mode & 0o777 == permissions
        else { throw posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func monotonicTimestamp(requested: Date, after previous: Date?) -> Date {
        let requestedSecond = floor(requested.timeIntervalSince1970)
        guard let previous else { return Date(timeIntervalSince1970: requestedSecond) }
        return Date(timeIntervalSince1970: max(requestedSecond, floor(previous.timeIntervalSince1970) + 1))
    }
}
