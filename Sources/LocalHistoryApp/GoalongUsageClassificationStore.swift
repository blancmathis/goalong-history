#if os(macOS)
import AppKit
import Foundation
import LocalHistoryCore
import SwiftUI

/// The user's Travail / Hors travail choices for applications and websites. A small
/// private file next to the history; the journals themselves are never rewritten.
@MainActor final class GoalongUsageClassificationStore: ObservableObject {
    static let shared = GoalongUsageClassificationStore()
    static let fileName = "activity-classification.json"

    @Published private(set) var rules: GoalongUsageClassificationRules
    @Published private(set) var lastError: String?
    private let fileURL: URL

    init(fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent(GoalongUsageClassificationStore.fileName)) {
        self.fileURL = fileURL
        rules = Self.load(from: fileURL)
    }

    func verdict(for item: GoalongActivityUsageItem) -> GoalongUsageClass? {
        guard let key = item.classificationKey else { return nil }
        return item.isWebsite ? rules.websites[key] : rules.applications[key]
    }

    /// `nil` removes the rule and restores the automatic classification everywhere.
    func set(_ verdict: GoalongUsageClass?, for item: GoalongActivityUsageItem) {
        guard let key = item.classificationKey else { return }
        var next = rules
        if item.isWebsite { next.websites[key] = verdict } else { next.applications[key] = verdict }
        save(next)
    }

    func set(_ verdict: GoalongUsageClass?, forItems items: [GoalongActivityUsageItem]) {
        var next = rules
        for item in items {
            guard let key = item.classificationKey else { continue }
            if item.isWebsite { next.websites[key] = verdict } else { next.applications[key] = verdict }
        }
        save(next)
    }

    func removeAll() { save(GoalongUsageClassificationRules()) }

    private func save(_ next: GoalongUsageClassificationRules) {
        guard next != rules else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(next)
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            rules = next
            lastError = nil
        } catch {
            SupportDiagnostics.shared.failure(error, component: .storage)
            lastError = "Le classement n’a pas pu être enregistré. Réessayez."
        }
    }

    private static func load(from url: URL) -> GoalongUsageClassificationRules {
        guard let data = try? SupportDiagnostics.readPrivateFile(url, maximum: 4 * 1_024 * 1_024) else {
            return GoalongUsageClassificationRules()
        }
        return (try? JSONDecoder().decode(GoalongUsageClassificationRules.self, from: data)) ?? GoalongUsageClassificationRules()
    }
}

extension GoalongActivityUsageItem {
    /// Same keys as the analytics engine: host for a website, bundle identifier (or name) for an app.
    var classificationKey: String? {
        isWebsite ? GoalongUsageClassificationRules.websiteKey(name)
            : GoalongUsageClassificationRules.applicationKey(bundleIdentifier: bundleIdentifier, name: name)
    }
}

/// Lists every Travail / Hors travail choice so it can be reviewed or undone outside Activité.
@MainActor struct GoalongUsageClassificationSettings: View {
    @ObservedObject private var store = GoalongUsageClassificationStore.shared
    @State private var confirmReset = false

    private struct Rule: Identifiable {
        let id: String
        let name: String
        let isWebsite: Bool
        let verdict: GoalongUsageClass
    }

    private var rules: [Rule] {
        let apps = store.rules.applications.map { Rule(id: "app:" + $0.key, name: Self.appName($0.key), isWebsite: false, verdict: $0.value) }
        let sites = store.rules.websites.map { Rule(id: "site:" + $0.key, name: $0.key, isWebsite: true, verdict: $0.value) }
        return (apps + sites).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        GoalongSettingsGroup(title: "Classement travail") {
            Text(store.rules.isEmpty
                 ? "Aucun classement personnel. Dans Activité, cliquez sur l’étiquette d’une app ou d’un site pour la classer en Travail ou Hors travail."
                 : "Vos choix priment sur le classement automatique et s’appliquent à tout l’historique, sans modifier les journaux.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(rules) { rule in
                HStack(spacing: 10) {
                    Image(systemName: rule.isWebsite ? "globe" : "app").frame(width: 18).foregroundStyle(.secondary)
                    Text(rule.name).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Text(rule.verdict == .work ? "Travail" : "Hors travail").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button {
                        store.set(nil, for: GoalongActivityUsageItem(id: rule.id, name: rule.isWebsite ? rule.name : String(rule.id.dropFirst(4)),
                            bundleIdentifier: rule.isWebsite ? nil : String(rule.id.dropFirst(4)), isWebsite: rule.isWebsite, seconds: 0))
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Revenir au classement automatique")
                        .accessibilityLabel("Retirer le classement de \(rule.name)")
                }
            }
            if !store.rules.isEmpty {
                Button("Tout réinitialiser…") { confirmReset = true }.buttonStyle(.bordered)
            }
        }
        .confirmationDialog("Revenir au classement automatique pour toutes les apps et tous les sites ?", isPresented: $confirmReset) {
            Button("Tout réinitialiser", role: .destructive) { store.removeAll() }
        } message: { Text("Vos journaux ne sont pas modifiés ; seuls vos choix Travail / Hors travail sont effacés.") }
    }

    private static func appName(_ key: String) -> String {
        guard key.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else { return key }
        return url.deletingPathExtension().lastPathComponent
    }
}
#endif
