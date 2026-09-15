#if os(macOS)
import SwiftUI
import Foundation
import CoreFoundation
import LocalHistoryQueryCLI

/// Read the immutable outgoing bytes, never the editable controls. Unsupported
/// content fails closed rather than hiding an unreviewed field behind a summary.
struct GoalongReadableShareData: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let seconds: Int
    }
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let total: Int?
        let applications: [Row]
        let hourly: [Int?]?
    }
    let date: String
    let devices: [Device]
    let websites: [Row]
    let metadata: [(String, String)]
    static func ==(a: Self, b: Self) -> Bool {
        a.date == b.date && a.devices == b.devices && a.websites == b.websites
            && a.metadata.map { $0.0 + $0.1 } == b.metadata.map { $0.0 + $0.1 }
    }
    init(payload: Data) throws {
        func invalid() -> GoalongSiteExportError { .invalid("Cet aperçu contient des données non reconnues. Aucun envoi n’est autorisé.") }
        func keys(_ object: [String: Any], _ allowed: Set<String>) throws {
            guard Set(object.keys).isSubset(of: allowed) else { throw invalid() }
        }
        func integer(_ value: Any?) throws -> Int? {
            guard let value, !(value is NSNull) else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 90_000, number.doubleValue.rounded() == number.doubleValue else { throw invalid() }
            return number.intValue
        }
        guard payload.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let version = root["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 2,
              let source = root["source"] as? String, source == "goalong-history",
              let days = root["days"] as? [[String: Any]], days.count == 1,
              let day = days.first, let date = day["date"] as? String,
              let telemetry = day["telemetry"] as? [String: Any],
              let rawDevices = telemetry["devices"] as? [[String: Any]], rawDevices.count <= 12 else { throw invalid() }
        try keys(root, ["version", "source", "days"])
        try keys(day, ["date", "title", "summary", "outcomes", "activities", "telemetry"])
        try keys(telemetry, ["timezone", "receivedAt", "state", "devices", "websites", "agent"])
        guard let summary = day["summary"] as? String, summary.isEmpty,
              let outcomes = day["outcomes"] as? [Any], outcomes.isEmpty,
              let activities = day["activities"] as? [Any], activities.isEmpty,
              telemetry["agent"] == nil || telemetry["agent"] is NSNull else { throw invalid() }
        self.date = date
        var metadata: [(String, String)] = [("Date", date), ("Format", "2"), ("Source", source)]
        for (field, label) in [("timezone", "Fuseau"), ("receivedAt", "Date de la source"), ("state", "État de la journée")] {
            if let text = telemetry[field] as? String { metadata.append((label, text)) }
        }
        if let title = day["title"] as? String { metadata.append(("Titre", title)) }
        devices = try rawDevices.map { device in
            try keys(device, ["id", "name", "kind", "source", "provenance", "coverage", "appsCoverage", "screenSeconds", "hourly", "apps"])
            guard let id = device["id"] as? String, let name = device["name"] as? String,
                  let apps = device["apps"] as? [[String: Any]], apps.count <= 200 else { throw invalid() }
            metadata.append(("Identifiant de \(name)", id))
            for field in ["kind", "source", "provenance", "coverage", "appsCoverage"] {
                if let value = device[field] as? String { metadata.append(("\(name) · \(field)", value)) }
            }
            let rows: [Row] = try apps.enumerated().map { index, app in
                try keys(app, ["id", "name", "seconds", "category"])
                guard let appID = app["id"] as? String, let name = app["name"] as? String,
                      let seconds = try integer(app["seconds"]) else { throw invalid() }
                metadata.append(("Identifiant de \(name)", appID))
                if let category = app["category"] as? String { metadata.append(("\(name) · catégorie", category)) }
                return Row(id: "\(id)-\(index)", label: name, seconds: seconds)
            }
            var hours: [Int?]?
            if let values = device["hourly"] as? [Any] {
                guard values.count == 24 else { throw invalid() }
                hours = try values.map { try integer($0) }
            } else if device["hourly"] != nil && !(device["hourly"] is NSNull) { throw invalid() }
            return Device(id: id, name: name, total: try integer(device["screenSeconds"]), applications: rows, hourly: hours)
        }
        var websites: [Row] = []
        if let web = telemetry["websites"] as? [String: Any] {
            try keys(web, ["source", "coverage", "includedInApplicationTotals", "rows"])
            guard let rows = web["rows"] as? [[String: Any]], rows.count <= 200 else { throw invalid() }
            for (index, row) in rows.enumerated() {
                try keys(row, ["domain", "browser", "seconds"])
                guard let name = row["domain"] as? String, let seconds = try integer(row["seconds"]) else { throw invalid() }
                websites.append(Row(id: "web-\(index)", label: name, seconds: seconds))
                if let browser = row["browser"] as? String { metadata.append(("\(name) · navigateur", browser)) }
            }
            for field in ["source", "coverage", "includedInApplicationTotals"] {
                if let value = web[field] { metadata.append(("Sites · \(field)", String(describing: value))) }
            }
        } else if telemetry["websites"] != nil && !(telemetry["websites"] is NSNull) { throw invalid() }
        self.websites = websites
        self.metadata = metadata
    }
}

struct GoalongReadableSharePreview: View {
    let data: GoalongReadableShareData
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(data.devices) { device in
                GoalongSettingsGroup(title: device.name) {
                    if let total = device.total { value("Total de l’appareil", seconds: total) }
                    ForEach(device.applications) { row in value(row.label, seconds: row.seconds) }
                    if device.applications.isEmpty && device.total == nil {
                        Text("Aucune durée de cet appareil n’est transmise.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let hours = device.hourly {
                        DisclosureGroup("Horaires transmis") {
                            ForEach(Array(hours.enumerated()), id: \.offset) { hour, seconds in
                                if let seconds { value(String(format: "%02d:00", hour), seconds: seconds) }
                            }
                        }.font(.system(size: 13))
                    }
                }
            }
            if !data.websites.isEmpty {
                GoalongSettingsGroup(title: "Sites web") { ForEach(data.websites) { row in value(row.label, seconds: row.seconds) } }
            }
            HStack {
                Label("Textes non inclus", systemImage: "text.badge.xmark")
                if !data.devices.contains(where: { $0.hourly != nil }) { Label("Horaires non inclus", systemImage: "clock") }
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            DisclosureGroup("Informations jointes") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(data.metadata.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0).font(.system(size: 12, weight: .medium))
                            Text(item.1).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.padding(.top, 10)
            }.font(.system(size: 13))
        }
    }
    private func value(_ label: String, seconds: Int) -> some View {
        HStack { Text(label).font(.system(size: 14)); Spacer(); Text(Self.duration(seconds)).font(.system(size: 14, weight: .medium)).monospacedDigit() }
    }
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(String(format: "%02d", seconds % 3600 / 60))"
    }
}
#endif
