import Darwin
import Foundation

public enum AgentTranscriptParser {
    /// A single transcript line is intentionally capped. Oversized payload lines are still
    /// hashed by the source reader, but are skipped for transient semantic analysis.
    static let maximumBufferedLineBytes = 512 * 1_024

    public static func parse(data: Data, fileURL: URL, provider: AgentProvider) -> AgentDocumentSummary {
        let ext = fileURL.pathExtension.lowercased()
        if jsonLineExtensions.contains(ext) {
            var parser = IncrementalJSONLines(fileURL: fileURL, provider: provider)
            parser.consume(data)
            return parser.finish()
        }
        if markdownExtensions.contains(ext) || textExtensions.contains(ext) {
            var parser = IncrementalText(
                fileURL: fileURL,
                markdown: markdownExtensions.contains(ext)
            )
            parser.consume(data)
            return parser.finish()
        }
        return parsePayload(data, fileURL: fileURL, provider: provider)
    }

    static func unanalyzedSummary(for fileURL: URL) -> AgentDocumentSummary {
        AgentDocumentSummary(
            format: documentFormat(for: fileURL),
            title: fileURL.deletingPathExtension().lastPathComponent
        )
    }

    static func documentFormat(for fileURL: URL) -> AgentDocumentFormat {
        let ext = fileURL.pathExtension.lowercased()
        if databaseExtensions.contains(ext) { return .database }
        if jsonLineExtensions.contains(ext) { return .jsonLines }
        if jsonExtensions.contains(ext) { return .json }
        if markdownExtensions.contains(ext) { return .markdown }
        if textExtensions.contains(ext) { return .text }
        return .unknown
    }

    /// Incremental JSONL parser shared by regular files and virtual OpenCode rows.
    /// It never retains more than `maximumBufferedLineBytes` of transcript content.
    struct IncrementalJSONLines {
        private static let timestampKeyBytes = Array("\"timestamp\"".utf8)
        private var accumulator: Accumulator
        private let analysisTimestampBounds: (lower: String, upper: String)?
        private let usesCodexDailyProjection: Bool
        private var pendingLine = Data()
        private var discardingOversizedLine = false
        private var parsedAny = false
        private var examinedFirstLine = false
        private var reachedAnalysisEnd = false
        private(set) var peakBufferedBytes = 0

        var hasReachedAnalysisEnd: Bool { reachedAnalysisEnd }

        init(
            fileURL: URL,
            provider: AgentProvider,
            analysisInterval: DateInterval? = nil,
            startsAtSourceBeginning: Bool = true
        ) {
            accumulator = Accumulator(fileURL: fileURL, provider: provider, format: .jsonLines)
            examinedFirstLine = !startsAtSourceBeginning
            if [.codex, .claudeCode].contains(provider), let analysisInterval {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                analysisTimestampBounds = (
                    formatter.string(from: analysisInterval.start),
                    formatter.string(from: analysisInterval.end)
                )
            } else {
                analysisTimestampBounds = nil
            }
            usesCodexDailyProjection = provider == .codex && analysisInterval != nil
        }

        mutating func consume(_ chunk: Data) {
            guard !chunk.isEmpty, !reachedAnalysisEnd else { return }
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                if let newline = chunk[cursor...].firstIndex(of: 0x0A) {
                    append(chunk[cursor..<newline])
                    completeLine()
                    if reachedAnalysisEnd { return }
                    cursor = chunk.index(after: newline)
                } else {
                    append(chunk[cursor..<chunk.endIndex])
                    break
                }
            }
        }

        /// Consumes a borrowed read buffer without first materializing another `Data` value.
        /// The source reader reuses the same fixed-size buffer for the whole file, while this
        /// parser copies only the current bounded line into `pendingLine`.
        mutating func consume(bytes: UnsafeRawBufferPointer) {
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                !bytes.isEmpty,
                !reachedAnalysisEnd
            else { return }
            var fragmentStart = 0
            var searchStart = 0
            while searchStart < bytes.count,
                let match = Darwin.memchr(
                    baseAddress.advanced(by: searchStart),
                    Int32(0x0A),
                    bytes.count - searchStart
                )
            {
                let index = baseAddress.distance(
                    to: match.assumingMemoryBound(to: UInt8.self)
                )
                let lineCount = index - fragmentStart
                if pendingLine.isEmpty, !discardingOversizedLine {
                    consumeLine(
                        bytes: UnsafeRawBufferPointer(
                            start: baseAddress.advanced(by: fragmentStart),
                            count: lineCount
                        )
                    )
                } else {
                    append(bytes: baseAddress.advanced(by: fragmentStart), count: lineCount)
                    completeLine()
                }
                if reachedAnalysisEnd { return }
                fragmentStart = index + 1
                searchStart = fragmentStart
            }
            append(
                bytes: baseAddress.advanced(by: fragmentStart),
                count: bytes.count - fragmentStart
            )
        }

        mutating func consumeLine(_ line: Data) {
            guard line.count <= AgentTranscriptParser.maximumBufferedLineBytes else {
                peakBufferedBytes = max(peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)
                examinedFirstLine = true
                return
            }
            peakBufferedBytes = max(peakBufferedBytes, line.count)
            parseLine(line)
        }

