import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct GoalongWorkRetryState: Codable, Equatable, Sendable {
    public var attempts: Int
    public var lastAskedDay: String?
    public init(attempts: Int = 1, lastAskedDay: String? = nil) {
        self.attempts = max(0, attempts); self.lastAskedDay = lastAskedDay
    }
    public func permitsReassessment(on day: String, seconds: TimeInterval) -> Bool {
        seconds >= 300 && attempts < 3 && lastAskedDay != day
    }
}

/// Most recent safe visible context, read only on a re-ask and never persisted.
public enum GoalongWorkReassessment {
    public static let maximumExcerptCharacters = 240
    public static func excerpts(root: URL, day: Date, keys: Set<String>, calendar: Calendar = .current,
                                permits: (GoalongWorkContext.Label) -> Bool,
                                shouldContinue: () -> Bool = { true }) -> [String: String] {
        guard !keys.isEmpty, shouldContinue() else { return [:] }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return [:] }; defer { close(rootFD) }
        let directory = openat(rootFD, "semantic", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return [:] }; defer { close(directory) }
        let name = GoalongActivityDayStore.dayKey(day, calendar: calendar) + ".semantic.jsonl"
        let file = root.appendingPathComponent("semantic/" + name)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: start)!
        var latest: [String: (Date, String)] = [:], failed = false, visited = 0
        let deadline = Date().addingTimeInterval(20)
        do {
            let metrics = try HistoryJSONLinesStreamReader(maximumLineBytes: 256 * 1024).read(
                file: file, directoryDescriptor: directory, relativeName: name, maximumBytes: 64 * 1024 * 1024,
                shouldContinue: { shouldContinue() && visited <= 32_768 && Date() < deadline },
                onLine: { bytes, _ in
                    visited += 1
                    guard let payload = try? decoder.decode(SemanticContextPayload.self, from: bytes),
                          payload.schemaVersion == 1, payload.capturedAt >= start, payload.capturedAt < end else { return }
                    let label = GoalongWorkContext.Label(application: payload.application.name,
                        bundleIdentifier: payload.application.bundleIdentifier, host: payload.url?.host?.lowercased(),
                        title: GoalongWorkContext.displayTitle(payload.window?.title))
                    guard keys.contains(label.key), permits(label), payload.contentSHA256 == SHA256Digest.hashHex(payload.text),
                          let redacted = ActivitySemanticTextSanitizer.redact(payload.text), !redacted.isEmpty else { return }
                    if latest[label.key].map({ $0.0 <= payload.capturedAt }) ?? true {
                        latest[label.key] = (payload.capturedAt, String(redacted.prefix(maximumExcerptCharacters)))
                    }
                }, onOversizedLine: { _, _ in failed = true })
            guard !failed, !metrics.wasCancelled, !metrics.reachedByteLimit, !metrics.sourceChangedDuringRead else { return [:] }
            return latest.mapValues { $0.1 }
        } catch { return [:] }
    }
}
