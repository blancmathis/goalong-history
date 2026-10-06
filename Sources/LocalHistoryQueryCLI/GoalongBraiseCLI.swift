#if os(macOS)
import Foundation

/// Normalized requests use the existing same-UID app broker. No distributed notifications.
public enum GoalongBraiseCLI {
    public static func parse(_ arguments: [String]) throws -> GoalongFocusRequest {
        guard arguments.count <= 5, arguments.allSatisfy({ $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              let action = arguments.first else { throw GoalongFocusError.invalidArgument }
        if ["status", "probe", "show", "on", "off", "auto", "pause", "resume", "enable", "disable", "quit"].contains(action), arguments.count == 1 {
            return .init(command: "braise " + action)
        }
        if ["intensity", "brightness"].contains(action), arguments.count == 2,
           let value = Double(arguments[1]), value.isFinite,
           (action == "intensity" ? 0.0...100.0 : 20.0...100.0).contains(value) {
            return .init(command: "braise " + action, options: ["value": arguments[1]])
        }
        if action == "login", arguments.count == 2, ["on", "off"].contains(arguments[1]) {
            return .init(command: "braise login", options: ["value": arguments[1]])
        }
        guard action == "schedule", arguments.count >= 2 else { throw GoalongFocusError.invalidArgument }
        let operation = arguments[1]
        if operation == "list", arguments.count == 2 { return .init(command: "braise schedule") }
        if operation == "add", arguments.count == 5 {
            let tokens = arguments[2].split(separator: ",", omittingEmptySubsequences: false)
            let days = tokens.compactMap { Int($0) }
            guard !days.isEmpty, days.count == tokens.count, days.allSatisfy({ (1...7).contains($0) }),
                  let start = minute(arguments[3]), let end = minute(arguments[4]), start != end else { throw GoalongFocusError.invalidArgument }
            return .init(command: "braise rule-add", options: ["days": arguments[2], "start": arguments[3], "end": arguments[4]])
        }
        if ["remove", "enable", "disable"].contains(operation), arguments.count == 3, UUID(uuidString: arguments[2]) != nil {
            return .init(command: "braise rule-" + operation, options: ["id": arguments[2]])
        }
        throw GoalongFocusError.invalidArgument
    }
    public static func minute(_ value: String) -> Int? {
        let p = value.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
    public static func validated(_ request: GoalongFocusRequest) throws -> GoalongFocusRequest {
        guard request.flags.isEmpty, request.body == nil else { throw GoalongFocusError.invalidArgument }
        let parts = request.command.split(separator: " ").map(String.init)
        guard parts.count == 2, parts[0] == "braise" else { throw GoalongFocusError.invalidArgument }
        let action = parts[1], o = request.options
        var args = [action]
        switch action {
        case "schedule": args = ["schedule", "list"]
        case "rule-add": args = ["schedule", "add", o["days"] ?? "", o["start"] ?? "", o["end"] ?? ""]
        case "rule-remove", "rule-enable", "rule-disable": args = ["schedule", String(action.dropFirst(5)), o["id"] ?? ""]
        case "intensity", "brightness", "login": args.append(o["value"] ?? "")
        default: break
        }
        guard try parse(args) == request else { throw GoalongFocusError.invalidArgument }; return request
    }
}
#endif