        mutating func consumeLine(bytes: UnsafeRawBufferPointer) {
            guard bytes.count <= AgentTranscriptParser.maximumBufferedLineBytes else {
                peakBufferedBytes = max(peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)
                examinedFirstLine = true
                return
            }
            peakBufferedBytes = max(peakBufferedBytes, bytes.count)
            guard shouldDecodeLine(bytes: bytes) else { return }
            decodeLine(Data(bytes))
        }

        /// OpenCode stores message roles and text parts in separate read-only SQLite rows.
        /// Preserve their opaque relationship only in memory so visible dialogue can be rebuilt
        /// without joining or copying the provider database.
        mutating func consumeOpenCodeRow(
            kind: String,
            identifier: String,
            messageID: String?,
            data: Data
        ) {
            guard data.count <= AgentTranscriptParser.maximumBufferedLineBytes else {
                peakBufferedBytes = max(peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)
                return
            }
            peakBufferedBytes = max(peakBufferedBytes, data.count)
            autoreleasepool {
                guard !data.isEmpty,
                    let object = try? JSONSerialization.jsonObject(with: data)
                else { return }
                parsedAny = true
                accumulator.inspectOpenCodeRow(
                    kind: kind,
                    identifier: identifier,
                    messageID: messageID,
                    object: object
                )
                accumulator.walk(object, currentKey: nil)
            }
        }

        mutating func finish() -> AgentDocumentSummary {
            if !pendingLine.isEmpty || discardingOversizedLine {
                completeLine()
            }
            return parsedAny
                ? accumulator.finish()
                : AgentDocumentSummary(
                    format: .jsonLines,
                    title: accumulator.fileURL.deletingPathExtension().lastPathComponent
                )
        }

        private mutating func append(_ fragment: Data.SubSequence) {
            guard !discardingOversizedLine, !fragment.isEmpty else { return }
            let remaining = AgentTranscriptParser.maximumBufferedLineBytes - pendingLine.count
            guard fragment.count <= remaining else {
                peakBufferedBytes = max(peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)
                pendingLine.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                return
            }
            pendingLine.append(contentsOf: fragment)
            peakBufferedBytes = max(peakBufferedBytes, pendingLine.count)
        }

        private mutating func append(bytes: UnsafePointer<UInt8>, count: Int) {
            guard !discardingOversizedLine, count > 0 else { return }
            let remaining = AgentTranscriptParser.maximumBufferedLineBytes - pendingLine.count
            guard count <= remaining else {
                peakBufferedBytes = max(peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)
                pendingLine.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                return
            }
            pendingLine.append(bytes, count: count)
            peakBufferedBytes = max(peakBufferedBytes, pendingLine.count)
        }

        private mutating func completeLine() {
            defer {
                pendingLine.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
            }
            guard !discardingOversizedLine, !pendingLine.isEmpty else { return }
            if pendingLine.last == 0x0D { pendingLine.removeLast() }
            parseLine(pendingLine)
        }

        private mutating func parseLine(_ line: Data) {
            let shouldDecode = line.withUnsafeBytes { shouldDecodeLine(bytes: $0) }
            guard shouldDecode else { return }
            decodeLine(line)
        }

        private mutating func decodeLine(_ line: Data) {
            autoreleasepool {
                if usesCodexDailyProjection {
                    parsedAny = true
                    line.withUnsafeBytes { bytes in
                        accumulator.inspectCodex(
                            bytes,
                            timestamp: Self.topLevelTimestamp(in: bytes)
                        )
                    }
                    return
                }
                guard !line.isEmpty,
                    let object = try? JSONSerialization.jsonObject(with: line)
                else { return }
                parsedAny = true
                accumulator.walk(object, currentKey: nil)
            }
        }

        /// Codex and Claude JSONL streams are chronological. During a selected-day analysis,
        /// compare their small top-level ISO timestamp before allocating a `Data` line or asking
        /// Foundation to materialize a potentially huge nested JSON object. The first line is
        /// still decoded for stable session metadata, and unknown formats fall back to the full
        /// parser instead of being silently dropped.
        private mutating func shouldDecodeLine(bytes: UnsafeRawBufferPointer) -> Bool {
            guard !reachedAnalysisEnd else { return false }
            if !examinedFirstLine {
                examinedFirstLine = true
                return true
            }
            guard let analysisTimestampBounds,
                let timestamp = Self.topLevelTimestamp(in: bytes)
            else { return true }
            if timestamp < analysisTimestampBounds.lower { return false }
            if timestamp >= analysisTimestampBounds.upper {
                reachedAnalysisEnd = true
                return false
            }
            return true
        }

