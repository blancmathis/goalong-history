import Foundation
import CryptoKit

/// Transient numeric evidence only. Never encoded into the metadata index.
public struct AgentTokenUsage: Equatable, Sendable {
    public var events: [Event] = []
    public var partial = false
    public struct Event: Equatable, Sendable, Identifiable {
        public var id: String
        public var date: Date
        public var model: String
        public var input: Int64?
        public var output: Int64?
        public var cacheRead: Int64?
        public var cacheWrite: Int64?
        public var reasoning: Int64?
        public var total: Int64?
    }
}

struct AgentUsageParser {
    let provider: AgentProvider
    let interval: DateInterval?
    var usage = AgentTokenUsage()
    var model = "Unknown model"
    var previous: [String: Int64]?
    var fork = false
    var seen = Set<String>()
    static let maximumEvents = 4096

    mutating func consume(_ object: [String: Any], rowID: String? = nil) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        if provider == .codex {
            if object["type"] as? String == "session_meta", payload["forked_from_id"] != nil {
                fork = true
                usage.partial = true
            }
            if object["type"] as? String == "turn_context" {
                model = String((payload["model"] as? String ?? "Unknown model").prefix(256))
            }
        }
        var values: [String: Int64] = [:]
        var identity: String?
        var date = Self.date(object["timestamp"])
        var eventModel = model
        switch provider {
        case .codex:
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { return }
            let total = Self.counters(info["total_token_usage"])
            let last = Self.counters(info["last_token_usage"])
            if !total.isEmpty, total == previous { return }
            defer { if !total.isEmpty { previous = total } }
            guard !fork else { return }
            if !last.isEmpty {
                values = last
            } else if !total.isEmpty, let previous, total.allSatisfy({ $0.value >= (previous[$0.key] ?? 0) }) {
                values = total.mapValues { $0 }
                for (key, value) in total { values[key] = previous[key].map { value - $0 } }
            } else {
                // An initial cumulative snapshot may contain earlier days or inherited work.
                usage.partial = true
                return
            }
            identity = Self.digest([object["timestamp"] as? String ?? "", String(describing: total.sorted { $0.key < $1.key }), String(describing: values.sorted { $0.key < $1.key })].joined(separator: "|"))
        case .claudeCode:
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let raw = message["usage"] as? [String: Any] else { return }
            values = Self.counters(raw)
            eventModel = String((message["model"] as? String ?? "Unknown model").prefix(256))
            identity = (message["id"] as? String).map { $0 + "|" + (object["requestId"] as? String ?? "") }
            // Anthropic's input excludes both cache categories.
            values["cached_input_tokens"] = values["cache_read_input_tokens"]
            values["cache_write"] = values["cache_creation_input_tokens"]
            if let input = values["input_tokens"], let read = values["cached_input_tokens"], let write = values["cache_write"] {
                values["input_tokens"] = input + read + write
            } else { values["input_tokens"] = nil }
        case .openCode:
            guard object["role"] as? String == "assistant",
                  let raw = object["tokens"] as? [String: Any] else { return }
            let cache = Self.counters(raw["cache"])
            let tokens = Self.counters(raw)
            values["input_tokens"] = tokens["input"].flatMap { input in cache["read"].flatMap { read in cache["write"].map { input + read + $0 } } }
            values["output_tokens"] = tokens["output"]
            values["cached_input_tokens"] = cache["read"]
            values["cache_write"] = cache["write"]
            values["reasoning_output_tokens"] = tokens["reasoning"]
            // Provider-normalized OpenCode output/reasoning conventions vary. Use its explicit total only.
            values["total_tokens"] = tokens["total"]
            eventModel = String((object["modelID"] as? String ?? "Unknown model").prefix(256))
            identity = rowID ?? object["id"] as? String
            let time = object["time"] as? [String: Any] ?? [:]
            date = Self.date(time["completed"] ?? time["created"])
        default: return
        }
        guard let date else { usage.partial = true; return }
        guard interval.map({ date >= $0.start && date < $0.end }) ?? true else { return }
        guard let identity else { usage.partial = true; return }
        let id = Self.digest(provider.rawValue + "|" + identity)
        guard usage.events.count < Self.maximumEvents else { usage.partial = true; return }
        guard seen.insert(id).inserted else { return }
        if provider == .codex { values["cache_write"] = values["cache_write_input_tokens"] }
        let input = values["input_tokens"], output = values["output_tokens"]
        let total = values["total_tokens"] ?? (provider == .openCode ? nil : input.flatMap { i in output.map { i + $0 } })
        usage.events.append(.init(id: id, date: date, model: eventModel, input: input, output: output,
                                  cacheRead: values["cached_input_tokens"], cacheWrite: values["cache_write"],
                                  reasoning: values["reasoning_output_tokens"], total: total))
    }

    static func counters(_ value: Any?) -> [String: Int64] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, pair in
            guard let n = pair.value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue <= 1e15, n.doubleValue.rounded() == n.doubleValue else { return }
            result[pair.key] = n.int64Value
        }
    }
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1000) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct AgentDailyTokenUsage {
    public struct Row: Identifiable {
        public var id: String
        public var provider: AgentProvider
        public var session: String
        public var model: String
        public var events: [AgentTokenUsage.Event]
        public func sum(_ field: KeyPath<AgentTokenUsage.Event, Int64?>) -> Int64? {
            guard !events.isEmpty, events.allSatisfy({ $0[keyPath: field] != nil }) else { return nil }
            return events.reduce(0) { $0 + ($1[keyPath: field] ?? 0) }
        }
    }
    public var rows: [Row] = []
    public var partial = false
    public init(records: [AgentCaptureRecord], day: Date, calendar: Calendar = .current, sourceCoverageIncomplete: Bool = false) {
        partial = sourceCoverageIncomplete
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var seen = Set<String>()
        for record in records.sorted(by: { $0.id < $1.id }) {
            partial = partial || !record.projectionIsComplete || record.availability != .available || record.summary.tokenUsage.partial || record.summary.tokenUsage.events.isEmpty || record.summary.tokenUsage.events.contains { $0.total == nil }
            let events = record.summary.tokenUsage.events.filter { $0.date >= start && $0.date < end && seen.insert($0.id).inserted }
            for (model, group) in Dictionary(grouping: events, by: \.model) {
                rows.append(Row(id: record.id + model, provider: record.provider, session: record.summary.title ?? "Conversation", model: model, events: group))
            }
        }
        rows.sort { $0.id < $1.id }
    }
    public var observedTotal: Int64? {
        let totals = rows.flatMap(\.events).compactMap(\.total)
        return totals.isEmpty ? nil : totals.reduce(0, +)
    }
}
