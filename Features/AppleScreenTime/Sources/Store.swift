import Foundation

public enum AppleScreenTimeStoreError: Error, CustomStringConvertible {
    case noImportForInterval
    case invalidFile

    public var description: String {
        switch self {
        case .noImportForInterval:
            return "No Apple Screen Time import covers the selected interval."
        case .invalidFile:
            return "The selected file is not a valid Apple Screen Time export."
        }
    }
}

public enum AppleScreenTimeJSON {
    public static func encoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacyFormatter = ISO8601DateFormatter()
        legacyFormatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = fractionalFormatter.date(from: value) ?? legacyFormatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date."
                )
            }
            return date
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, prettyPrinted: Bool = true) throws -> Data {
        try encoder(prettyPrinted: prettyPrinted).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}

public final class AppleScreenTimeStore {
    public let rootDirectory: URL
    public let snapshotsDirectory: URL
    public let configurationFile: URL

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "ai.goalong.apple-screen-time.store")

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.rootDirectory = rootDirectory
        self.snapshotsDirectory = rootDirectory.appendingPathComponent("imports", isDirectory: true)
        self.configurationFile = rootDirectory.appendingPathComponent("configuration.json", isDirectory: false)
        self.fileManager = fileManager
        try prepareDirectories()
    }

    public func loadConfiguration() -> AppleScreenTimeConfiguration {
        queue.sync {
            guard let data = try? Data(contentsOf: configurationFile),
                let value = try? AppleScreenTimeJSON.decode(AppleScreenTimeConfiguration.self, from: data)
            else {
                return .default
            }
            return value
        }
    }

    public func saveConfiguration(_ configuration: AppleScreenTimeConfiguration) throws {
        try queue.sync {
            let data = try AppleScreenTimeJSON.encode(configuration)
            try writePrivate(data, to: configurationFile)
        }
    }

    @discardableResult
    public func importExport(from sourceURL: URL) throws -> AppleScreenTimeStoredExport {
        let data = try Data(contentsOf: sourceURL)
        return try importExport(data: data)
    }

    @discardableResult
    public func importExport(data: Data) throws -> AppleScreenTimeStoredExport {
        let envelope: AppleScreenTimeExportEnvelope
        do {
            envelope = try AppleScreenTimeJSON.decode(AppleScreenTimeExportEnvelope.self, from: data)
        } catch {
            throw AppleScreenTimeStoreError.invalidFile
        }
        let verification: AppleScreenTimeImportVerification =
            envelope.provenance.signature == nil ? .unsigned : .signaturePresentUnverified
        return try importEnvelope(envelope, verification: verification)
    }

    @discardableResult
    public func importEnvelope(
        _ envelope: AppleScreenTimeExportEnvelope,
        verification: AppleScreenTimeImportVerification
    ) throws -> AppleScreenTimeStoredExport {
        try AppleScreenTimeValidator.validate(envelope)
        let stored = AppleScreenTimeStoredExport(verification: verification, envelope: envelope)
        try queue.sync {
            let data = try AppleScreenTimeJSON.encode(stored)
            let timestamp = Self.fileTimestamp(stored.importedAt)
            let filename = "\(timestamp)-\(UUID().uuidString.lowercased()).json"
            try writePrivate(data, to: snapshotsDirectory.appendingPathComponent(filename))
        }
        return stored
    }

    public func storedExports() -> [AppleScreenTimeStoredExport] {
        queue.sync {
            guard
                let files = try? fileManager.contentsOfDirectory(
                    at: snapshotsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { return [] }

            return
                files
                .filter { $0.pathExtension.lowercased() == "json" }
                .compactMap { file -> AppleScreenTimeStoredExport? in
                    guard let data = try? Data(contentsOf: file),
                        let stored = try? AppleScreenTimeJSON.decode(AppleScreenTimeStoredExport.self, from: data),
                        (try? AppleScreenTimeValidator.validate(stored.envelope)) != nil
                    else { return nil }
                    return stored
                }
                .sorted { $0.importedAt > $1.importedAt }
        }
    }

    public func newestExport(overlapping interval: DateInterval) -> AppleScreenTimeStoredExport? {
        storedExports().first { stored in
            let exportInterval = DateInterval(
                start: stored.envelope.requestedStart,
                end: stored.envelope.requestedEnd
            )
            return exportInterval.intersects(interval)
        }
    }

    public func summary(
        for day: Date,
        scope: AppleScreenTimeScope,
        calendar: Calendar = .current
    ) -> AppleScreenTimeDaySummary? {
        guard let interval = calendar.dateInterval(of: .day, for: day),
            let stored = newestExport(overlapping: interval)
        else { return nil }
        return AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: scope)
    }

    public func writeSharePayload(
        _ payload: AppleScreenTimeSharePayload,
        to destination: URL
    ) throws {
        let data = try AppleScreenTimeJSON.encode(payload)
        try writePrivate(data, to: destination)
    }

    @discardableResult
    public func deleteAllImports() throws -> Int {
        try queue.sync {
            let files = try fileManager.contentsOfDirectory(
                at: snapshotsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var count = 0
            for file in files where file.pathExtension.lowercased() == "json" {
                try fileManager.removeItem(at: file)
                count += 1
            }
            return count
        }
    }

    private func prepareDirectories() throws {
        for directory in [rootDirectory, snapshotsDirectory] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try prepareDirectories()
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
