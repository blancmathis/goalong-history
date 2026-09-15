import Foundation
import LocalHistoryCore

public enum GoalongOutgoingPrivacy {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalHistory", isDirectory: true)
    }
    /// Validates metadata and selected numeric exports without changing reviewed bytes.
    public static func validate(_ payload: Data, root: URL, expectedRevision: String?) throws -> GoalongPrivacyPolicy {
        let policy = GoalongPrivacyPolicy.load(in: root)
        guard !policy.blocked, expectedRevision.map({ $0 == policy.revision }) ?? !policy.hasExclusions else {
            throw GoalongSiteExportError.invalid("Les exclusions ont changé ou doivent être vérifiées. Préparez un nouvel aperçu.")
        }
        guard policy.hasExclusions else { return policy }
        guard let document = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              document["version"] as? Int == 2,
              let days = document["days"] as? [[String: Any]], !days.isEmpty else {
            throw GoalongSiteExportError.invalid("Cet export ne permet pas de vérifier vos exclusions.")
        }
        for day in days {
            guard (day["summary"] as? String ?? "").isEmpty,
                  (day["outcomes"] as? [Any] ?? []).isEmpty,
                  (day["activities"] as? [Any] ?? []).isEmpty,
                  let telemetry = day["telemetry"] as? [String: Any],
                  telemetry["agent"] == nil || telemetry["agent"] is NSNull,
                  let devices = telemetry["devices"] as? [[String: Any]] else {
                throw GoalongSiteExportError.invalid("Les exclusions bloquent les textes et analyses non filtrables.")
            }
            for device in devices {
                guard device["screenSeconds"] == nil || device["screenSeconds"] is NSNull,
                      device["hourly"] == nil || device["hourly"] is NSNull,
                      let apps = device["apps"] as? [[String: Any]] else {
                    throw GoalongSiteExportError.invalid("Un total ou un horaire pourrait contenir de l’activité exclue.")
                }
                guard policy.domains.isEmpty || apps.isEmpty else {
                    throw GoalongSiteExportError.invalid("Les durées Apple ne permettent pas de séparer les sites exclus.")
                }
                for app in apps {
                    guard !policy.excludes(appID: app["id"] as? String, name: app["name"] as? String) else {
                        throw GoalongSiteExportError.invalid("L’aperçu contient une application désormais exclue.")
                    }
                }
            }
            if let sites = telemetry["websites"] as? [String: Any], let rows = sites["rows"] as? [[String: Any]] {
                guard rows.allSatisfy({ ($0["domain"] as? String).map { !policy.excludes(domain: $0) } ?? false }) else {
                    throw GoalongSiteExportError.invalid("L’aperçu contient un site désormais exclu.")
                }
            }
        }
        return policy
    }
}