        static func topLevelTimestamp(in bytes: UnsafeRawBufferPointer) -> String? {
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bytes.count >= 16
            else { return nil }
            let key = Self.timestampKeyBytes
            var keyStart: Int?
            var index = 0
            while index <= bytes.count - key.count {
                var matches = true
                for offset in key.indices where base[index + offset] != key[offset] {
                    matches = false
                    break
                }
                if matches {
                    keyStart = index
                    break
                }
                index += 1
            }
            guard let keyStart else { return nil }
            index = keyStart + key.count
            while index < bytes.count, base[index] == 0x20 || base[index] == 0x09 { index += 1 }
            guard index < bytes.count, base[index] == 0x3A else { return nil }
            index += 1
            while index < bytes.count, base[index] == 0x20 || base[index] == 0x09 { index += 1 }
            guard index < bytes.count, base[index] == 0x22 else { return nil }
            index += 1
            let valueStart = index
            while index < bytes.count, base[index] != 0x22, index - valueStart <= 64 {
                index += 1
            }
            guard index < bytes.count, base[index] == 0x22, index > valueStart else { return nil }
            return String(
                decoding: UnsafeBufferPointer(start: base.advanced(by: valueStart), count: index - valueStart),
                as: UTF8.self
            )
        }
    }

    private static let codexTypeKey = Array("\"type\"".utf8)
    private static let codexRoleKey = Array("\"role\"".utf8)
    private static let codexIDKey = Array("\"id\"".utf8)
    private static let codexSessionIDKey = Array("\"session_id\"".utf8)
    private static let codexModelKey = Array("\"model\"".utf8)
    private static let codexCWDKey = Array("\"cwd\"".utf8)
    private static let codexNameKey = Array("\"name\"".utf8)
    private static let codexSourceKey = Array("\"source\"".utf8)
    private static let codexStatusKey = Array("\"status\"".utf8)
    private static let codexPhaseKey = Array("\"phase\"".utf8)
    private static let codexTextKey = Array("\"text\"".utf8)

    /// Extracts only small JSON string fields. Codex writes compact JSONL with stable top-level
    /// and payload keys; malformed or differently formatted lines simply yield no projected field.
    private static func jsonStringValues(
        forKey key: [UInt8],
        in bytes: UnsafeRawBufferPointer,
        maximumCount: Int = 1
    ) -> [String] {
        guard maximumCount > 0,
            let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
            bytes.count >= key.count + 3
        else { return [] }
        var output: [String] = []
        output.reserveCapacity(maximumCount)
        var searchIndex = 0
        while searchIndex <= bytes.count - key.count, output.count < maximumCount {
            var matched = true
            for offset in key.indices where base[searchIndex + offset] != key[offset] {
                matched = false
                break
            }
            guard matched else {
                searchIndex += 1
                continue
            }
            var index = searchIndex + key.count
            while index < bytes.count, base[index] == 0x20 || base[index] == 0x09 { index += 1 }
            guard index < bytes.count, base[index] == 0x3A else {
                searchIndex += key.count
                continue
            }
            index += 1
            while index < bytes.count, base[index] == 0x20 || base[index] == 0x09 { index += 1 }
            guard index < bytes.count, base[index] == 0x22 else {
                searchIndex += key.count
                continue
            }
            index += 1
            let valueStart = index
            var escaped = false
            while index < bytes.count {
                let byte = base[index]
                if byte == 0x22, !escaped { break }
                if byte == 0x5C {
                    escaped.toggle()
                } else {
                    escaped = false
                }
                index += 1
            }
            guard index < bytes.count else { break }
            output.append(
                String(
                    decoding: UnsafeBufferPointer(
                        start: base.advanced(by: valueStart),
                        count: index - valueStart
                    ),
                    as: UTF8.self
                )
            )
            searchIndex = index + 1
        }
        return output
    }

    private static func decodedJSONString(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        let literal = Data(("\"" + raw + "\"").utf8)
        return (try? JSONDecoder().decode(String.self, from: literal)) ?? raw
    }

    /// Text and Markdown use the same bounded line discipline as JSONL, avoiding a complete
    /// `String` copy for large logs.
    struct IncrementalText {
        private let fileURL: URL
        private let markdown: Bool
        private var pendingLine = Data()
        private var discardingOversizedLine = false
        private var summary: AgentDocumentSummary
        private(set) var peakBufferedBytes = 0

        init(fileURL: URL, markdown: Bool) {
            self.fileURL = fileURL
            self.markdown = markdown
            summary = AgentDocumentSummary(
                format: markdown ? .markdown : .text,
                title: fileURL.deletingPathExtension().lastPathComponent
            )
        }

        mutating func consume(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                if let newline = chunk[cursor...].firstIndex(of: 0x0A) {
                    append(chunk[cursor..<newline])
                    completeLine()
                    cursor = chunk.index(after: newline)
                } else {
                    append(chunk[cursor..<chunk.endIndex])
                    break
                }
            }
        }

        /// Raw-buffer sibling of `consume(_:)`; see `IncrementalJSONLines.consume(bytes:)`.
        mutating func consume(bytes: UnsafeRawBufferPointer) {
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                !bytes.isEmpty
            else { return }
            var fragmentStart = 0
            var searchStart = 0
            while searchStart < bytes.count,
                let match = Darwin.memchr(
                    baseAddress.advanced(by: searchStart),
                    Int32(0x0A),
                    bytes.count - searchStart
                )
            {
                let index = baseAddress.distance(
                    to: match.assumingMemoryBound(to: UInt8.self)
                )
                append(bytes: baseAddress.advanced(by: fragmentStart), count: index - fragmentStart)
                completeLine()
                fragmentStart = index + 1
                searchStart = fragmentStart
            }
            append(
                bytes: baseAddress.advanced(by: fragmentStart),
                count: bytes.count - fragmentStart
            )
        }

        mutating func finish() -> AgentDocumentSummary {
            if !pendingLine.isEmpty || discardingOversizedLine { completeLine() }
            return summary
        }

        private mutating func append(_ fragment: Data.SubSequence) {
            guard !discardingOversizedLine, !fragment.isEmpty else { return }
            let remaining = AgentTranscriptParser.maximumBufferedLineBytes - pendingLine.count
            guard fragment.count <= remaining else {
                peakBufferedBytes = max(peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)
                pendingLine.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                return
            }
            pendingLine.append(contentsOf: fragment)
            peakBufferedBytes = max(peakBufferedBytes, pendingLine.count)
        }

        private mutating func append(bytes: UnsafePointer<UInt8>, count: Int) {
            guard !discardingOversizedLine, count > 0 else { return }
            let remaining = AgentTranscriptParser.maximumBufferedLineBytes - pendingLine.count
            guard count <= remaining else {
                peakBufferedBytes = max(peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)
                pendingLine.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                return
            }
            pendingLine.append(bytes, count: count)
            peakBufferedBytes = max(peakBufferedBytes, pendingLine.count)
        }

        private mutating func completeLine() {
            defer {
                pendingLine.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
            }
            guard !discardingOversizedLine, !pendingLine.isEmpty else { return }
            if pendingLine.last == 0x0D { pendingLine.removeLast() }
            autoreleasepool {
                guard let text = String(data: pendingLine, encoding: .utf8) else { return }
                inspectTextLine(text, summary: &summary)
            }
        }
    }

    private static func parsePayload(
        _ data: Data,
        fileURL: URL,
        provider: AgentProvider
    ) -> AgentDocumentSummary {
        let ext = fileURL.pathExtension.lowercased()
        if databaseExtensions.contains(ext) {
            return AgentDocumentSummary(
                format: .database,
                title: fileURL.deletingPathExtension().lastPathComponent
            )
        }

        if jsonExtensions.contains(ext),
            let object = try? JSONSerialization.jsonObject(with: data)
        {
            var accumulator = Accumulator(fileURL: fileURL, provider: provider, format: .json)
            accumulator.walk(object, currentKey: nil)
            return accumulator.finish()
        }

        if !looksBinary(data), let text = String(data: data, encoding: .utf8) {
            var summary = AgentDocumentSummary(
                format: markdownExtensions.contains(ext) ? .markdown : .text,
                title: fileURL.deletingPathExtension().lastPathComponent
            )
            text.enumerateLines { line, _ in inspectTextLine(line, summary: &summary) }
            return summary
        }

        return AgentDocumentSummary(
            format: looksBinary(data) ? .binary : .unknown,
            title: fileURL.deletingPathExtension().lastPathComponent
        )
    }

    private static func inspectTextLine(_ rawLine: String, summary: inout AgentDocumentSummary) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if summary.excerpt == nil { summary.excerpt = bounded(line, maximum: 360) }
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

    private struct Accumulator {
        let fileURL: URL
        let provider: AgentProvider
        let format: AgentDocumentFormat

        var sessionID: String?
        var title: String?
        var excerpt: String?
        var projectPath: String?
        var earliestDate: Date?
        var latestDate: Date?
        var codexEarliestTimestamp: String?
        var codexLatestTimestamp: String?
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
        var visibleMessages: [AgentVisibleMessage] = []
        var pendingAssistantMessage: (sourceID: String?, text: String)?
        var openCodeRoleByMessageID: [String: AgentVisibleMessage.Role] = [:]
        var lastVisibleSourceID: String?

        mutating func walk(_ value: Any, currentKey: String?) {
            if let dictionary = value as? [String: Any] {
                let orderedKeys = stableDictionaryKeys(dictionary)
                inspect(dictionary, currentKey: currentKey, orderedKeys: orderedKeys)
                let serializedCopilotKey =
                    provider == .copilot
                    ? copilotSerializedStorageKey(from: dictionary)
                    : nil
                for key in orderedKeys {
                    guard let child = dictionary[key] else { continue }
                    let childKey =
                        normalizeKey(key) == "v"
                        ? (serializedCopilotKey ?? key)
                        : key
                    walk(child, currentKey: childKey)
                }
            } else if let array = value as? [Any] {
                for child in array { walk(child, currentKey: currentKey) }
            } else if let string = value as? String {
                inspectLooseString(string, key: currentKey)
            }
        }

        mutating func inspect(
            _ dictionary: [String: Any],
            currentKey: String?,
            orderedKeys: [String]
        ) {
            var normalized: [String: Any] = [:]
            normalized.reserveCapacity(dictionary.count)
            for key in orderedKeys {
                guard let value = dictionary[key] else { continue }
                let normalizedKey = normalizeKey(key)
                guard !normalizedKey.isEmpty, normalized[normalizedKey] == nil else { continue }
                normalized[normalizedKey] = value
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

            var role = normalizedRole(from: normalized)
            if role == nil, provider == .gemini {
                role = geminiRole(from: normalized)
            }
            if role == nil,
                provider == .copilot,
                normalizeKey(currentKey ?? "") == "requests",
                copilotUserInput(from: normalized) != nil
            {
                role = "user"
            }
            if let role {
                messageCount += 1
                switch role {
                case "user", "human": userMessageCount += 1
                case "assistant", "agent": assistantMessageCount += 1
                case "system", "developer": systemMessageCount += 1
                default: break
                }
            }
            if excerpt == nil, let content = messageContent(from: normalized) {
                if role == nil || role == "user" || role == "human", content.count >= 12 {
                    excerpt = bounded(content, maximum: 360)
                }
            }
            if let role,
                let content = visibleMessageContent(from: normalized)
            {
                let phase = firstString(normalized, keys: ["phase"])?.lowercased() ?? ""
                switch role {
                case "user", "human":
                    appendVisibleUser(content, sourceID: nil)
                case "assistant", "agent":
                    if phase != "commentary" {
                        appendVisibleAssistant(
                            content,
                            sourceID: nil,
                            explicitlyFinal: phase == "final_answer"
                        )
                    }
                default:
                    break
                }
            }

            let type =
                firstString(
                    normalized,
                    keys: ["type", "event", "eventname", "hookeventname", "kind"]
                )?.lowercased() ?? ""
            let status =
                firstString(
                    normalized,
                    keys: ["status", "outcome", "resultstatus"]
                )?.lowercased() ?? ""

            var countedTool = false
            if type.contains("tool")
                || type == "function_call"
                || type == "custom_tool_call"
                || normalized["toolname"] != nil
                || normalized["tool"] != nil
            {
                toolCallCount += 1
                countedTool = true
            }
            if let tool = toolName(from: normalized) {
                tools.insert(bounded(tool, maximum: 120))
                if !countedTool { toolCallCount += 1 }
            }

            let source = firstString(normalized, keys: ["source", "sessionsource"])?.lowercased() ?? ""
            if type.contains("subagent")
                || type.contains("sub_agent")
                || source.contains("subagent")
                || source.contains("sub_agent")
            {
                subagentCount += 1
            }
            if type.contains("error") || status == "failed" || status == "failure" || status == "error" {
                errorCount += 1
            } else if let error = normalized["error"], !isNullOrEmpty(error) {
                errorCount += 1
            }

            for key in stableDictionaryKeys(normalized) {
                guard let rawValue = normalized[key] else { continue }
                if timestampKeys.contains(key), let date = parseDate(rawValue) { observe(date) }
                if fileKeys.contains(key), let raw = rawValue as? String, plausibleFilePath(raw) {
                    touchedFiles.insert(bounded(raw, maximum: 500))
                }
                if commandKeys.contains(key),
                    let raw = flattenText(rawValue, depth: 0, maximum: 4_000),
                    plausibleCommand(raw)
                {
                    commands.insert(bounded(raw, maximum: 500))
                }
            }
        }

        mutating func inspectLooseString(_ string: String, key rawKey: String?) {
            guard let key = rawKey.map(normalizeKey) else { return }
            if excerpt == nil,
                ["prompt", "userprompt", "instruction", "request"].contains(key),
                string.count >= 12
            {
                excerpt = bounded(String(string.prefix(1_024)), maximum: 360)
            }
            if timestampKeys.contains(key), let date = parseDate(string) { observe(date) }
        }

        mutating func inspectOpenCodeRow(
            kind: String,
            identifier: String,
            messageID: String?,
            object: Any
        ) {
            guard let dictionary = object as? [String: Any] else { return }
            var normalized: [String: Any] = [:]
            for key in stableDictionaryKeys(dictionary) {
                let normalizedKey = normalizeKey(key)
                guard !normalizedKey.isEmpty, normalized[normalizedKey] == nil else { continue }
                normalized[normalizedKey] = dictionary[key]
            }
            if kind == "message",
                openCodeRoleByMessageID.count < 4_096,
                let role = normalizedRole(from: normalized)
            {
                switch role {
                case "user", "human":
                    openCodeRoleByMessageID[identifier] = .user
                case "assistant", "agent":
                    openCodeRoleByMessageID[identifier] = .assistantFinal
                default:
                    break
                }
                return
            }
            guard kind == "part",
                let relatedMessageID = messageID
                    ?? firstString(normalized, keys: ["messageid", "message"]),
                let role = openCodeRoleByMessageID[relatedMessageID],
                let partType = firstString(normalized, keys: ["type"])?.lowercased(),
                ["text", "input_text", "output_text"].contains(partType),
                let content = visibleMessageContent(from: normalized)
            else { return }
            switch role {
            case .user:
                appendVisibleUser(content, sourceID: relatedMessageID)
            case .assistantFinal:
                appendVisibleAssistant(
                    content,
                    sourceID: relatedMessageID,
                    explicitlyFinal: false
                )
            }
        }

        mutating func appendVisibleUser(_ raw: String, sourceID: String?) {
            guard let text = normalizedVisibleUserText(raw) else { return }
            flushPendingAssistant()
            appendVisible(.user, text: text, sourceID: sourceID)
        }

        mutating func appendVisibleAssistant(
            _ raw: String,
            sourceID: String?,
            explicitlyFinal: Bool
        ) {
            let text = normalizedVisibleAssistantText(raw)
            guard !text.isEmpty else { return }
            if explicitlyFinal {
                pendingAssistantMessage = nil
                appendVisible(.assistantFinal, text: text, sourceID: sourceID)
                return
            }
            if pendingAssistantMessage?.sourceID == sourceID, sourceID != nil {
                let combined = (pendingAssistantMessage?.text ?? "") + "\n" + text
                pendingAssistantMessage = (
                    sourceID,
                    AgentUTF8Bound.string(
                        combined,
                        maximumBytes: AgentDocumentSummary.maximumVisibleMessageBytes
                    )
                )
            } else {
                pendingAssistantMessage = (sourceID, text)
            }
        }

        mutating func flushPendingAssistant() {
            guard let pending = pendingAssistantMessage else { return }
            pendingAssistantMessage = nil
            appendVisible(.assistantFinal, text: pending.text, sourceID: pending.sourceID)
        }

        mutating func appendVisible(
            _ role: AgentVisibleMessage.Role,
            text raw: String,
            sourceID: String?
        ) {
            let text = AgentUTF8Bound.string(
                raw,
                maximumBytes: AgentDocumentSummary.maximumVisibleMessageBytes
            )
            guard !text.isEmpty else { return }
            if let sourceID,
                lastVisibleSourceID == sourceID,
                visibleMessages.last?.role == role
            {
                let combined = (visibleMessages.last?.text ?? "") + "\n" + text
                visibleMessages[visibleMessages.count - 1].text = AgentUTF8Bound.string(
                    combined,
                    maximumBytes: AgentDocumentSummary.maximumVisibleMessageBytes
                )
                return
            }
            visibleMessages.append(AgentVisibleMessage(role: role, text: text))
            lastVisibleSourceID = sourceID
            while visibleMessages.count > AgentDocumentSummary.maximumVisibleMessageCount
                || visibleMessages.reduce(0, { $0 + $1.text.utf8.count })
                    > AgentDocumentSummary.maximumVisibleConversationBytes
            {
                let removalIndex = visibleMessages.count > 2 ? visibleMessages.count / 2 : 0
                visibleMessages.remove(at: removalIndex)
                if removalIndex == visibleMessages.count { lastVisibleSourceID = nil }
            }
        }

        mutating func inspectCodex(
            _ bytes: UnsafeRawBufferPointer,
            timestamp: String?
        ) {
            if let timestamp {
                if codexEarliestTimestamp.map({ timestamp < $0 }) ?? true {
                    codexEarliestTimestamp = timestamp
                }
                if codexLatestTimestamp.map({ timestamp > $0 }) ?? true {
                    codexLatestTimestamp = timestamp
                }
            }
            let eventType = jsonStringValues(forKey: codexTypeKey, in: bytes)
                .first?.lowercased() ?? ""
            let payloadType: String
            if eventType == "response_item" || eventType == "event_msg" {
                payloadType = jsonStringValues(
                    forKey: codexTypeKey,
                    in: bytes,
                    maximumCount: 2
                ).dropFirst().first?.lowercased() ?? ""
            } else {
                payloadType = ""
            }
            if sessionID == nil, eventType == "session_meta" {
                let value = jsonStringValues(forKey: codexSessionIDKey, in: bytes).first
                    ?? jsonStringValues(forKey: codexIDKey, in: bytes).first
                    ?? ""
                sessionID = nonEmpty(value)
            }
            if projectPath == nil, eventType == "session_meta",
                let cwd = jsonStringValues(forKey: codexCWDKey, in: bytes).first,
                plausiblePath(cwd)
            {
                projectPath = bounded(cwd, maximum: 500)
            }
            if (eventType == "turn_context" || eventType == "session_meta"),
                let model = jsonStringValues(forKey: codexModelKey, in: bytes).first,
                plausibleIdentifier(model)
            {
                models.insert(bounded(model, maximum: 120))
            }

            let role = payloadType == "message"
                ? jsonStringValues(forKey: codexRoleKey, in: bytes).first?.lowercased() ?? ""
                : ""
            if payloadType == "message",
                ["user", "human", "assistant", "agent", "system", "developer"].contains(role)
            {
                messageCount += 1
                switch role {
                case "user", "human": userMessageCount += 1
                case "assistant", "agent": assistantMessageCount += 1
                case "system", "developer": systemMessageCount += 1
                default: break
                }
            }
            let visibleText = payloadType == "message"
                ? jsonStringValues(
                    forKey: codexTextKey,
                    in: bytes,
                    maximumCount: 8
                )
                .map(decodedJSONString)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            if excerpt == nil,
                (role == "user" || role == "human"),
                !visibleText.isEmpty
            {
                if visibleText.count >= 12 {
                    excerpt = bounded(visibleText, maximum: 360)
                }
            }
            if !visibleText.isEmpty {
                switch role {
                case "user", "human":
                    appendVisibleUser(visibleText, sourceID: nil)
                case "assistant", "agent":
                    let phase = jsonStringValues(forKey: codexPhaseKey, in: bytes)
                        .first?.lowercased() ?? ""
                    if phase != "commentary" {
                        appendVisibleAssistant(
                            visibleText,
                            sourceID: nil,
                            explicitlyFinal: phase == "final_answer"
                        )
                    }
                default:
                    break
                }
            }

            if payloadType == "function_call" || payloadType == "custom_tool_call" {
                toolCallCount += 1
                if let name = jsonStringValues(forKey: codexNameKey, in: bytes).first,
                    plausibleIdentifier(name)
                {
                    tools.insert(bounded(name, maximum: 120))
                }
            }
            let status = eventType == "event_msg"
                ? jsonStringValues(forKey: codexStatusKey, in: bytes).first?.lowercased() ?? ""
                : ""
            if payloadType.contains("error") || eventType.contains("error")
                || payloadType == "turn_aborted" || status == "failed" || status == "failure"
            {
                errorCount += 1
            }
            let source = eventType == "session_meta"
                ? jsonStringValues(forKey: codexSourceKey, in: bytes).first?.lowercased() ?? ""
                : ""
            if payloadType.contains("subagent") || payloadType.contains("sub_agent")
                || source.contains("subagent") || source.contains("sub_agent")
            {
                subagentCount += 1
            }
        }

        mutating func observe(_ date: Date) {
            if earliestDate.map({ date < $0 }) ?? true { earliestDate = date }
            if latestDate.map({ date > $0 }) ?? true { latestDate = date }
        }

        mutating func finish() -> AgentDocumentSummary {
            flushPendingAssistant()
            return AgentDocumentSummary(
                format: format,
                sessionID: sessionID,
                title: title ?? fileURL.deletingPathExtension().lastPathComponent,
                excerpt: excerpt,
                projectPath: projectPath,
                startedAt: earliestDate ?? codexEarliestTimestamp.flatMap(parseDate),
                endedAt: latestDate ?? codexLatestTimestamp.flatMap(parseDate),
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
                commands: commands.values,
                visibleMessages: visibleMessages
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
    private static let textExtensions: Set<String> = ["txt", "log"]
    private static let databaseExtensions: Set<String> = ["db", "sqlite", "sqlite3", "vscdb"]
    private static let timestampKeys: Set<String> = [
        "timestamp", "time", "createdat", "updatedat", "startedat", "endedat", "completedat", "date",
    ]
    private static let fileKeys: Set<String> = [
        "filepath", "file", "filename", "path", "targetpath", "absolutepath", "relativepath",
    ]
    private static let commandKeys: Set<String> = ["command", "cmd", "shellcommand", "script"]

    private static let iso8601Lock = NSLock()
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standardISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func normalizedRole(from dictionary: [String: Any]) -> String? {
        let raw = firstString(dictionary, keys: ["role", "speaker", "authorrole", "messagerole"])?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw else { return nil }
        let allowed: Set<String> = ["user", "human", "assistant", "agent", "system", "developer", "tool"]
        return allowed.contains(raw) ? raw : nil
    }

    private static func geminiRole(from dictionary: [String: Any]) -> String? {
        let raw = firstString(dictionary, keys: ["type"])?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw {
        case "user", "human": return "user"
        case "gemini", "model", "assistant", "agent": return "assistant"
        case "system", "developer": return raw
        default: return nil
        }
    }

    private static func copilotUserInput(from dictionary: [String: Any]) -> String? {
        for key in ["message", "userinput", "inputtext", "input", "prompt"] {
            guard let value = dictionary[key],
                let text = flattenText(value, depth: 0, maximum: 1_024),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return text
        }
        return nil
    }

    /// Current VS Code chat sessions can serialize top-level properties as JSONL key/value
    /// records (`{"k":["requests"],"v":[...]}`). Preserve that key while walking `v` so
    /// request dictionaries are interpreted the same way as the equivalent JSON document.
    private static func copilotSerializedStorageKey(from dictionary: [String: Any]) -> String? {
        guard let path = dictionary["k"] as? [Any],
            let last = path.last as? String,
            !last.isEmpty
        else { return nil }
        return last
    }

    private static func messageContent(from dictionary: [String: Any]) -> String? {
        for key in ["content", "text", "message", "prompt", "response", "output", "result", "instruction"] {
            guard let value = dictionary[key],
                let flattened = flattenText(value, depth: 0, maximum: 1_024)
            else { continue }
            let clean = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    /// Extracts only text that was visible as a user message or assistant reply. Structured
    /// thinking, tool-use, tool-result, image, and other provider blocks are intentionally absent.
    private static func visibleMessageContent(from dictionary: [String: Any]) -> String? {
        for key in ["content", "text", "message", "prompt", "response", "output"] {
            guard let value = dictionary[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            guard let blocks = value as? [Any] else { continue }
            var texts: [String] = []
            for block in blocks {
                guard let dictionary = block as? [String: Any] else { continue }
                let type = (dictionary["type"] as? String)?.lowercased() ?? ""
                guard ["text", "input_text", "output_text"].contains(type),
                    let text = dictionary["text"] as? String
                else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts.append(trimmed) }
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    private static func normalizedVisibleUserText(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
            !text.hasPrefix("<summary>"),
            !text.hasPrefix("# AGENTS.md instructions")
        else { return nil }
        if text.hasPrefix("<codex_delegation>"),
            let input = content(ofTag: "input", in: text)
        {
            text = input
        }
        for tag in ["in-app-browser-context", "environment_context", "app-context"] {
            text = removingTaggedBlocks(tag, from: text)
        }
        if let marker = text.range(of: "## My request:", options: .backwards) {
            text = String(text[marker.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return AgentUTF8Bound.string(
            text,
            maximumBytes: AgentDocumentSummary.maximumVisibleMessageBytes
        )
    }

    private static func normalizedVisibleAssistantText(_ raw: String) -> String {
        let withoutMemoryReceipt = removingTaggedBlocks("oai-mem-citation", from: raw)
        return AgentUTF8Bound.string(
            withoutMemoryReceipt.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumBytes: AgentDocumentSummary.maximumVisibleMessageBytes
        )
    }

    private static func content(ofTag tag: String, in text: String) -> String? {
        guard let opening = text.range(of: "<\(tag)>", options: [.caseInsensitive]),
            let closing = text.range(
                of: "</\(tag)>",
                options: [.caseInsensitive],
                range: opening.upperBound..<text.endIndex
            )
        else { return nil }
        return String(text[opening.upperBound..<closing.lowerBound])
    }

    private static func removingTaggedBlocks(_ tag: String, from raw: String) -> String {
        var text = raw
        while let openingStart = text.range(of: "<\(tag)", options: [.caseInsensitive])?.lowerBound,
            let openingEnd = text[openingStart...].firstIndex(of: ">"),
            let closing = text.range(
                of: "</\(tag)>",
                options: [.caseInsensitive],
                range: text.index(after: openingEnd)..<text.endIndex
            )
        {
            text.removeSubrange(openingStart..<closing.upperBound)
        }
        return text
    }

    private static func toolName(from dictionary: [String: Any]) -> String? {
        for key in ["toolname", "tool", "functionname", "commandname"] {
            if let value = dictionary[key] as? String, plausibleIdentifier(value) { return value }
            if let value = dictionary[key] as? [String: Any],
                let name = value["name"] as? String,
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

    private static func flattenText(_ value: Any, depth: Int, maximum: Int) -> String? {
        guard depth <= 4, maximum > 0 else { return nil }
        if let string = value as? String { return String(string.prefix(maximum)) }
        if let number = value as? NSNumber { return String(number.stringValue.prefix(maximum)) }
        if let array = value as? [Any] {
            var output = ""
            for child in array where output.count < maximum {
                guard
                    let text = flattenText(
                        child,
                        depth: depth + 1,
                        maximum: maximum - output.count
                    ), !text.isEmpty
                else { continue }
                if !output.isEmpty, output.count < maximum { output.append("\n") }
                output.append(contentsOf: text.prefix(maximum - output.count))
            }
            return output.isEmpty ? nil : output
        }
        if let dictionary = value as? [String: Any] {
            for key in ["text", "content", "message", "value"] {
                if let child = dictionary[key],
                    let text = flattenText(child, depth: depth + 1, maximum: maximum)
                {
                    return text
                }
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
        iso8601Lock.lock()
        defer { iso8601Lock.unlock() }
        return fractionalISO8601.date(from: string) ?? standardISO8601.date(from: string)
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter(\.isLetter)
    }

    /// Foundation dictionaries deliberately do not promise iteration order. Canonicalize by
    /// normalized key first, then by the original UTF-8 bytes so normalization collisions and
    /// first-observed fields have one stable winner on every process and platform.
    private static func stableDictionaryKeys(_ dictionary: [String: Any]) -> [String] {
        dictionary.keys.sorted { lhs, rhs in
            let normalizedLHS = normalizeKey(lhs)
            let normalizedRHS = normalizeKey(rhs)
            if normalizedLHS != normalizedRHS {
                return normalizedLHS.utf8.lexicographicallyPrecedes(normalizedRHS.utf8)
            }
            return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
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
        return trimmed.contains("/") || trimmed.contains("\\")
            || URL(fileURLWithPath: trimmed).pathExtension.count > 0
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
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] { return array.isEmpty }
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty }
        return false
    }

    private static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data.prefix(8_192).contains(0)
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        let compact =
            value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maximum else { return compact }
        return String(compact.prefix(maximum - 1)) + "…"
    }
}
