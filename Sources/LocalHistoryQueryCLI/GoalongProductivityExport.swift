import Foundation
import CryptoKit

/// An editable, offline report envelope. Semantic classification is deliberately
/// unknown until a person or an explicitly chosen agent interprets the context.
public enum GoalongProductivityExport {
    public static func payload(fromSelectedSiteExport data: Data) throws -> Data {
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              input["version"] as? Int == 2,
              let days = input["days"] as? [[String: Any]] else {
            throw GoalongSiteExportError.invalid("Prepare a Goalong website v2 export first.")
        }
        let converted: [[String: Any]] = try days.map { day in
            guard let date = day["date"] as? String,
                  let telemetry = day["telemetry"] as? [String: Any],
                  let timezone = telemetry["timezone"] as? String,
                  let devices = telemetry["devices"] as? [[String: Any]] else {
                throw GoalongSiteExportError.invalid("The selected export has no device measurements.")
            }
            var budgets = [[String: Any]](), activities = [[String: Any]]()
            for device in devices {
                guard let deviceID = device["id"] as? String, let name = device["name"] as? String else { continue }
                let source = device["source"] as? String ?? "apple-screen-time"
                let ref = "\(source):\(deviceID)"
                let apps = device["apps"] as? [[String: Any]] ?? []
                var accounted = 0
                func add(_ seconds: Int, app: String?, appID: String) {
                    let identity = "\(ref):\(appID)"
                    let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
                    let budgetID = "duration-\(digest)"
                    var budget: [String: Any] = ["id": budgetID, "device_ref": ref,
                        "device_name": name, "device_kind": device["kind"] ?? "computer",
                        "basis": "application_usage", "seconds": seconds]
                    if let app { budget["application"] = app }
                    budgets.append(budget)
                    if seconds > 0 {
                        var activity: [String: Any] = ["id": "activity-\(digest)", "duration_ref": budgetID,
                            "seconds": seconds, "description": app.map { "Utilisation de \($0), contexte à préciser" } ?? "Activité sans détail d’application",
                            "category": NSNull(), "context": "unspecified", "semantic_origin": "deterministic", "productive_proposal": "unknown"]
                        if let app { activity["application"] = app }
                        activities.append(activity)
                    }
                }
                for app in apps {
                    guard let seconds = app["seconds"] as? Int, seconds >= 0,
                          let appName = app["name"] as? String, let appID = app["id"] as? String else { continue }
                    accounted += seconds
                    add(seconds, app: appName, appID: appID)
                }
                if let total = device["screenSeconds"] as? Int, total > accounted || (total == 0 && apps.isEmpty) {
                    add(max(0, total - accounted), app: nil, appID: "remainder")
                }
            }
            guard budgets.count <= 200 else { throw GoalongSiteExportError.invalid("Select fewer devices or applications: structured reports allow 200 duration sources per day.") }
            let completed = telemetry["state"] as? String == "completed"
            let complete = completed && !devices.isEmpty && devices.allSatisfy { $0["coverage"] as? String == "complete" }
            let summary = day["summary"] as? String ?? ""
            return ["date": date, "timezone": timezone, "state": completed ? "closed" : "in-progress",
                    "coverage": ["scope": "day", "day_accounting": complete ? "complete" : "partial"],
                    "telemetry": telemetry, "duration_budgets": budgets, "activities": activities,
                    "report": ["id": "report-\(date)", "revision": 1,
                               "producer_claim": ["kind": "deterministic", "name": "Goalong History"],
                               "summary": summary.isEmpty ? "Durées sélectionnées. Les activités restent à qualifier selon leur contexte." : summary,
                               "sections": [], "uncertainties": ["Les durées des applications peuvent se chevaucher.", "Le premier plan ne prouve ni l’attention ni l’achèvement d’une tâche."]]]
        }
        let output: [String: Any] = ["version": 3, "source": ["kind": "goalong-history", "instance_id": "native-analysis"], "days": converted]
        let result = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        guard result.count <= 2 * 1024 * 1024 else { throw GoalongSiteExportError.invalid("The selected report exceeds 2 MiB.") }
        return result + Data("\n".utf8)
    }
}
