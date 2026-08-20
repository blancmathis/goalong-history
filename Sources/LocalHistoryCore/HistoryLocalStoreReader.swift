import Foundation

public struct HistoryLoadIssue: Codable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let line: Int?
    public let message: String

    public init(path: String, line: Int?, message: String) {
        self.id = "\(path):\(line.map(String.init) ?? "-"):\(message)"
        self.path = path
        self.line = line
        self.message = message
    }
}

public struct HistoryLoadedData {
    public let events: [HistoryEvent]
    public let memories: [ActivityMemory]
    public let semanticSnapshots: [String: SemanticContextPayload]
    public let captureHealth: CaptureHealthSnapshot?
    public let issues: [HistoryLoadIssue]

    public init(
        events: [HistoryEvent],
        memories: [ActivityMemory],
        semanticSnapshots: [String: SemanticContextPayload],
        captureHealth: CaptureHealthSnapshot?,
        issues: [HistoryLoadIssue]
    ) {
        self.events = events
        self.memories = memories
        self.semanticSnapshots = semanticSnapshots
        self.captureHealth = captureHealth
        self.issues = issues
    }
}

/// Stable, read-only filesystem adapter for ChatGPT, Codex and a future MCP server.
/// It never asks for Accessibility/Input Monitoring and never mutates recorder files.
public struct HistoryLocalStoreReader {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public var eventsDirectory: URL {
        rootDirectory.appendingPathComponent("events", isDirectory: true)
    }

    public var memoriesDirectory: URL {
        rootDirectory.appendingPathComponent("memories", isDirectory: true)
    }

    public var analysisDirectory: URL {
        rootDirectory.appendingPathComponent("analysis", isDirectory: true)
    }

    public var semanticDirectory: URL {
        rootDirectory.appendingPathComponent("semantic", isDirectory: true)
    }

    public var captureHealthFile: URL {
        rootDirectory.appendingPathComponent("capture-health.json")
    }

    public func load(
        start: Date? = nil,
        end: Date? = nil
    ) -> HistoryLoadedData {
        var issues: [HistoryLoadIssue] = []
        let events = loadJSONLines(
            HistoryEvent.self,
            from: files(in: eventsDirectory, extensions: ["jsonl"]),
            start: start,
            end: end,
            timestamp: { $0.timestamp },
            issues: &issues
        )
        let memories = loadJSONFiles(
            ActivityMemory.self,
            from: files(in: memoriesDirectory, extensions: ["json"])
                + files(in: analysisDirectory, extensions: ["memory.json"]),
            issues: &issues
        )
        let semanticRows = loadJSONLines(
            SemanticContextPayload.self,
            from: files(in: semanticDirectory, extensions: ["jsonl"]),
            start: start,
            end: end,
            timestamp: { $0.capturedAt },
            issues: &issues
        ) + loadJSONFiles(
            SemanticContextPayload.self,
            from: files(in: semanticDirectory, extensions: ["json"]),
            issues: &issues
        ).filter { payload in
            if let start, payload.capturedAt < start { return false }
            if let end, payload.capturedAt > end { return false }
            return true
        }

        var semantic: [String: SemanticContextPayload] = [:]
        for row in semanticRows.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            semantic[row.id] = row
        }

        let health: CaptureHealthSnapshot? = {
            guard FileManager.default.fileExists(atPath: captureHealthFile.path) else { return nil }
            do {
                return try decoder().decode(CaptureHealthSnapshot.self, from: Data(contentsOf: captureHealthFile))
            } catch {
                issues.append(
                    HistoryLoadIssue(
                        path: captureHealthFile.path,
                        line: nil,
                        message: "Could not decode capture health: \(error)"
                    )
                )
                return nil
            }
        }()

        return HistoryLoadedData(
            events: events.sorted { $0.timestamp < $1.timestamp },
            memories: memories.sorted { $0.start < $1.start },
            semanticSnapshots: semantic,
            captureHealth: health,
            issues: issues
        )
    }

    private func files(in directory: URL, extensions: Set<String>) -> [URL] {
        guard let rows = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return rows.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            let name = url.lastPathComponent.lowercased()
            return extensions.contains(where: { suffix in name.hasSuffix(".\(suffix)") })
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadJSONLines<T: Decodable>(
        _ type: T.Type,
        from files: [URL],
        start: Date?,
        end: Date?,
        timestamp: (T) -> Date,
        issues: inout [HistoryLoadIssue]
    ) -> [T] {
        var result: [T] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                let text = String(data: data, encoding: .utf8)
            else {
                issues.append(HistoryLoadIssue(path: file.path, line: nil, message: "Could not read UTF-8 JSONL"))
                continue
            }
            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                do {
                    let value = try decoder().decode(T.self, from: Data(rawLine.utf8))
                    let date = timestamp(value)
                    if let start, date < start { continue }
                    if let end, date > end { continue }
                    result.append(value)
                } catch {
                    issues.append(
                        HistoryLoadIssue(
                            path: file.path,
                            line: index + 1,
                            message: "Could not decode JSONL row: \(error)"
                        )
                    )
                }
            }
        }
        return result
    }

    private func loadJSONFiles<T: Decodable>(
        _ type: T.Type,
        from files: [URL],
        issues: inout [HistoryLoadIssue]
    ) -> [T] {
        files.compactMap { file in
            do {
                return try decoder().decode(T.self, from: Data(contentsOf: file))
            } catch {
                issues.append(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message: "Could not decode JSON file: \(error)"
                    )
                )
                return nil
            }
        }
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.fractionalISO.date(from: raw) ?? Self.basicISO.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(raw)"
            )
        }
        return decoder
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
