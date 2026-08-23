import Foundation

public struct HistoryEventDeletionResult: Equatable {
    public let deletedEventCount: Int
    public let deletedEventIDs: [String]
    public let referencedSemanticSnapshotIDs: [String]
    public let affectedDays: [Date]
    public let removedFilePaths: [String]

    public init(
        deletedEventCount: Int,
        deletedEventIDs: [String],
        referencedSemanticSnapshotIDs: [String],
        affectedDays: [Date],
        removedFilePaths: [String]
    ) {
        self.deletedEventCount = deletedEventCount
        self.deletedEventIDs = deletedEventIDs
        self.referencedSemanticSnapshotIDs = referencedSemanticSnapshotIDs
        self.affectedDays = affectedDays
        self.removedFilePaths = removedFilePaths
    }

    public static let empty = HistoryEventDeletionResult(
        deletedEventCount: 0,
        deletedEventIDs: [],
        referencedSemanticSnapshotIDs: [],
        affectedDays: [],
        removedFilePaths: []
    )
}

public struct HistorySemanticDeletionResult: Equatable {
    public let deletedSnapshotCount: Int
    public let deletedSnapshotIDs: [String]
    public let affectedDays: [Date]
    public let removedFilePaths: [String]

    public init(
        deletedSnapshotCount: Int,
        deletedSnapshotIDs: [String],
        affectedDays: [Date],
        removedFilePaths: [String]
    ) {
        self.deletedSnapshotCount = deletedSnapshotCount
        self.deletedSnapshotIDs = deletedSnapshotIDs
        self.affectedDays = affectedDays
        self.removedFilePaths = removedFilePaths
    }

    public static let empty = HistorySemanticDeletionResult(
        deletedSnapshotCount: 0,
        deletedSnapshotIDs: [],
        affectedDays: [],
        removedFilePaths: []
    )
}

public enum HistoryDeletionExecutionError: Error, Equatable, CustomStringConvertible {
    case invalidInterval
    case missingTimelineEntryID
    case timelineEntryNotFound(String)
    case undecodableEvent(path: String, line: Int)
    case undecodableSemanticSnapshot(path: String, line: Int)

    public var description: String {
        switch self {
        case .invalidInterval:
            return "The deletion request requires a valid start and end date."
        case .missingTimelineEntryID:
            return "The deletion request requires a timeline entry identifier."
        case .timelineEntryNotFound(let identifier):
            return "No detailed event matched timeline entry \(identifier)."
        case .undecodableEvent(let path, let line):
            return "Refusing a partial deletion because \(path):\(line) is not a decodable history event."
        case .undecodableSemanticSnapshot(let path, let line):
            return "Refusing a partial deletion because \(path):\(line) is not a decodable semantic snapshot."
        }
    }
}

/// Deterministic deletion over the local JSONL stores. Partial deletions fail instead
/// of silently retaining undecodable rows whose timestamp or interaction membership
/// cannot be proven. Whole-store deletion may remove undecodable rows because every
/// detailed item is explicitly in scope.
public enum HistoryJSONLDeletionEngine {
    public static func deleteEvents(
        in directory: URL,
        request: HistoryDeletionRequest,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) throws -> HistoryEventDeletionResult {
        let files = try JSONLFiles.inDirectory(directory, fileManager: fileManager)
        guard !files.isEmpty else { return .empty }

        if request.scope == .allDetailedData
            || request.scope == .allLocalHistoryIncludingProofs
        {
            var deletedIDs: [String] = []
            var semanticIDs: [String] = []
            var affectedDays: [Date] = []
            var deletedCount = 0
            for file in files {
                let data = try Data(contentsOf: file)
                for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    deletedCount += 1
                    if let event = try? eventDecoder.decode(HistoryEvent.self, from: Data(rawLine)) {
                        deletedIDs.append(event.id)
                        if let snapshotID = event.semanticContext?.snapshotID {
                            semanticIDs.append(snapshotID)
                        }
                        affectedDays.append(calendar.startOfDay(for: event.timestamp))
                    }
                }
                if let day = JSONLFiles.dayFromFilename(file.lastPathComponent, calendar: calendar) {
                    affectedDays.append(day)
                }
            }
            for file in files {
                try fileManager.removeItem(at: file)
            }
            return HistoryEventDeletionResult(
                deletedEventCount: deletedCount,
                deletedEventIDs: distinct(deletedIDs).sorted(),
                referencedSemanticSnapshotIDs: distinct(semanticIDs).sorted(),
                affectedDays: distinctDates(affectedDays).sorted(),
                removedFilePaths: files.map(\.path).sorted()
            )
        }

