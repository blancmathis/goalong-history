#if os(macOS)
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

    private struct ChatGPTNormalizedArchive: Codable {
        let schemaVersion: Int
        let summary: ChatGPTImportSummary
        let messages: [ChatGPTImportedMessage]
    }

    enum ChatGPTHistoryStoreError: LocalizedError {
        case fileTooLarge(Int64)
        case invalidRoot
        case noMessages
        case tooManyMessages

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let bytes):
                return "The ChatGPT export is too large to import safely (\(bytes) bytes)."
            case .invalidRoot:
                return "Choose the conversations.json file from a ChatGPT data export."
            case .noMessages:
                return "No dated user or assistant messages were found in this export."
            case .tooManyMessages:
                return "The export contains more than 250,000 messages and was not imported."
            }
        }
    }

    final class ChatGPTHistoryStore {
        static let maximumSourceBytes: Int64 = 512 * 1_024 * 1_024
        static let maximumMessages = 250_000

        let rootDirectory: URL
        let archiveFile: URL

        private let fileManager: FileManager
        private let encoder: JSONEncoder
        private let decoder: JSONDecoder

        init(rootDirectory: URL, fileManager: FileManager = .default) {
            self.rootDirectory = rootDirectory.standardizedFileURL
            self.archiveFile = self.rootDirectory.appendingPathComponent(
                "normalized-conversations.json", isDirectory: false)
            self.fileManager = fileManager
            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
        }

        func importConversations(from sourceURL: URL, importedAt: Date = Date()) throws -> ChatGPTImportSummary {
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes <= Self.maximumSourceBytes else {
                throw ChatGPTHistoryStoreError.fileTooLarge(bytes)
            }

            let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
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
            try prepare()
            try secureWrite(try encoder.encode(archive), to: archiveFile)
            return summary
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
            if fileManager.fileExists(atPath: archiveFile.path) {
                try fileManager.removeItem(at: archiveFile)
            }
        }

        private func loadArchive() -> ChatGPTNormalizedArchive? {
            guard let data = try? Data(contentsOf: archiveFile) else { return nil }
            return try? decoder.decode(ChatGPTNormalizedArchive.self, from: data)
        }

        private func prepare() throws {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
        }

        private func secureWrite(_ data: Data, to destination: URL) throws {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
            try data.write(to: temporary, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
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
                let conversationID = string(conversation["id"])
                    ?? string(conversation["conversation_id"])
                    ?? "conversation-\(conversationIndex)"
                let title = sanitize(
                    string(conversation["title"]) ?? "Untitled conversation",
                    maximumLength: 300
                ) ?? "Untitled conversation"
                let fallbackTimestamp = timestamp(conversation["update_time"])
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

                    let messageID = string(message["id"]) ?? nodeID
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

        private static func sanitize(_ value: String, maximumLength: Int) -> String? {
            ActivitySemanticTextSanitizer.clean(value, maximumLength: maximumLength)
        }
    }
#endif
