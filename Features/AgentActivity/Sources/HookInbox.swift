import Foundation

public enum AgentHookInboxError: Error, LocalizedError {
    case payloadTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let bytes):
            return "The agent hook payload is too large to record safely (\(bytes) bytes)."
        }
    }
}

public enum AgentHookInboxWriter {
    public static let maximumPayloadBytes = 512 * 1_024 * 1_024

    @discardableResult
    public static func write(
        rootDirectory: URL,
        provider: AgentProvider,
        eventName: String,
        payload: Data,
        processIdentifier: Int32,
        capturedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        guard payload.count <= maximumPayloadBytes else {
            throw AgentHookInboxError.payloadTooLarge(payload.count)
        }

        let providerDirectory =
            rootDirectory
            .appendingPathComponent("hook-inbox", isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(localDay(capturedAt), isDirectory: true)
        try createSecureDirectory(providerDirectory, fileManager: fileManager)

        let envelope = AgentHookEnvelope(
            provider: provider,
            eventName: eventName,
            capturedAt: capturedAt,
            processIdentifier: processIdentifier,
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)

        let milliseconds = Int64(capturedAt.timeIntervalSince1970 * 1_000)
        let event = safeComponent(eventName)
        let destination = providerDirectory.appendingPathComponent(
            "\(milliseconds)-\(event)-\(envelope.id).agent-event.json",
            isDirectory: false
        )
        try data.write(to: destination, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    private static func createSecureDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func safeComponent(_ value: String) -> String {
        let mapped = value.map { character -> Character in
            character.isLetter || character.isNumber || "-_.".contains(character) ? character : "_"
        }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return result.isEmpty ? "event" : String(result.prefix(100))
    }
}
