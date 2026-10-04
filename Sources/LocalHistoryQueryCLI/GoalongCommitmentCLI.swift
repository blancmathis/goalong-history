#if os(macOS)
import Foundation

public enum GoalongCommitmentCLI {
    public static func target(_ input: String, kind: String) -> Int? {
        let digits = CharacterSet(charactersIn: "0123456789")
        func number(_ value: String) -> Int? {
            guard !value.isEmpty, value.unicodeScalars.allSatisfy({ digits.contains($0) }) else { return nil }; return Int(value)
        }
        if kind == "sessions" || kind == "plan" { return number(input) }
        if input.hasSuffix("m"), !input.contains("h") { return number(String(input.dropLast())) }
        if let h = input.firstIndex(of: "h") {
            guard let hours = number(String(input[..<h])), hours <= 80 else { return nil }
            var suffix = String(input[input.index(after: h)...]); if suffix.hasSuffix("m") { suffix.removeLast() }
            guard let minutes = suffix.isEmpty ? 0 : number(suffix), minutes < 60 else { return nil }; return hours * 60 + minutes
        }
        return number(input)
    }
    static func day(_ input: String) -> Bool { ["today", "tomorrow"].contains(input) || GoalongFocusCalendar.dayInterval(input) != nil }
    static func week(_ input: String) -> Bool { ["this", "next"].contains(input) || GoalongFocusCalendar.weekInterval(input) != nil }
    static func parse(command: String, arguments: [String], readFile: (String) throws -> Data) throws -> GoalongFocusRequest {
        var args = arguments, action = "", options: [String: String] = [:], stakes: [String] = []
        if command == "commitment" { guard !args.isEmpty else { throw GoalongFocusError.invalidArgument }; action = args.removeFirst() }
        while !args.isEmpty {
            let key = args.removeFirst()
            guard ["--day", "--week", "--kind", "--target", "--task", "--stake", "--until", "--file", "--from", "--to"].contains(key),
                  !args.isEmpty, !args[0].hasPrefix("--") else { throw GoalongFocusError.invalidArgument }
            let value = args.removeFirst()
            if key == "--stake" { stakes.append(value) }
            else { guard options[key] == nil else { throw GoalongFocusError.invalidArgument }; options[key] = value }
        }
        if !stakes.isEmpty { options["--stake"] = stakes.joined(separator: ",") }
        let route = command + (action.isEmpty ? "" : " " + action)
        var body: Data?
        switch route {
        case "commitments":
            guard options.keys.allSatisfy({ ["--from", "--to"].contains($0) }), options.values.allSatisfy({ GoalongFocusCalendar.dayInterval($0) != nil }),
                  options["--from"] == nil || options["--to"] == nil || options["--from"]! <= options["--to"]! else { throw GoalongFocusError.invalidArgument }
        case "commitment show":
            guard options.keys.allSatisfy({ ["--day", "--week"].contains($0) }) else { throw GoalongFocusError.invalidArgument }
        case "commitment delete", "commitment joker", "commitment declare":
            guard options.count == 1, options["--day"] != nil || options["--week"] != nil else { throw GoalongFocusError.invalidArgument }
        case "commitment set":
            guard (options["--day"] == nil) != (options["--week"] == nil) else { throw GoalongFocusError.invalidArgument }
            if let file = options.removeValue(forKey: "--file") {
                guard options.keys.allSatisfy({ ["--day", "--week"].contains($0) }) else { throw GoalongFocusError.invalidArgument }
                body = try readFile(file)
                guard body!.count <= GoalongFocusCLI.maximumInputBytes, (try? JSONSerialization.jsonObject(with: body!)) is [String: Any] else { throw GoalongFocusError.invalidArgument }
            } else {
                guard options.keys.allSatisfy({ ["--day", "--week", "--kind", "--target", "--task", "--stake", "--until"].contains($0) }),
                      let kind = options["--kind"], ["work", "task", "sessions", "plan"].contains(kind), let input = options["--target"], let n = target(input, kind: kind),
                      (kind == "task" ? options["--task"] != nil : options["--task"] == nil), options["--until"] == nil || !stakes.isEmpty else { throw GoalongFocusError.invalidArgument }
                let isWeek = options["--week"] != nil
                let minimum = kind == "work" ? (isWeek ? 60 : 30) : kind == "task" ? (isWeek ? 30 : 15) : 1
                let maximum = kind == "sessions" ? (isWeek ? 60 : 12) : kind == "plan" ? (isWeek ? 70 : 10) : (isWeek ? 4800 : 960)
                guard (minimum...maximum).contains(n), ["sessions", "plan"].contains(kind) || n % 15 == 0 else { throw GoalongFocusError.invalidArgument }
                if let task = options["--task"] { guard task.count <= 140, !task.trimmingCharacters(in: .whitespaces).isEmpty else { throw GoalongFocusError.invalidArgument } }
                guard stakes.count <= 200, Set(stakes).count == stakes.count, stakes.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw GoalongFocusError.invalidArgument }
                if let until = options["--until"] {
                    let n = until.split(separator: ":", omittingEmptySubsequences: false)
                    guard n.count == 2, let h = Int(n[0]), let m = Int(n[1]), (0...23).contains(h), (0...59).contains(m), String(format: "%02d:%02d", h, m) == until else { throw GoalongFocusError.invalidArgument }
                }
            }
        default: throw GoalongFocusError.invalidArgument
        }
        guard options["--day"].map(day) ?? true, options["--week"].map(week) ?? true else { throw GoalongFocusError.invalidArgument }
        return GoalongFocusRequest(command: route, options: options, body: body)
    }
}
#endif
