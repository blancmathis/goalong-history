#if os(macOS)
import Foundation
import LocalHistoryCore

public enum GoalongFocusError: String, Error, CustomStringConvertible {
    case appNotRunning, moduleDisabled, invalidArgument, locked, notFound, storageFailed, tooManyWatchers
    /// `plan move` on a task already done or dropped.
    case itemFinished
    /// The plan changed since it was read, or a request ID was reused for different input.
    case conflict, requestConflict
    /// Client side only: the request reached the app but no answer came back in time.
    case outcomeUnknown
    public var description: String { rawValue }
}
public struct GoalongFocusRequest: Codable, Equatable {
    public var command: String
    public var options: [String: String]
    public var flags: Set<String>
    public var body: Data?
    public init(command: String, options: [String: String] = [:], flags: Set<String> = [], body: Data? = nil) {
        self.command = command; self.options = options; self.flags = flags; self.body = body
    }
}
extension GoalongFocusRequest {
    public func validated() throws -> GoalongFocusRequest {
        if command.hasPrefix("braise ") { return try GoalongBraiseCLI.validated(self) }
        let parts = command.split(separator: " ").map(String.init)
        guard let root = parts.first, parts.count <= 2 else { throw GoalongFocusError.invalidArgument }
        var args = Array(parts.dropFirst())
        var values = options
        if let title = values.removeValue(forKey: "title") { args.append(title) }
        if let id = values.removeValue(forKey: "id") { args.append(id) }
        if ["sessions", "friction", "plan show", "review show"].contains(command), let day = values.removeValue(forKey: "--day") { args.append(day) }
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            if key == "--block" || key == "--stake" { for id in value.split(separator: ",") { args += [key, String(id)] } }
            else { args += [key, value] }
        }
        args += flags.sorted()
        if body != nil { args += ["--file", "-"] }
        let parsed = try GoalongFocusCLI.parse(command: root, arguments: args, readFile: { _ in self.body ?? Data() })
        guard parsed == self else { throw GoalongFocusError.invalidArgument }; return parsed
    }
}
/// The client validates syntax; the app validates the same normalized request and owns every write.
public enum GoalongFocusCLI {
    public static let maximumInputBytes = 64 * 1024
    public static let commands = ["focus", "session", "sessions", "plan", "routine", "guide", "review", "limits", "block-lists", "block-list", "friction", "commitment", "commitments", "braise"]
    private static func text(_ value: String, max: Int = 140) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty && value.count <= max && value.utf8.count <= max * 32
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func day(_ value: String) -> Bool {
        if value == "today" || value == "yesterday" || value == "tomorrow" { return true }
        return GoalongDayParser.date(value) != nil
    }
    public static func parse(command: String, arguments: [String], readFile: (String) throws -> Data = readInput) throws -> GoalongFocusRequest {
        guard commands.contains(command), arguments.count <= 420, arguments.allSatisfy({ text($0, max: 4096) }) else { throw GoalongFocusError.invalidArgument }
        if command == "braise" { return try GoalongBraiseCLI.parse(arguments) }
        if command == "commitment" || command == "commitments" { return try GoalongCommitmentCLI.parse(command: command, arguments: arguments, readFile: readFile) }
        var args = arguments, action = "", options: [String: String] = [:], flags = Set<String>()
        if ["focus", "session", "plan", "routine", "guide", "block-list", "review"].contains(command) {
            guard !args.isEmpty else { throw GoalongFocusError.invalidArgument }; action = args.removeFirst()
        }
        var positional: [String] = [], blocks: [String] = []
        while !args.isEmpty {
            let token = args.removeFirst()
            if ["--open", "--lock", "--ambiance", "--block-during-breaks"].contains(token) {
                guard flags.insert(token).inserted else { throw GoalongFocusError.invalidArgument }; continue
            }
            if token == "--pomodoro" {
                guard options[token] == nil else { throw GoalongFocusError.invalidArgument }
                options[token] = !args.isEmpty && !args[0].hasPrefix("--") ? args.removeFirst() : "25/5/15/4"; continue
            }
            if token.hasPrefix("--") {
                guard ["--intent", "--minutes", "--cycles", "--block", "--plan-item", "--outcome", "--note", "--day", "--project", "--estimate", "--to", "--file", "--if-revision", "--request-id", "--if-match"].contains(token),
                      !args.isEmpty, !args[0].hasPrefix("--") else { throw GoalongFocusError.invalidArgument }
                let value = args.removeFirst()
                if token == "--block" { blocks.append(value) }
                else { guard options[token] == nil else { throw GoalongFocusError.invalidArgument }; options[token] = value }
            } else { positional.append(token) }
        }
        if !blocks.isEmpty { options["--block"] = blocks.joined(separator: ",") }
        var body: Data?
        let route = command + (action.isEmpty ? "" : " " + action)
        switch route {
        case "focus status", "focus watch", "session current", "session skip", "limits", "block-lists", "routine show", "guide show", "guide usage":
            guard options.isEmpty, flags.isEmpty, positional.isEmpty else { throw GoalongFocusError.invalidArgument }
        case "session start":
            guard positional.isEmpty, options.keys.allSatisfy({ ["--intent", "--minutes", "--cycles", "--block", "--plan-item", "--pomodoro"].contains($0) }),
                  flags.isSubset(of: ["--open", "--lock", "--ambiance", "--block-during-breaks"]),
                  options["--intent"].map({ text($0) }) == true else { throw GoalongFocusError.invalidArgument }
            let modes = (options["--minutes"] == nil ? 0 : 1) + (options["--pomodoro"] == nil ? 0 : 1) + (flags.contains("--open") ? 1 : 0)
            guard modes == 1, !flags.contains("--open") || !flags.contains("--lock"), !flags.contains("--lock") || !blocks.isEmpty else { throw GoalongFocusError.invalidArgument }
            if let minutes = options["--minutes"] { guard Int(minutes).map({ (5...240).contains($0) }) == true else { throw GoalongFocusError.invalidArgument } }
            if let p = options["--pomodoro"] {
                let n = p.split(separator: "/", omittingEmptySubsequences: false).compactMap { Int($0) }
                guard n.count == 4, (5...120).contains(n[0]), (1...30).contains(n[1]), (5...60).contains(n[2]), (2...8).contains(n[3]) else { throw GoalongFocusError.invalidArgument }
            }
            if let cycles = options["--cycles"] { guard options["--pomodoro"] != nil, Int(cycles).map({ (1...16).contains($0) }) == true else { throw GoalongFocusError.invalidArgument } }
            guard blocks.count <= 200, Set(blocks).count == blocks.count, blocks.allSatisfy({ UUID(uuidString: $0) != nil }),
                  options["--plan-item"].map({ UUID(uuidString: $0) != nil }) ?? true else { throw GoalongFocusError.invalidArgument }
        case "session stop":
            guard positional.isEmpty, flags.isEmpty, options.keys.allSatisfy({ ["--outcome", "--note"].contains($0) }),
                  options["--outcome"].map({ ["done", "partly", "not-done"].contains($0) }) ?? true,
                  options["--note"].map({ text($0) }) ?? true else { throw GoalongFocusError.invalidArgument }
        case "sessions", "friction", "plan show", "review show":
            guard flags.isEmpty, options.isEmpty, positional.count <= 1, positional.first.map(day) ?? true else { throw GoalongFocusError.invalidArgument }
            options["--day"] = positional.first ?? "today"
        case "plan add":
            guard flags.isEmpty, positional.count == 1, text(positional[0]), options.keys.allSatisfy({ ["--day", "--project", "--estimate"].contains($0) }),
                  options["--project"].map({ text($0) }) ?? true,
                  options["--estimate"].map({ Int($0).map({ (5...600).contains($0) }) == true }) ?? true else { throw GoalongFocusError.invalidArgument }
            options["title"] = positional[0]
        case "plan done", "plan drop", "plan move":
            let allowed = action == "move" ? ["--day", "--to"] : ["--day"]
            guard flags.isEmpty, positional.count == 1, UUID(uuidString: positional[0]) != nil, options.keys.allSatisfy({ allowed.contains($0) }),
                  action != "move" || options["--to"].map(day) == true else { throw GoalongFocusError.invalidArgument }
            options["id"] = positional[0]
        case "plan patch", "plan reflow", "plan undo":
            let allowed = action == "patch" ? ["--day", "--if-revision", "--request-id", "--file"] : ["--day", "--if-revision", "--request-id"]
            guard flags.isEmpty, positional.isEmpty, options.keys.allSatisfy({ allowed.contains($0) }),
                  options["--day"].map(day) == true,
                  let rawRevision = options["--if-revision"], let revision = Int(rawRevision),
                  (0...1_000_000_000).contains(revision), String(revision) == rawRevision,
                  options["--request-id"].map({ text($0, max: 128) }) == true else { throw GoalongFocusError.invalidArgument }
            if action == "patch" {
                guard let path = options.removeValue(forKey: "--file") else { throw GoalongFocusError.invalidArgument }
                body = try readFile(path)
                guard body!.count <= maximumInputBytes, (try? JSONSerialization.jsonObject(with: body!)) is [String: Any] else { throw GoalongFocusError.invalidArgument }
            }
        case "routine set":
            guard flags.isEmpty, positional.isEmpty, options.keys.allSatisfy({ ["--file", "--if-revision"].contains($0) }),
                  let path = options.removeValue(forKey: "--file") else { throw GoalongFocusError.invalidArgument }
            if let raw = options["--if-revision"] {
                guard let revision = Int(raw), (0...1_000_000_000).contains(revision), String(revision) == raw else { throw GoalongFocusError.invalidArgument }
            }
            body = try readFile(path)
            try validateRoutineInput(body!)
        case "guide set":
            guard flags.isEmpty, positional.isEmpty, options.count == 2,
                  let path = options.removeValue(forKey: "--file"),
                  let raw = options["--if-revision"], let revision = Int(raw),
                  (0...1_000_000_000).contains(revision), String(revision) == raw else { throw GoalongFocusError.invalidArgument }
            body = try readFile(path); try validateGuideInput(body!)
        case "block-list show":
            guard flags.isEmpty, options.isEmpty, positional.count == 1,
                  UUID(uuidString: positional[0]) != nil else { throw GoalongFocusError.invalidArgument }
            options["id"] = positional[0]
        case "block-list put":
            guard flags.isEmpty, positional.isEmpty, options.count == 2,
                  let path = options.removeValue(forKey: "--file"), let match = options["--if-match"],
                  match == "new" || (match.count == 64 && match.allSatisfy({ "0123456789abcdef".contains($0) })) else { throw GoalongFocusError.invalidArgument }
            body = try readFile(path); try validateBlockListInput(body!)
        case "plan set", "review set":
            guard flags.isEmpty, positional.isEmpty, options.keys.allSatisfy({ ["--day", "--file"].contains($0) }), let path = options.removeValue(forKey: "--file") else { throw GoalongFocusError.invalidArgument }
            body = try readFile(path)
            guard body!.count <= maximumInputBytes, let object = try? JSONSerialization.jsonObject(with: body!), object is [String: Any] else { throw GoalongFocusError.invalidArgument }
        default: throw GoalongFocusError.invalidArgument
        }
        guard options["--day"].map(day) ?? true else { throw GoalongFocusError.invalidArgument }
        return GoalongFocusRequest(command: route, options: options, flags: flags, body: body)
    }
    /// Reject unknown routine fields before the request reaches the app. The app also validates
    /// the typed agenda, civil-time ranges and the absence of task commitments in a template.
    private static func validateRoutineInput(_ data: Data) throws {
        guard data.count <= maximumInputBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["agenda"], let rawAgenda = object["agenda"] else { throw GoalongFocusError.invalidArgument }
        if rawAgenda is NSNull { return }
        guard let agenda = rawAgenda as? [String: Any],
              Set(agenda.keys).isSubset(of: ["timeZoneID", "startMinute", "endMinute", "bufferMinutes", "reminderLimit", "guided", "autoAdjust", "slots"]),
              agenda["timeZoneID"] is String else { throw GoalongFocusError.invalidArgument }
        if let rawSlots = agenda["slots"] {
            guard let slots = rawSlots as? [[String: Any]], slots.count <= 64 else { throw GoalongFocusError.invalidArgument }
            let allowed: Set<String> = ["id", "itemID", "title", "startMinute", "endMinute", "fixed", "state", "earliestMinute", "latestEndMinute", "instructions", "reminder", "contextURL"]
            guard slots.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else { throw GoalongFocusError.invalidArgument }
        }
    }
    /// The same schema checks run at the native app boundary; unknown fields never silently disappear.
    public static func validateGuideInput(_ data: Data) throws {
        guard data.count <= maximumInputBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty,
              Set(object.keys).isSubset(of: ["dayGuide", "coach", "morningPrompt", "morningMinute", "eveningPrompt", "eveningMinute"]) else { throw GoalongFocusError.invalidArgument }
        let groups: [(String, Set<String>)] = [
            ("dayGuide", ["enabled", "introVersion", "remindersEnabled", "quietStartMinute", "quietEndMinute"]),
            ("coach", ["enabled", "provider", "model", "reasoningEffort", "dailyCallLimit", "maximumOutputCharacters", "includeTasks", "includeAgenda", "includeProcesses", "includeReview"]),
        ]
        for (key, keys) in groups {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let group = raw as? [String: Any], Set(group.keys).isSubset(of: keys) else { throw GoalongFocusError.invalidArgument }
        }
        for key in ["morningPrompt", "morningMinute", "eveningPrompt", "eveningMinute"] where object[key] is NSNull { throw GoalongFocusError.invalidArgument }
    }
    public static func validateBlockListInput(_ data: Data) throws {
        guard data.count <= maximumInputBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["list"], let list = object["list"] as? [String: Any],
              Set(list.keys).isSubset(of: ["id", "name", "mode", "sites", "exceptions", "keywords", "reason", "triggers", "earn", "apps", "program", "quotaMinutesPerDay", "breaks", "action", "slowDownSeconds", "continueMinutes"]),
              (list["id"] as? String).flatMap(UUID.init(uuidString:)) != nil else { throw GoalongFocusError.invalidArgument }
        func rows(_ raw: Any?, keys: Set<String>, maximum: Int) throws {
            guard let raw, !(raw is NSNull) else { return }
            guard let values = raw as? [[String: Any]], values.count <= maximum,
                  values.allSatisfy({ Set($0.keys).isSubset(of: keys) }) else { throw GoalongFocusError.invalidArgument }
        }
        func bounded(_ object: [String: Any], _ key: String, _ range: ClosedRange<Int>, required: Bool = false) throws {
            guard let raw = object[key], !(raw is NSNull) else {
                if required { throw GoalongFocusError.invalidArgument }
                return
            }
            guard let value = raw as? Int, range.contains(value) else { throw GoalongFocusError.invalidArgument }
        }
        try rows(list["sites"], keys: ["pattern"], maximum: 2000)
        try rows(list["exceptions"], keys: ["pattern"], maximum: 2000)
        try rows(list["apps"], keys: ["bundleIdentifier", "name"], maximum: 500)
        if let raw = list["program"] {
            guard let program = raw as? [String: Any], Set(program.keys).isSubset(of: ["ranges", "lockedUntil"]) else { throw GoalongFocusError.invalidArgument }
            try rows(program["ranges"], keys: ["id", "weekdays", "startMinute", "endMinute", "lock", "pause"], maximum: 128)
            if let ranges = program["ranges"] as? [[String: Any]] {
                for range in ranges {
                    guard (range["id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
                          let days = range["weekdays"] as? [Int], !days.isEmpty, days.count <= 7,
                          Set(days).count == days.count, days.allSatisfy({ (1...7).contains($0) }) else { throw GoalongFocusError.invalidArgument }
                    try bounded(range, "startMinute", 0...1440, required: true)
                    try bounded(range, "endMinute", 0...1440, required: true)
                    if let rawPause = range["pause"], !(rawPause is NSNull) {
                        guard let pause = rawPause as? [String: Any],
                              Set(pause.keys).isSubset(of: ["id", "budgetMinutes", "period", "maxPauseMinutes", "maxPauses", "gate", "extraPerPeriod"]),
                              (pause["id"] as? String).flatMap(UUID.init(uuidString:)) != nil else { throw GoalongFocusError.invalidArgument }
                        try bounded(pause, "budgetMinutes", 1...1440)
                        try bounded(pause, "maxPauseMinutes", 1...1440)
                        try bounded(pause, "maxPauses", 1...1440)
                        try bounded(pause, "extraPerPeriod", 0...10)
                        if let rawGate = pause["gate"] {
                            guard let gate = rawGate as? [String: Any], gate.count == 1,
                                  Set(gate.keys).isSubset(of: ["none", "wait", "typing", "password"]),
                                  let value = gate.values.first as? [String: Any],
                                  Set(value.keys).isSubset(of: gate["wait"] == nil ? [] : ["minutes"]) else { throw GoalongFocusError.invalidArgument }
                            if gate["wait"] != nil { try bounded(value, "minutes", 1...1440, required: true) }
                        }
                    }
                }
            }
        }
        let objects: [(String, Set<String>)] = [("breaks", ["count", "minutes"]), ("earn", ["workMinutes", "rewardMinutes", "capMinutes"]), ("triggers", ["apps", "focus"])]
        for (key, keys) in objects {
            guard let raw = list[key], !(raw is NSNull) else { continue }
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw GoalongFocusError.invalidArgument }
            if key == "triggers" { try rows(value["apps"], keys: ["bundleIdentifier", "name"], maximum: 500) }
        }
    }
    public static func readInput(_ path: String) throws -> Data {
        let handle: FileHandle
        if path == "-" { handle = .standardInput }
        else {
            guard !path.contains("://"), text(path, max: 4096) else { throw GoalongFocusError.invalidArgument }
            do { handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) } catch { throw GoalongFocusError.invalidArgument }
        }
        defer { if path != "-" { try? handle.close() } }
        var data = Data()
        while let part = try handle.read(upToCount: min(8192, maximumInputBytes + 1 - data.count)), !part.isEmpty {
            data.append(part); guard data.count <= maximumInputBytes else { throw GoalongFocusError.invalidArgument }
        }
        return data
    }
    public static func execute(_ request: GoalongFocusRequest, root: URL) throws -> Data {
        do { return try GoalongReadOnlyQueryBroker.requestFocus(rootDirectory: root, request: request) }
        catch GoalongFocusError.appNotRunning where request.command == "focus status" { return unavailable }
        catch GoalongFocusError.outcomeUnknown where request.command == "focus status" { return unavailable }
    }
    public static let unavailable = Data("{\"schema\":1,\"state\":\"unavailable\"}".utf8)
    public static func watch(root: URL, emit: (Data) -> Void, shouldContinue: () -> Bool = { true }, retry: () -> Void = { Thread.sleep(forTimeInterval: 5) }) throws {
        let id = UUID().uuidString
        var cursor: String?, wasUnavailable = false
        defer { _ = try? GoalongReadOnlyQueryBroker.requestFocus(rootDirectory: root, request: .init(command: "focus unwatch", options: ["id": id])) }
        while shouldContinue() {
            do {
                var options = ["id": id]; if let cursor { options["cursor"] = cursor }
                let data = try GoalongReadOnlyQueryBroker.requestFocus(rootDirectory: root, request: .init(command: "focus watch", options: options))
                let envelope = try JSONDecoder().decode(GoalongFocusWatchBatch.self, from: data)
                for value in envelope.lines { emit(value) }
                cursor = envelope.cursor; wasUnavailable = false
            } catch let error as GoalongFocusError where error == .appNotRunning || error == .outcomeUnknown {
                if !wasUnavailable { emit(unavailable); wasUnavailable = true }; cursor = nil; retry()
            }
        }
    }
}
public struct GoalongFocusWatchBatch: Codable { public var cursor: String; public var lines: [Data] }
/// Long-poll subscriptions: immediate wake on change, bounded leases and replay, no observation.
public final class GoalongFocusStatusHub {
    private let condition = NSCondition()
    private let instance = UUID().uuidString
    private var sequence = 0
    private var lines: [(Int, Data)] = []
    private var leases: [String: Date] = [:]
    public init() {}
    public func publish(_ line: Data) {
        condition.lock(); defer { condition.unlock() }
        guard lines.last?.1 != line else { return }
        sequence += 1; lines.append((sequence, line)); if lines.count > 256 { lines.removeFirst() }; condition.broadcast()
    }
    public func remove(_ id: String) { condition.lock(); leases[id] = nil; condition.unlock() }
    public func poll(id: String, cursor: String?, timeout: TimeInterval = 5) throws -> GoalongFocusWatchBatch {
        condition.lock(); defer { condition.unlock() }
        guard UUID(uuidString: id) != nil else { throw GoalongFocusError.invalidArgument }
        leases = leases.filter { $0.value > Date() }
        guard leases[id] != nil || leases.count < 8 else { throw GoalongFocusError.tooManyWatchers }
        leases[id] = Date().addingTimeInterval(15)
        let prefix = instance + ":"
        let prior = cursor.flatMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }
        if prior == sequence { _ = condition.wait(until: Date().addingTimeInterval(min(5, max(0, timeout)))) }
        let output = prior.map { old in lines.filter { $0.0 > old }.map(\.1) } ?? lines.last.map { [$0.1] } ?? []
        return GoalongFocusWatchBatch(cursor: prefix + "\(sequence)", lines: output)
    }
}
#endif
