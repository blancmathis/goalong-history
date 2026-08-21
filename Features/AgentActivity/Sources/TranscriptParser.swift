import Foundation

public enum AgentTranscriptParser {
    public static func parse(data: Data, fileURL: URL, provider: AgentProvider) -> AgentDocumentSummary {
        if let envelope = decodeHookEnvelope(data) {
            var summary = parsePayload(envelope.payload, fileURL: fileURL, provider: envelope.provider)
            summary.format = .hookEvent
            if summary.title == nil { summary.title = humanized(envelope.eventName) }
            if summary.startedAt == nil { summary.startedAt = envelope.capturedAt }
            if summary.endedAt == nil { summary.endedAt = envelope.capturedAt }
            if envelope.eventName.lowercased().contains("tool"), summary.toolCallCount == 0 {
                summary.toolCallCount = 1
            }
            if envelope.eventName.lowercased().contains("error"), summary.errorCount == 0 {
                summary.errorCount = 1
            }
            if envelope.eventName.lowercased().contains("subagent"), summary.subagentCount == 0 {
                summary.subagentCount = 1
            }
            return summary
        }
        return parsePayload(data, fileURL: fileURL, provider: provider)
    }

    private static func parsePayload(_ data: Data, fileURL: URL, provider: AgentProvider) -> AgentDocumentSummary {
        let ext = fileURL.pathExtension.lowercased()
        if databaseExtensions.contains(ext) {
            return AgentDocumentSummary(
                format: .database,
                title: fileURL.deletingPathExtension().lastPathComponent
            )
        }

        if jsonLineExtensions.contains(ext), let text = String(data: data, encoding: .utf8) {
            var accumulator = Accumulator(fileURL: fileURL, provider: provider, format: .jsonLines)
            var parsedAny = false
            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = String(line).data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: lineData)
                else { continue }
                parsedAny = true
                accumulator.walk(object, path: [])
            }
            if parsedAny { return accumulator.finish() }
        }

        if jsonExtensions.contains(ext),
            let object = try? JSONSerialization.jsonObject(with: data)
        {
            var accumulator = Accumulator(fileURL: fileURL, provider: provider, format: .json)
            accumulator.walk(object, path: [])
            return accumulator.finish()
        }

        if let text = String(data: data, encoding: .utf8), !looksBinary(data) {
            return parseText(text, fileURL: fileURL, markdown: markdownExtensions.contains(ext))
        }

        return AgentDocumentSummary(
            format: looksBinary(data) ? .binary : .unknown,
            title: fileURL.deletingPathExtension().lastPathComponent
        )
    }

    private static func parseText(_ text: String, fileURL: URL, markdown: Bool) -> AgentDocumentSummary {
        let lines = text.components(separatedBy: .newlines)
        var summary = AgentDocumentSummary(
            format: markdown ? .markdown : .text,
            title: fileURL.deletingPathExtension().lastPathComponent
        )

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if summary.excerpt == nil {
                summary.excerpt = bounded(line, maximum: 360)
            }
            let lower = line.lowercased()
            if lower.hasPrefix("user:") || lower.hasPrefix("human:") || lower.hasPrefix("utilisateur:") {
                summary.messageCount += 1
                summary.userMessageCount += 1
            } else if lower.hasPrefix("assistant:") || lower.hasPrefix("agent:") {
                summary.messageCount += 1
                summary.assistantMessageCount += 1
            } else if lower.hasPrefix("system:") || lower.hasPrefix("developer:") {
                summary.messageCount += 1
                summary.systemMessageCount += 1
            }
            if lower.contains("tool call") || lower.hasPrefix("tool:") || lower.hasPrefix("command:") {
                summary.toolCallCount += 1
            }
            if lower.contains(" error:") || lower.hasPrefix("error:") || lower.contains(" failed") {
                summary.errorCount += 1
            }
        }
        return summary
    }

    private static func decodeHookEnvelope(_ data: Data) -> AgentHookEnvelope? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentHookEnvelope.self, from: data)
    }

    private struct Accumulator {
        let fileURL: URL
        let provider: AgentProvider
        let format: AgentDocumentFormat

        var sessionID: String?
        var title: String?
        var excerpt: String?
        var projectPath: String?
        var dates: [Date] = []
        var messageCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var systemMessageCount = 0
        var toolCallCount = 0
        var errorCount = 0
        var subagentCount = 0
        var models = OrderedSet(limit: 20)
        var tools = OrderedSet(limit: 80)
        var touchedFiles = OrderedSet(limit: 160)
        var commands = OrderedSet(limit: 80)

        mutating func walk(_ value: Any, path: [String]) {
            if let dictionary = value as? [String: Any] {
                inspect(dictionary, path: path)
                for (key, child) in dictionary {
                    walk(child, path: path + [key])
                }
            } else if let array = value as? [Any] {
                for child in array { walk(child, path: path) }
            } else if let string = value as? String {
                inspectLooseString(string, path: path)
            }
        }

        mutating func inspect(_ dictionary: [String: Any], path: [String]) {
            var normalized: [String: Any] = [:]
            normalized.reserveCapacity(dictionary.count)
            for key in dictionary.keys.sorted() {
                let normalizedKey = normalizeKey(key)
                guard !normalizedKey.isEmpty, normalized[normalizedKey] == nil else { continue }
                normalized[normalizedKey] = dictionary[key]
            }

            if sessionID == nil {
                sessionID = firstString(
                    normalized,
                    keys: ["sessionid", "conversationid", "threadid", "chatid", "runid"]
                ).flatMap(nonEmpty)
            }
            if title == nil {
                title = firstString(
                    normalized,
                    keys: ["title", "subject", "tasksubject", "tasktitle", "name"]
                ).flatMap { plausibleTitle($0) ? bounded($0, maximum: 180) : nil }
            }
            if projectPath == nil {
                projectPath = firstString(
                    normalized,
                    keys: ["cwd", "directory", "workspace", "workspaceroot", "worktree", "projectpath", "projectroot"]
                ).flatMap { plausiblePath($0) ? bounded($0, maximum: 500) : nil }
            }

            for key in ["model", "modelid", "modelname"] {
                if let value = normalized[key] as? String, plausibleIdentifier(value) {
                    models.insert(bounded(value, maximum: 120))
                }
            }

            let role = normalizedRole(from: normalized)
            let content = messageContent(from: normalized)
            if let role {
                messageCount += 1
                switch role {
                case "user", "human": userMessageCount += 1
                case "assistant", "agent": assistantMessageCount += 1
                case "system", "developer": systemMessageCount += 1
                default: break
                }
                if let content, excerpt == nil, role == "user" || role == "human" {
                    excerpt = bounded(content, maximum: 360)
                }
            } else if excerpt == nil, let content, content.count >= 12 {
                excerpt = bounded(content, maximum: 360)
            }

            let type =
                firstString(normalized, keys: ["type", "event", "eventname", "hookeventname", "kind"])?
                .lowercased() ?? ""
            let status =
                firstString(normalized, keys: ["status", "outcome", "resultstatus"])?
                .lowercased() ?? ""

            var countedTool = false
            if type.contains("tool") || normalized["toolname"] != nil || normalized["tool"] != nil {
                toolCallCount += 1
                countedTool = true
            }
            if let tool = toolName(from: normalized) {
                tools.insert(bounded(tool, maximum: 120))
                if !countedTool { toolCallCount += 1 }
            }

            if type.contains("subagent") || type.contains("sub_agent") {
                subagentCount += 1
            }
            if type.contains("error") || status == "failed" || status == "failure" || status == "error" {
                errorCount += 1
            } else if let error = normalized["error"], !isNullOrEmpty(error) {
                errorCount += 1
            }

            for (key, rawValue) in normalized {
                if timestampKeys.contains(key), let date = parseDate(rawValue) {
                    dates.append(date)
                }
                if fileKeys.contains(key), let raw = rawValue as? String, plausibleFilePath(raw) {
                    touchedFiles.insert(bounded(raw, maximum: 500))
                }
                if commandKeys.contains(key), let raw = flattenText(rawValue, depth: 0), plausibleCommand(raw) {
                    commands.insert(bounded(raw, maximum: 500))
                }
            }
        }

        mutating func inspectLooseString(_ string: String, path: [String]) {
            guard let key = path.last.map(normalizeKey) else { return }
            if excerpt == nil, ["prompt", "userprompt", "instruction", "request"].contains(key), string.count >= 12 {
                excerpt = bounded(string, maximum: 360)
            }
            if timestampKeys.contains(key), let date = parseDate(string) {
                dates.append(date)
            }
        }

        func finish() -> AgentDocumentSummary {
            let sortedDates = dates.sorted()
            return AgentDocumentSummary(
                format: format,
                sessionID: sessionID,
                title: title ?? fileURL.deletingPathExtension().lastPathComponent,
                excerpt: excerpt,
                projectPath: projectPath,
                startedAt: sortedDates.first,
                endedAt: sortedDates.last,
                messageCount: messageCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount,
                systemMessageCount: systemMessageCount,
                toolCallCount: toolCallCount,
                errorCount: errorCount,
                subagentCount: subagentCount,
                models: models.values,
                tools: tools.values,
                touchedFiles: touchedFiles.values,
                commands: commands.values
            )
        }
    }

    private struct OrderedSet {
        let limit: Int
        private(set) var values: [String] = []
        private var seen = Set<String>()

        init(limit: Int) { self.limit = limit }

        mutating func insert(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, values.count < limit else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            values.append(trimmed)
        }
    }

    private static let jsonLineExtensions: Set<String> = ["jsonl", "ndjson", "trace"]
    private static let jsonExtensions: Set<String> = ["json", "agent-event"]
    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let databaseExtensions: Set<String> = ["db", "sqlite", "sqlite3", "vscdb"]
    private static let timestampKeys: Set<String> = [
        "timestamp", "time", "createdat", "updatedat", "startedat", "endedat", "completedat", "date",
    ]
    private static let fileKeys: Set<String> = [
        "filepath", "file", "filename", "path", "targetpath", "absolutepath", "relativepath",
    ]
    private static let commandKeys: Set<String> = ["command", "cmd", "shellcommand", "script"]

    private static func normalizedRole(from dictionary: [String: Any]) -> String? {
        let raw = firstString(dictionary, keys: ["role", "speaker", "authorrole", "messagerole"])?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw else { return nil }
        let allowed: Set<String> = ["user", "human", "assistant", "agent", "system", "developer", "tool"]
        return allowed.contains(raw) ? raw : nil
    }

    private static func messageContent(from dictionary: [String: Any]) -> String? {
        for key in ["content", "text", "message", "prompt", "response", "output", "result", "instruction"] {
            guard let value = dictionary[key], let flattened = flattenText(value, depth: 0) else { continue }
            let clean = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    private static func toolName(from dictionary: [String: Any]) -> String? {
        for key in ["toolname", "tool", "functionname", "commandname"] {
            if let value = dictionary[key] as? String, plausibleIdentifier(value) { return value }
            if let value = dictionary[key] as? [String: Any], let name = value["name"] as? String,
                plausibleIdentifier(name)
            {
                return name
            }
        }
        return nil
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func flattenText(_ value: Any, depth: Int) -> String? {
        guard depth <= 4 else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] {
            let pieces = array.compactMap { flattenText($0, depth: depth + 1) }.filter { !$0.isEmpty }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        }
        if let dictionary = value as? [String: Any] {
            for key in ["text", "content", "message", "value"] {
                if let child = dictionary[key], let text = flattenText(child, depth: depth + 1) { return text }
            }
        }
        return nil
    }

    private static func parseDate(_ value: Any) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let string = value as? String else { return nil }
        if let raw = Double(string) {
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = fractional.date(from: string) { return result }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter(\.isLetter)
    }

    private static func plausibleTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= 500 && !plausiblePath(trimmed)
    }

    private static func plausibleIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 240 && !trimmed.contains("\n")
    }

    private static func plausiblePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~") || value.contains("/Users/") || value.contains("\\")
    }

    private static func plausibleFilePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 1_000, !trimmed.contains("\n") else { return false }
        return trimmed.contains("/") || trimmed.contains("\\") || URL(fileURLWithPath: trimmed).pathExtension.count > 0
    }

    private static func plausibleCommand(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 4_000
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : bounded(trimmed, maximum: 300)
    }

    private static func isNullOrEmpty(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let array = value as? [Any] { return array.isEmpty }
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty }
        return false
    }

    private static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(8_192)
        return sample.contains(0)
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        let compact =
            value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maximum else { return compact }
        return String(compact.prefix(maximum - 1)) + "…"
    }

    private static func humanized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