        guard request.scope == .timelineEntry
            || request.scope == .interval
            || request.scope == .day
        else {
            return .empty
        }

        let interval = try deletionInterval(for: request)
        let timelineID: String?
        if request.scope == .timelineEntry {
            guard let value = request.timelineEntryID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { throw HistoryDeletionExecutionError.missingTimelineEntryID }
            timelineID = value
        } else {
            timelineID = nil
        }

        struct Row {
            let data: Data
            let event: HistoryEvent
        }
        struct FileRows {
            let URL: URL
            let rows: [Row]
        }

        var decodedFiles: [FileRows] = []
        var seedEventIDs = Set<String>()
        var linkedInteractionIDs = Set<String>()
        for file in files {
            let data = try Data(contentsOf: file)
            var rows: [Row] = []
            for (index, rawLine) in data.split(
                separator: 0x0A,
                omittingEmptySubsequences: true
            ).enumerated() {
                let line = Data(rawLine)
                guard let event = try? eventDecoder.decode(HistoryEvent.self, from: line) else {
                    throw HistoryDeletionExecutionError.undecodableEvent(
                        path: file.path,
                        line: index + 1
                    )
                }
                rows.append(Row(data: line, event: event))
                let isSeed: Bool
                if let timelineID {
                    isSeed = event.id == timelineID
                } else if let interval {
                    isSeed = event.timestamp >= interval.start
                        && event.timestamp <= interval.end
                } else {
                    isSeed = false
                }
                if isSeed {
                    seedEventIDs.insert(event.id)
                    if let interactionID = event.metadata?[ComputerHistoryMetadata.interactionID],
                        !interactionID.isEmpty
                    {
                        linkedInteractionIDs.insert(interactionID)
                    }
                }
            }
            decodedFiles.append(FileRows(URL: file, rows: rows))
        }

        if let timelineID, seedEventIDs.isEmpty {
            throw HistoryDeletionExecutionError.timelineEntryNotFound(timelineID)
        }
        guard !seedEventIDs.isEmpty else { return .empty }

        var deletedIDs: [String] = []
        var semanticIDs: [String] = []
        var affectedDays: [Date] = []
        var removedFiles: [String] = []

        for fileRows in decodedFiles {
            var kept: [Data] = []
            for row in fileRows.rows {
                let interactionID = row.event.metadata?[ComputerHistoryMetadata.interactionID]
                let shouldDelete = seedEventIDs.contains(row.event.id)
                    || interactionID.map(linkedInteractionIDs.contains) == true
                if shouldDelete {
                    deletedIDs.append(row.event.id)
                    if let snapshotID = row.event.semanticContext?.snapshotID {
                        semanticIDs.append(snapshotID)
                    }
                    affectedDays.append(calendar.startOfDay(for: row.event.timestamp))
                } else {
                    kept.append(row.data)
                }
            }

            guard kept.count != fileRows.rows.count else { continue }
            if kept.isEmpty {
                try fileManager.removeItem(at: fileRows.URL)
                removedFiles.append(fileRows.URL.path)
            } else {
                try JSONLFiles.write(lines: kept, to: fileRows.URL, fileManager: fileManager)
            }
        }

