import Foundation

public struct GoalongSiteSelectionCatalog: Sendable {
    public struct Application: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let seconds: Int
    }
    public struct Device: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let screenSeconds: Int?
        public let applications: [Application]
    }
    public struct Website: Identifiable, Sendable {
        public var id: String { domain }
        public let domain: String
        public let seconds: Int
    }
    public let devices: [Device]
    public let websites: [Website]
    public let timezone: String

    private init(devices: [Device], websites: [Website], timezone: String) {
        self.devices = devices; self.websites = websites; self.timezone = timezone
    }

    /// A copy without the websites the caller must never offer or send.
    public func removingWebsites(where isHidden: (String) -> Bool) -> GoalongSiteSelectionCatalog {
        .init(devices: devices, websites: websites.filter { !isHidden($0.domain) }, timezone: timezone)
    }

    /// A copy without the applications the caller must never offer or send (arguments: id, name).
    public func removingApplications(where isHidden: (String, String) -> Bool) -> GoalongSiteSelectionCatalog {
        .init(devices: devices.map {
            Device(id: $0.id, name: $0.name, kind: $0.kind, screenSeconds: $0.screenSeconds,
                   applications: $0.applications.filter { !isHidden($0.id, $0.name) })
        }, websites: websites, timezone: timezone)
    }

    public init(payload: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let day = (root["days"] as? [[String: Any]])?.first,
              let telemetry = day["telemetry"] as? [String: Any],
              let rows = telemetry["devices"] as? [[String: Any]],
              let timezone = telemetry["timezone"] as? String else {
            throw GoalongSiteExportError.invalid("La liste locale des appareils est indisponible.")
        }
        self.timezone = timezone
        devices = try rows.map { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String,
                  let kind = row["kind"] as? String else {
                throw GoalongSiteExportError.invalid("Un appareil enregistré est incomplet.")
            }
            let apps = (row["apps"] as? [[String: Any]] ?? []).compactMap { app -> Application? in
                guard let id = app["id"] as? String, let name = app["name"] as? String,
                      let seconds = app["seconds"] as? Int else { return nil }
                return Application(id: id, name: name, seconds: seconds)
            }
            return Device(id: id, name: name, kind: kind, screenSeconds: row["screenSeconds"] as? Int, applications: apps)
        }
        websites = ((telemetry["websites"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []).compactMap { row in
            guard let domain = row["domain"] as? String, let seconds = row["seconds"] as? Int else { return nil }
            return Website(domain: domain, seconds: seconds)
        }
    }
}

extension GoalongQueryCLI {
    public static func siteSelectionCatalog(rootDirectory: URL, day: String, includeWebsites: Bool = false) throws -> GoalongSiteSelectionCatalog {
        try GoalongSiteSelectionCatalog(payload: siteExportPayload(rootDirectory: rootDirectory, day: day,
            options: .init(includeApplications: true, includeWebsites: includeWebsites)))
    }
}
