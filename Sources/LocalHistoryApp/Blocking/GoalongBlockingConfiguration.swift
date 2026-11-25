#if os(macOS)
import CryptoKit
import Foundation
import LocalHistoryQueryCLI

/// Agent configuration goes through the same native validation, persistence and locks as the UI.
/// No password, stop grant, session, clock or enforcement-state field is exposed by this API.
@MainActor enum GoalongBlockingConfiguration {
    static func fingerprint(_ list: BlockList) throws -> String {
        var object = try JSONSerialization.jsonObject(with: FocusJSON.encode(list)) as! [String: Any]
        if var program = object["program"] as? [String: Any], var ranges = program["ranges"] as? [[String: Any]] {
            // Set<Int> has no stable encoding order across launches.
            for index in ranges.indices {
                if let days = ranges[index]["weekdays"] as? [Int] { ranges[index]["weekdays"] = days.sorted() }
            }
            program["ranges"] = ranges; object["program"] = program
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func payload(_ list: BlockList, controller: BlockingController) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": 1,
            "fingerprint": fingerprint(list),
            "list": JSONSerialization.jsonObject(with: FocusJSON.encode(list)),
            "locked": controller.isStricterOnly(list.id),
            "hasPassword": controller.hasPassword,
        ], options: [.sortedKeys])
    }
    static func handle(_ input: GoalongFocusRequest, controller: BlockingController) throws -> Data {
        let request = try input.validated()
        controller.refresh(enforceLast: false)
        if request.command == "block-list show" {
            guard let id = request.options["id"].flatMap(UUID.init(uuidString:)), let list = controller.list(id) else { throw GoalongFocusError.notFound }
            return try payload(list, controller: controller)
        }
        guard request.command == "block-list put", let body = request.body,
              let expected = request.options["--if-match"] else { throw GoalongFocusError.invalidArgument }
        try GoalongFocusCLI.validateBlockListInput(body)
        struct Envelope: Decodable { var list: BlockList }
        let value: BlockList
        do { value = try FocusJSON.decode(Envelope.self, from: body).list }
        catch { throw GoalongFocusError.invalidArgument }
        // Validate numbers before coverage arithmetic, pause arithmetic or a native edit check.
        // UI fields already bound these values; a JSON caller has no such protection.
        guard BlockingRules.validate(BlockingDocument(lists: [value])),
              value.program.ranges.count <= 128,
              value.program.ranges.allSatisfy({ validPause($0.pause) }) else { throw GoalongFocusError.invalidArgument }
        let current = controller.list(value.id)
        if expected == "new" {
            guard current == nil else { throw GoalongFocusError.conflict }
        } else {
            guard let current, try fingerprint(current) == expected else { throw GoalongFocusError.conflict }
        }
        if let current {
            let protectedList = controller.isStricterOnly(current.id)
            for old in current.program.ranges where protectedList || old.effectiveLock != .free {
                // A replacement UUID, or a moved original plus a replacement, can reset a pause pool.
                // Remote edits keep each protected range's identity and civil geometry. Extra coverage
                // is added as a new range; reshaping/stopping protected rules remains a native action.
                guard let kept = value.program.ranges.first(where: { $0.id == old.id }),
                      kept.weekdays == old.weekdays, kept.startMinute == old.startMinute,
                      kept.endMinute == old.endMinute else { throw GoalongFocusError.locked }
            }
        }
        var candidate = controller.snapshot
        candidate.lists.removeAll { $0.id == value.id }; candidate.lists.append(value)
        guard BlockingRules.validate(candidate) else { throw GoalongFocusError.invalidArgument }
        // Remote configuration cannot borrow a prior UI password grant or open an authentication dialog.
        // A weakening that needs a native stop remains a native user action, even outside its active window.
        guard controller.weakeningStop(value) == nil else { throw GoalongFocusError.locked }
        if case .refused = controller.editCheck(value) {
            throw current.map { controller.isStricterOnly($0.id) } == true ? GoalongFocusError.locked : .invalidArgument
        }
        if controller.save(value) != nil { throw GoalongFocusError.invalidArgument }
        guard let saved = controller.list(value.id) else { throw GoalongFocusError.storageFailed }
        return try payload(saved, controller: controller)
    }
    private static func validPause(_ value: PausePolicy?) -> Bool {
        guard let value else { return true }
        guard PausePolicy.budgetRange.contains(value.budgetMinutes),
              value.maxPauseMinutes.map({ (1...1440).contains($0) }) ?? true,
              value.maxPauses.map({ (1...1440).contains($0) }) ?? true,
              value.extraPerPeriod.map({ PausePolicy.extraRange.contains($0) }) ?? true else { return false }
        if case .wait(let minutes) = value.gate { return PausePolicy.waitRange.contains(minutes) }
        return true
    }
}
#endif