        return HistoryEventDeletionResult(
            deletedEventCount: deletedIDs.count,
            deletedEventIDs: distinct(deletedIDs).sorted(),
            referencedSemanticSnapshotIDs: distinct(semanticIDs).sorted(),
            affectedDays: distinctDates(affectedDays).sorted(),
            removedFilePaths: removedFiles.sorted()
        )
    }

    public static func deleteSemanticSnapshots(
        in directory: URL,
        request: HistoryDeletionRequest,
        additionallyDeleting snapshotIDs: [String] = [],
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) throws -> HistorySemanticDeletionResult {
        let files = try JSONLFiles.inDirectory(directory, fileManager: fileManager)
        guard !files.isEmpty else { return .empty }

        if request.scope == .allDetailedData
            || request.scope == .allLocalHistoryIncludingProofs
        {
            var deletedIDs: [String] = []
            var affectedDays: [Date] = []
            var deletedCount = 0
            for file in files {
                let data = try Data(contentsOf: file)
                for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    deletedCount += 1
                    if let payload = try? semanticDecoder.decode(
                        SemanticContextPayload.self,
                        from: Data(rawLine)
                    ) {
                        deletedIDs.append(payload.id)
                        affectedDays.append(calendar.startOfDay(for: payload.capturedAt))
                    }
                }
                if let day = JSONLFiles.dayFromFilename(file.lastPathComponent, calendar: calendar) {
                    affectedDays.append(day)
                }
            }
            for file in files {
                try fileManager.removeItem(at: file)
            }
            return HistorySemanticDeletionResult(
                deletedSnapshotCount: deletedCount,
                deletedSnapshotIDs: distinct(deletedIDs).sorted(),
                affectedDays: distinctDates(affectedDays).sorted(),
                removedFilePaths: files.map(\.path).sorted()
            )
        }

        guard request.scope == .timelineEntry
            || request.scope == .interval
            || request.scope == .day
        else {
            return .empty
        }

        let interval = try deletionInterval(for: request)
        let explicitIDs = Set(snapshotIDs)
        var deletedIDs: [String] = []
        var affectedDays: [Date] = []
        var removedFiles: [String] = []

        for file in files {
            let data = try Data(contentsOf: file)
            var kept: [Data] = []
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for (index, rawLine) in lines.enumerated() {
                let line = Data(rawLine)
                guard let payload = try? semanticDecoder.decode(
                    SemanticContextPayload.self,
                    from: line
                ) else {
                    throw HistoryDeletionExecutionError.undecodableSemanticSnapshot(
                        path: file.path,
                        line: index + 1
                    )
                }
                let inInterval = interval.map {
                    payload.capturedAt >= $0.start && payload.capturedAt <= $0.end
                } ?? false
                if explicitIDs.contains(payload.id) || inInterval {
                    deletedIDs.append(payload.id)
                    affectedDays.append(calendar.startOfDay(for: payload.capturedAt))
                } else {
                    kept.append(line)
                }
            }

            guard kept.count != lines.count else { continue }
            if kept.isEmpty {
                try fileManager.removeItem(at: file)
                removedFiles.append(file.path)
            } else {
                try JSONLFiles.write(lines: kept, to: file, fileManager: fileManager)
            }
        }

        return HistorySemanticDeletionResult(
            deletedSnapshotCount: deletedIDs.count,
            deletedSnapshotIDs: distinct(deletedIDs).sorted(),
            affectedDays: distinctDates(affectedDays).sorted(),
            removedFilePaths: removedFiles.sorted()
        )
    }

    private static func deletionInterval(
        for request: HistoryDeletionRequest
    ) throws -> (start: Date, end: Date)? {
        guard request.scope == .interval || request.scope == .day else { return nil }
        guard let rawStart = request.start, let rawEnd = request.end else {
            throw HistoryDeletionExecutionError.invalidInterval
        }
        return rawStart <= rawEnd
            ? (rawStart, rawEnd)
            : (rawEnd, rawStart)
    }

    private static let eventDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let semanticDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func distinctDates(_ values: [Date]) -> [Date] {
        distinct(values)
    }
}

private enum JSONLFiles {
    static func inDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func write(
        lines: [Data],
        to URL: URL,
        fileManager: FileManager
    ) throws {
        var output = Data()
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }
        try output.write(to: URL, options: [.atomic])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: URL.path
        )
    }

    static func dayFromFilename(
        _ filename: String,
        calendar: Calendar
    ) -> Date? {
        guard let match = filename.range(
            of: #"^\d{4}-\d{2}-\d{2}"#,
            options: .regularExpression
        ) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(filename[match])).map {
            calendar.startOfDay(for: $0)
        }
    }
}
