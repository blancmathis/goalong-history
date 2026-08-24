#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct ChatGPTImportedMessage: Codable, Equatable, Identifiable {
        let id: String
        let conversationID: String
        let conversationTitle: String
        let role: String
        let createdAt: Date
        let text: String
    }

    struct ChatGPTImportSummary: Codable, Equatable {
        let importedAt: Date
        let conversationCount: Int
        let messageCount: Int
        let firstMessageAt: Date?
        let lastMessageAt: Date?
        let sourceSHA256: String

        static let empty = ChatGPTImportSummary(
            importedAt: Date(timeIntervalSince1970: 0),
            conversationCount: 0,
            messageCount: 0,
            firstMessageAt: nil,
            lastMessageAt: nil,
            sourceSHA256: ""
        )
    }

    private struct ChatGPTNormalizedArchive: Codable, Equatable {
        let schemaVersion: Int
        let summary: ChatGPTImportSummary
        let messages: [ChatGPTImportedMessage]
    }

    enum ChatGPTHistoryStoreError: LocalizedError {
        case fileTooLarge(Int64)
        case sourceIsSymbolicLink
        case sourceIsNotRegularFile
        case sourceChangedDuringRead
        case sourceReadFailed(String)
        case invalidRoot
        case noMessages
        case tooManyMessages

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let bytes):
                return "The ChatGPT export is too large to import safely (\(bytes) bytes)."
            case .sourceIsSymbolicLink:
                return "The ChatGPT export must be a regular file, not a symbolic link."
            case .sourceIsNotRegularFile:
                return "The ChatGPT export must be a regular file."
            case .sourceChangedDuringRead:
                return
                    "The ChatGPT export changed, grew, or was replaced while Goalong was reading it. Nothing was imported."
            case .sourceReadFailed(let message):
                return "The ChatGPT export could not be read safely: \(message)"
            case .invalidRoot:
                return "Choose the conversations.json file from a ChatGPT data export."
            case .noMessages:
                return "No dated user or assistant messages were found in this export."
            case .tooManyMessages:
                return "The export contains more than 250,000 messages and was not imported."
            }
        }
    }

    enum ChatGPTSourceReadCheckpoint {
        case opened
        case reachedEnd
    }

    enum ChatGPTSecureStorageCheckpoint {
        case directoryPinned
    }

    enum ChatGPTSecureStorageError: LocalizedError {
        case unsafeDirectory(URL)
        case unsafeFile(URL)
        case posix(operation: String, url: URL, code: Int32)

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory(let url):
                return "Goalong refused an unsafe ChatGPT storage directory at \(url.path)."
            case .unsafeFile(let url):
                return "Goalong refused an unsafe ChatGPT storage file at \(url.path)."
            case .posix(let operation, let url, let code):
                return
                    "Goalong could not \(operation) the ChatGPT storage directory at \(url.path): \(String(cString: strerror(code)))"
            }
        }
    }

    enum ChatGPTSecureStorage {
        private final class DirectoryCapability {
            let descriptor: Int32

            init(descriptor: Int32) {
                self.descriptor = descriptor
            }

            deinit {
                Darwin.close(descriptor)
            }
        }

        static func prepareDirectory(_ directory: URL) throws {
            guard
                try pinDirectory(
                    directory,
                    createIfMissing: true,
                    enforceOwnerOnlyPermissions: true
                ) != nil
            else {
                throw ChatGPTSecureStorageError.unsafeDirectory(directory)
            }
        }

        static func writeFileAtomically(
            _ data: Data,
            to destination: URL,
            checkpoint: ((ChatGPTSecureStorageCheckpoint) -> Void)? = nil
        ) throws {
            let directory = destination.deletingLastPathComponent()
            let name = destination.lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else {
                throw ChatGPTSecureStorageError.unsafeFile(destination)
            }
            guard
                let directoryCapability = try pinDirectory(
                    directory,
                    createIfMissing: true,
                    enforceOwnerOnlyPermissions: true
                )
            else {
                throw ChatGPTSecureStorageError.unsafeDirectory(directory)
            }
            try withExtendedLifetime(directoryCapability) {
                let directoryDescriptor = directoryCapability.descriptor
                checkpoint?(.directoryPinned)

                var existingStatus = stat()
                let lookup = name.withCString {
                    Darwin.fstatat(
                        directoryDescriptor,
                        $0,
                        &existingStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard lookup != 0 || (existingStatus.st_mode & S_IFMT) == S_IFREG else {
                    throw ChatGPTSecureStorageError.unsafeFile(destination)
                }
                if lookup != 0, errno != ENOENT {
                    throw ChatGPTSecureStorageError.posix(
                        operation: "inspect",
                        url: destination,
                        code: errno
                    )
                }

                let temporaryName = ".\(name).\(UUID().uuidString).tmp"
                let descriptor = temporaryName.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(0o600)
                    )
                }
                guard descriptor >= 0 else {
                    throw ChatGPTSecureStorageError.posix(
                        operation: "create a temporary file for",
                        url: destination,
                        code: errno
                    )
                }
                var removeTemporary = true
                defer {
                    Darwin.close(descriptor)
                    if removeTemporary {
                        _ = temporaryName.withCString {
                            Darwin.unlinkat(directoryDescriptor, $0, 0)
                        }
                    }
                }

                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(
                            descriptor,
                            bytes.baseAddress?.advanced(by: offset),
                            bytes.count - offset
                        )
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else {
                            throw ChatGPTSecureStorageError.posix(
                                operation: "write",
                                url: destination,
                                code: errno
                            )
                        }
                        offset += written
                    }
                }
                var writtenStatus = stat()
                guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
                    Darwin.fstat(descriptor, &writtenStatus) == 0,
                    (writtenStatus.st_mode & S_IFMT) == S_IFREG,
                    (writtenStatus.st_mode & mode_t(0o777)) == mode_t(0o600),
                    writtenStatus.st_uid == Darwin.geteuid(),
                    try !hasExtendedAccessControlList(
                        descriptor: descriptor,
                        url: destination
                    )
                else {
                    throw ChatGPTSecureStorageError.unsafeFile(destination)
                }
                try syncDescriptor(
                    descriptor,
                    operation: "sync",
                    url: destination
                )

                let renamed = temporaryName.withCString { temporary in
                    name.withCString { finalName in
                        Darwin.renameat(
                            directoryDescriptor,
                            temporary,
                            directoryDescriptor,
                            finalName
                        )
                    }
                }
                guard renamed == 0 else {
                    throw ChatGPTSecureStorageError.posix(
                        operation: "install",
                        url: destination,
                        code: errno
                    )
                }
                removeTemporary = false
                try syncDescriptor(
                    directoryDescriptor,
                    operation: "sync the directory containing",
                    url: destination
                )
            }
        }

        static func removeRegularFileIfPresent(
            at destination: URL,
            checkpoint: ((ChatGPTSecureStorageCheckpoint) -> Void)? = nil
        ) throws {
            let directory = destination.deletingLastPathComponent()
            let name = destination.lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else {
                throw ChatGPTSecureStorageError.unsafeFile(destination)
            }
            guard
                let directoryCapability = try pinDirectory(
                    directory,
                    createIfMissing: false,
                    enforceOwnerOnlyPermissions: false
                )
            else { return }
            try withExtendedLifetime(directoryCapability) {
                let directoryDescriptor = directoryCapability.descriptor
                checkpoint?(.directoryPinned)

                var status = stat()
                let lookup = name.withCString {
                    Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                guard lookup == 0 else {
                    if errno == ENOENT { return }
                    throw ChatGPTSecureStorageError.posix(
                        operation: "inspect",
                        url: destination,
                        code: errno
                    )
                }
                guard (status.st_mode & S_IFMT) == S_IFREG else {
                    throw ChatGPTSecureStorageError.unsafeFile(destination)
                }
                let removed = name.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
                guard removed == 0 else {
                    throw ChatGPTSecureStorageError.posix(
                        operation: "remove",
                        url: destination,
                        code: errno
                    )
                }
                try syncDescriptor(
                    directoryDescriptor,
                    operation: "sync the directory containing",
                    url: destination
                )
            }
        }

        private static func pinDirectory(
            _ directory: URL,
            createIfMissing: Bool,
            enforceOwnerOnlyPermissions: Bool
        ) throws -> DirectoryCapability? {
            let components = directory.path.split(separator: "/", omittingEmptySubsequences: true)
            guard directory.isFileURL, directory.path.hasPrefix("/"), !components.isEmpty else {
                throw ChatGPTSecureStorageError.unsafeDirectory(directory)
            }

            let rootDescriptor = Darwin.open(
                "/",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard rootDescriptor >= 0 else {
                throw ChatGPTSecureStorageError.posix(
                    operation: "open",
                    url: directory,
                    code: errno
                )
            }
            var current = DirectoryCapability(descriptor: rootDescriptor)

            for (index, componentSlice) in components.enumerated() {
                let component = String(componentSlice)
                guard component != ".", component != ".." else {
                    throw ChatGPTSecureStorageError.unsafeDirectory(directory)
                }
                let isFinal = index == components.count - 1
                var created = false
                var nextDescriptor = component.withCString {
                    Darwin.openat(
                        current.descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }

                if nextDescriptor < 0, errno == ENOENT, isFinal, createIfMissing {
                    let createdResult = component.withCString {
                        Darwin.mkdirat(current.descriptor, $0, mode_t(0o700))
                    }
                    if createdResult == 0 {
                        created = true
                    } else if errno != EEXIST {
                        throw ChatGPTSecureStorageError.posix(
                            operation: "create",
                            url: directory,
                            code: errno
                        )
                    }
                    nextDescriptor = component.withCString {
                        Darwin.openat(
                            current.descriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                }

                guard nextDescriptor >= 0 else {
                    let code = errno
                    if code == ENOENT, !createIfMissing { return nil }
                    if code == ELOOP || code == ENOTDIR {
                        throw ChatGPTSecureStorageError.unsafeDirectory(directory)
                    }
                    throw ChatGPTSecureStorageError.posix(
                        operation: "open",
                        url: directory,
                        code: code
                    )
                }

                let next = DirectoryCapability(descriptor: nextDescriptor)
                if isFinal {
                    var status = stat()
                    guard Darwin.fstat(next.descriptor, &status) == 0,
                        (status.st_mode & S_IFMT) == S_IFDIR,
                        status.st_uid == Darwin.geteuid(),
                        try !hasExtendedAccessControlList(
                            descriptor: next.descriptor,
                            url: directory
                        )
                    else {
                        throw ChatGPTSecureStorageError.unsafeDirectory(directory)
                    }

                    if enforceOwnerOnlyPermissions {
                        var metadataChanged = created
                        if (status.st_mode & mode_t(0o777)) != mode_t(0o700) {
                            guard Darwin.fchmod(next.descriptor, mode_t(0o700)) == 0 else {
                                throw ChatGPTSecureStorageError.unsafeDirectory(directory)
                            }
                            metadataChanged = true
                        }
                        guard Darwin.fstat(next.descriptor, &status) == 0,
                            (status.st_mode & S_IFMT) == S_IFDIR,
                            (status.st_mode & mode_t(0o777)) == mode_t(0o700)
                        else {
                            throw ChatGPTSecureStorageError.unsafeDirectory(directory)
                        }
                        if metadataChanged {
                            try syncDescriptor(
                                next.descriptor,
                                operation: "sync",
                                url: directory
                            )
                        }
                        if created {
                            try syncDescriptor(
                                current.descriptor,
                                operation: "sync the parent of",
                                url: directory
                            )
                        }
                    }
                }
                current = next
            }
            return current
        }

        private static func hasExtendedAccessControlList(
            descriptor: Int32,
            url: URL
        ) throws -> Bool {
            errno = 0
            guard let accessControlList = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
                let code = errno
                if code == ENOENT || code == EOPNOTSUPP { return false }
                throw ChatGPTSecureStorageError.posix(
                    operation: "inspect access controls for",
                    url: url,
                    code: code
                )
            }
            defer {
                Darwin.acl_free(UnsafeMutableRawPointer(accessControlList))
            }
            return true
        }

        private static func syncDescriptor(
            _ descriptor: Int32,
            operation: String,
            url: URL
        ) throws {
            while Darwin.fsync(descriptor) != 0 {
                let code = errno
                if code == EINTR { continue }
                throw ChatGPTSecureStorageError.posix(
                    operation: operation,
                    url: url,
                    code: code
                )
            }
        }
    }

    final class ChatGPTHistoryStore {
        static let maximumSourceBytes: Int64 = 512 * 1_024 * 1_024
        static let maximumArchiveBytes: Int64 = 512 * 1_024 * 1_024
        static let maximumMessages = 250_000
        static let maximumPreservedIdentifierBytes = 256

        let rootDirectory: URL
        let archiveFile: URL

        private let encoder: JSONEncoder
        private let decoder: JSONDecoder

        init(rootDirectory: URL, fileManager _: FileManager = .default) {
            self.rootDirectory = rootDirectory
            self.archiveFile = self.rootDirectory.appendingPathComponent(
                "normalized-conversations.json", isDirectory: false)
            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
        }

        func importConversations(
            from sourceURL: URL,
            importedAt: Date = Date(),
            sourceReadCheckpoint: ((ChatGPTSourceReadCheckpoint) -> Void)? = nil
        ) throws -> ChatGPTImportSummary {
            let data = try Self.readStableSource(
                at: sourceURL,
                maximumBytes: Self.maximumSourceBytes,
                checkpoint: sourceReadCheckpoint
            )
            let parsed = try Self.parseConversations(data: data)
            guard !parsed.messages.isEmpty else { throw ChatGPTHistoryStoreError.noMessages }
            guard parsed.messages.count <= Self.maximumMessages else {
                throw ChatGPTHistoryStoreError.tooManyMessages
            }

            let sorted = parsed.messages.sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            let summary = ChatGPTImportSummary(
                importedAt: importedAt,
                conversationCount: parsed.conversationIDs.count,
                messageCount: sorted.count,
                firstMessageAt: sorted.first?.createdAt,
                lastMessageAt: sorted.last?.createdAt,
                sourceSHA256: SHA256Digest.hashHex(data)
            )
            let archive = ChatGPTNormalizedArchive(
                schemaVersion: 1,
                summary: summary,
                messages: sorted
            )
            if let existing = loadArchive(),
                existing.schemaVersion == archive.schemaVersion,
                existing.summary.sourceSHA256 == summary.sourceSHA256,
                existing.messages == sorted
            {
                return existing.summary
            }
            let archiveData = try encoder.encode(archive)
            guard Int64(archiveData.count) <= Self.maximumArchiveBytes else {
                throw ChatGPTHistoryStoreError.fileTooLarge(Int64(archiveData.count))
            }
            try prepare()
            try secureWrite(archiveData, to: archiveFile)
            return summary
        }

        static func readStableSource(
            at sourceURL: URL,
            maximumBytes: Int64,
            checkpoint: ((ChatGPTSourceReadCheckpoint) -> Void)? = nil
        ) throws -> Data {
            let descriptor = sourceURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                if errno == ELOOP {
                    throw ChatGPTHistoryStoreError.sourceIsSymbolicLink
                }
                throw ChatGPTHistoryStoreError.sourceReadFailed(posixMessage(errno))
            }
            defer { Darwin.close(descriptor) }

            var initialStatus = stat()
            guard Darwin.fstat(descriptor, &initialStatus) == 0 else {
                throw ChatGPTHistoryStoreError.sourceReadFailed(posixMessage(errno))
            }
            guard (initialStatus.st_mode & S_IFMT) == S_IFREG else {
                throw ChatGPTHistoryStoreError.sourceIsNotRegularFile
            }
            let initialSize = Int64(initialStatus.st_size)
            guard initialSize >= 0, initialSize <= maximumBytes else {
                throw ChatGPTHistoryStoreError.fileTooLarge(max(0, initialSize))
            }

            checkpoint?(.opened)
            var data = Data()
            data.reserveCapacity(Int(initialSize))
            var scratch = [UInt8](repeating: 0, count: 64 * 1_024)
            while data.count < Int(initialSize) {
                let remaining = Int(initialSize) - data.count
                let requested = min(scratch.count, remaining)
                let count = scratch.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, requested)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else {
                    throw ChatGPTHistoryStoreError.sourceReadFailed(posixMessage(errno))
                }
                guard count > 0 else {
                    throw ChatGPTHistoryStoreError.sourceChangedDuringRead
                }
                data.append(contentsOf: scratch.prefix(count))
            }

            var trailingByte: UInt8 = 0
            var trailingCount: Int
            repeat {
                trailingCount = Darwin.read(descriptor, &trailingByte, 1)
            } while trailingCount < 0 && errno == EINTR
            guard trailingCount >= 0 else {
                throw ChatGPTHistoryStoreError.sourceReadFailed(posixMessage(errno))
            }
            guard trailingCount == 0 else {
                throw ChatGPTHistoryStoreError.sourceChangedDuringRead
            }

            checkpoint?(.reachedEnd)
            var finalStatus = stat()
            guard Darwin.fstat(descriptor, &finalStatus) == 0 else {
                throw ChatGPTHistoryStoreError.sourceReadFailed(posixMessage(errno))
            }
            guard sameFileSnapshot(initialStatus, finalStatus),
                Int64(data.count) == initialSize
            else {
                throw ChatGPTHistoryStoreError.sourceChangedDuringRead
            }

            let verificationDescriptor = sourceURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard verificationDescriptor >= 0 else {
                throw ChatGPTHistoryStoreError.sourceChangedDuringRead
            }
            defer { Darwin.close(verificationDescriptor) }
            var pathStatus = stat()
            guard Darwin.fstat(verificationDescriptor, &pathStatus) == 0,
                sameFileSnapshot(initialStatus, pathStatus)
            else {
                throw ChatGPTHistoryStoreError.sourceChangedDuringRead
            }
            return data
        }

        func summary() -> ChatGPTImportSummary? {
            loadArchive()?.summary
        }

        func messages(for day: Date, calendar: Calendar = .current) -> [ChatGPTImportedMessage] {
            guard let interval = calendar.dateInterval(of: .day, for: day), let archive = loadArchive() else {
                return []
            }
            return archive.messages.filter {
                $0.createdAt >= interval.start && $0.createdAt < interval.end
            }
        }

        func removeImport() throws {
            try ChatGPTSecureStorage.removeRegularFileIfPresent(at: archiveFile)
        }

        private func loadArchive() -> ChatGPTNormalizedArchive? {
            guard
                let data = try? Self.readStableSource(
                    at: archiveFile,
                    maximumBytes: Self.maximumArchiveBytes
                )
            else { return nil }
            return try? decoder.decode(ChatGPTNormalizedArchive.self, from: data)
        }

        private func prepare() throws {
            try ChatGPTSecureStorage.prepareDirectory(rootDirectory)
        }

        private func secureWrite(_ data: Data, to destination: URL) throws {
            try ChatGPTSecureStorage.writeFileAtomically(data, to: destination)
        }

        struct ParsedConversations {
            let messages: [ChatGPTImportedMessage]
            let conversationIDs: Set<String>
        }

        static func parseConversations(data: Data) throws -> ParsedConversations {
            let root = try JSONSerialization.jsonObject(with: data, options: [])
            let rawConversations: [[String: Any]]
            if let array = root as? [[String: Any]] {
                rawConversations = array
            } else if let dictionary = root as? [String: Any],
                let array = dictionary["conversations"] as? [[String: Any]]
            {
                rawConversations = array
            } else {
                throw ChatGPTHistoryStoreError.invalidRoot
            }

            var messages: [ChatGPTImportedMessage] = []
            var conversationIDs = Set<String>()
            var seenMessageIDs = Set<String>()

            for (conversationIndex, conversation) in rawConversations.enumerated() {
                let rawConversationID =
                    string(conversation["id"])
                    ?? string(conversation["conversation_id"])
                    ?? "conversation-\(conversationIndex)"
                let conversationID = boundedIdentifier(
                    rawConversationID,
                    kind: "conversation"
                )
                let title =
                    sanitize(
                        string(conversation["title"]) ?? "Untitled conversation",
                        maximumLength: 300
                    ) ?? "Untitled conversation"
                let fallbackTimestamp =
                    timestamp(conversation["update_time"])
                    ?? timestamp(conversation["create_time"])
                guard let mapping = conversation["mapping"] as? [String: Any] else { continue }

                var foundInConversation = false
                for (nodeID, rawNode) in mapping {
                    guard let node = rawNode as? [String: Any],
                        let message = node["message"] as? [String: Any],
                        let author = message["author"] as? [String: Any],
                        let role = string(author["role"])?.lowercased(),
                        role == "user" || role == "assistant",
                        let createdAt = timestamp(message["create_time"])
                            ?? timestamp(message["update_time"])
                            ?? fallbackTimestamp,
                        let content = message["content"] as? [String: Any],
                        let text = text(from: content),
                        let clean = sanitize(text, maximumLength: 16_000),
                        !clean.isEmpty
                    else { continue }

                    let messageID = boundedIdentifier(
                        string(message["id"]) ?? nodeID,
                        kind: "message"
                    )
                    let stableID = "\(conversationID):\(messageID)"
                    guard seenMessageIDs.insert(stableID).inserted else { continue }
                    messages.append(
                        ChatGPTImportedMessage(
                            id: stableID,
                            conversationID: conversationID,
                            conversationTitle: title,
                            role: role,
                            createdAt: createdAt,
                            text: clean
                        )
                    )
                    foundInConversation = true
                    if messages.count > maximumMessages {
                        throw ChatGPTHistoryStoreError.tooManyMessages
                    }
                }
                if foundInConversation { conversationIDs.insert(conversationID) }
            }
            return ParsedConversations(messages: messages, conversationIDs: conversationIDs)
        }

        private static func text(from content: [String: Any]) -> String? {
            var pieces: [String] = []
            if let parts = content["parts"] as? [Any] {
                pieces.append(contentsOf: parts.compactMap(flattenText))
            }
            if pieces.isEmpty, let direct = flattenText(content["text"]) {
                pieces.append(direct)
            }
            if pieces.isEmpty, let direct = flattenText(content["content"]) {
                pieces.append(direct)
            }
            let value = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        private static func flattenText(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            if let array = value as? [Any] {
                let joined = array.compactMap(flattenText).joined(separator: "\n")
                return joined.isEmpty ? nil : joined
            }
            if let dictionary = value as? [String: Any] {
                for key in ["text", "content", "caption", "value"] {
                    if let nested = flattenText(dictionary[key]), !nested.isEmpty { return nested }
                }
            }
            return nil
        }

        private static func timestamp(_ value: Any?) -> Date? {
            if let number = value as? NSNumber {
                let seconds = number.doubleValue
                guard seconds.isFinite, seconds > 0 else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = value as? String, let seconds = Double(string), seconds > 0 {
                return Date(timeIntervalSince1970: seconds)
            }
            return nil
        }

        private static func string(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }

        private static func boundedIdentifier(_ raw: String, kind: String) -> String {
            if raw.utf8.count <= maximumPreservedIdentifierBytes,
                raw.unicodeScalars.allSatisfy({ scalar in
                    scalar.isASCII
                        && (CharacterSet.alphanumerics.contains(scalar)
                            || scalar == "-" || scalar == "_" || scalar == ".")
                }),
                ActivitySemanticTextSanitizer.redact(raw) == raw
            {
                return raw
            }
            return "\(kind)-sha256-\(SHA256Digest.hashHex(raw))"
        }

        private static func sanitize(_ value: String, maximumLength: Int) -> String? {
            ActivitySemanticTextSanitizer.clean(value, maximumLength: maximumLength)
        }

        private static func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
            (lhs.st_mode & S_IFMT) == S_IFREG
                && lhs.st_mode == rhs.st_mode
                && lhs.st_dev == rhs.st_dev
                && lhs.st_ino == rhs.st_ino
                && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        }

        private static func posixMessage(_ code: Int32) -> String {
            String(cString: strerror(code))
        }
    }
#endif
