#if os(macOS)
import AppKit
import Foundation
import LocalHistoryCore
import UniformTypeIdentifiers

/// Spreadsheet-ready export of the period shown in Activité: one row per day and
/// application or website. Only names, identifiers and durations already on screen;
/// no window title, URL path or content. Written only where the user chooses.
enum GoalongActivityExport {
    static let header = ["date", "type", "nom", "identifiant", "classement", "secondes_actives",
                         "secondes_travail", "secondes_hors_travail", "secondes_a_classer"]

    static func csv(period: GoalongLocalAnalytics.Period, grouping: GoalongActivityUsageGrouping,
                    rules: GoalongUsageClassificationRules, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var lines = [header.joined(separator: ";")]
        for day in period.days where day.state == .ready && day.activeSeconds > 0 {
            let date = formatter.string(from: day.date)
            for item in GoalongActivityProjection.usage(.init(days: [day]), grouping: grouping) {
                let rule = item.classificationKey.flatMap { key in
                    item.isWebsite ? rules.websites[key] : rules.applications[key]
                }
                let label: String
                switch (rule, item.dominantClass) {
                case (.work?, _): label = "travail"
                case (.other?, _): label = "hors travail"
                case (nil, .work?): label = "travail (auto)"
                case (nil, .other?): label = "hors travail (auto)"
                case (nil, nil): label = "à classer"
                }
                let fields = [date, item.isWebsite ? "site" : "application", item.displayName,
                              item.isWebsite ? item.name : (item.bundleIdentifier ?? ""), label,
                              seconds(item.seconds), seconds(item.workSeconds), seconds(item.otherSeconds),
                              seconds(item.unclassifiedSeconds)]
                lines.append(fields.map(escape).joined(separator: ";"))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    @MainActor static func save(period: GoalongLocalAnalytics.Period, grouping: GoalongActivityUsageGrouping,
                                rules: GoalongUsageClassificationRules) -> String? {
        let panel = NSSavePanel()
        panel.title = "Exporter l’activité"
        panel.message = "Durées par jour et par application ou site. Aucun titre, adresse complète ni contenu."
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let days = period.days
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let range = [days.first, days.last].compactMap { $0.map { formatter.string(from: $0.date) } }
        panel.nameFieldStringValue = "Goalong-activite-\(Set(range).sorted().joined(separator: "_au_")).csv"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // A BOM lets Excel read accents correctly; Numbers and scripts ignore it.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(csv(period: period, grouping: grouping, rules: rules).utf8)
        do {
            try SupportReportWriter.write(data, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            SupportDiagnostics.shared.failure(error, component: .storage)
            return "L’export n’a pas pu être enregistré. Essayez un autre dossier."
        }
    }

    private static func seconds(_ value: TimeInterval) -> String { String(Int(value.rounded())) }

    private static func escape(_ value: String) -> String {
        // Neutralise spreadsheet formulas and quote separators.
        var text = value
        if let first = text.first, "=+-@\t\r".contains(first) { text = "'" + text }
        guard text.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
#endif
