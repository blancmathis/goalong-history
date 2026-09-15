#if os(macOS)
import SwiftUI
import AppKit
import LocalHistoryCore

extension Notification.Name { static let goalongExclusionsDidChange = Notification.Name("goalong.global.exclusions.changed") }

/// Published settings mirror the persisted policy; collectors read the same policy.
final class GoalongExclusionStore: ObservableObject {
    static let shared = GoalongExclusionStore()
    @Published private(set) var policy: GoalongPrivacyPolicy
    @Published var error: String?
    let root: URL
    init(root: URL = AppPaths.applicationSupportDirectory) { self.root = root; policy = .load(in: root) }
    @discardableResult func update(_ mutation: (inout GoalongPrivacyPolicy) -> Void) -> Bool {
        var next = policy
        guard !next.blocked else { error = "Les exclusions sont illisibles. Ouvrez les diagnostics avant de reprendre."; return false }
        mutation(&next); next.revision = UUID().uuidString; next.effectiveFrom = Date()
        do {
            try next.save(in: root)
            let saved = GoalongPrivacyPolicy.load(in: root)
            guard saved == next else { throw NSError(domain: "GoalongPrivacy", code: 3) }
            GoalongPrivacyPolicyCache.invalidate(in: root)
            policy = saved; error = nil
            Task { @MainActor in
                ChatGPTRecapRuntime.shared.stop()
                GoalongWebsiteAutoSender.shared.stop()
            }
            NotificationCenter.default.post(name: .goalongExclusionsDidChange, object: nil)
            return true
        } catch { self.error = "Modification non appliquée : \(error.localizedDescription)"; return false }
    }
}

struct GoalongApplicationChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor final class GoalongApplicationCatalog: ObservableObject {
    @Published var apps: [GoalongApplicationChoice] = []
    @Published var loading = false
    func load() {
        guard !loading else { return }
        loading = true
        let locations = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        Task {
            let result = await Task.detached(priority: .utility) {
                var found: [String: GoalongApplicationChoice] = [:]
                for location in locations {
                    guard let iterator = FileManager.default.enumerator(at: location, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                    var visited = 0
                    while let url = iterator.nextObject() as? URL {
                        visited += 1
                        if visited > 8000 { break }
                        if url.pathExtension == "app" {
                            iterator.skipDescendants()
                            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                            let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                                ?? url.deletingPathExtension().lastPathComponent
                            found[id.lowercased()] = .init(id: id, name: name)
                        } else if iterator.level > 3 { iterator.skipDescendants() }
                    }
                }
                return Array(found.values)
            }.value
            apps = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loading = false
        }
    }
}

@MainActor struct GoalongApplicationsSettings: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @StateObject private var catalog = GoalongApplicationCatalog()
    @State private var search = ""
    @State private var sites = false
    @State private var excludedOnly = false
    @State private var newDomain = ""
    @State private var domainError: String?
    @State private var pendingDomain: String?
    @State private var notice: String?
    private var apps: [GoalongApplicationChoice] {
        var values = Dictionary(catalog.apps.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for item in model.snapshot.trackedUsage where item.kind == .application {
            if let id = item.bundleIdentifier { values[id.lowercased()] = .init(id: id, name: item.name) }
        }
        for (id, name) in exclusions.policy.applications { values[id.lowercased()] = .init(id: id, name: name) }
        for id in model.appliedSettings.excludedApplicationsText.components(separatedBy: .newlines) where !id.isEmpty && values[id.lowercased()] == nil {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { $0.deletingPathExtension().lastPathComponent } ?? "Application indisponible"
            values[id.lowercased()] = .init(id: id, name: name)
        }
        return values.values.filter { item in
            (search.isEmpty || item.name.localizedStandardContains(search)) && (!excludedOnly || isExcluded(item))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var domains: [String] {
        let observed = model.snapshot.trackedUsage.filter { $0.kind == .website }.compactMap(\.host)
        let old = model.appliedSettings.excludedDomainsText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(Set(observed + exclusions.policy.domains + old)).filter {
            (search.isEmpty || $0.localizedStandardContains(search)) && (!excludedOnly || domainExcluded($0))
        }.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Exclure du suivi détaillé et des prochains envois.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                GoalongHelpButton(text: "Le suivi détaillé et les prochains envois respectent ces exclusions. Les historiques locaux d’Apple et des outils IA restent séparés ; ils ne sont pas effacés. Les textes et totaux impossibles à filtrer sont bloqués. Une ancienne exclusion limitée au suivi détaillé est indiquée comme telle.")
            }
            Picker("Type", selection: $sites) { Text("Applications").tag(false); Text("Sites web").tag(true) }.pickerStyle(.segmented)
            HStack {
                TextField("Rechercher par nom…", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Exclusions", isOn: $excludedOnly).toggleStyle(.checkbox).fixedSize()
            }
            if sites {
                HStack {
                    TextField("Ajouter un site · exemple.fr", text: $newDomain).textFieldStyle(.roundedBorder).onSubmit(addDomain)
                    Button("Exclure", action: addDomain).disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let domainError { Text(domainError).font(.system(size: 12)).foregroundStyle(LHTheme.warning) }
            }
            LHCard(padding: 0) {
                LazyVStack(spacing: 0) {
                    if sites {
                        if domains.isEmpty { empty }
                        ForEach(domains, id: \.self) { domain in
                            HStack(spacing: 12) {
                                Image(systemName: "globe").frame(width: 30).foregroundStyle(.secondary)
                                Text(domain).font(.system(size: 14))
                                Spacer()
                                Text(domainExcluded(domain) ? "Exclu" : "Autorisé").font(.system(size: 12)).foregroundStyle(.secondary)
                                Toggle("Autoriser \(domain)", isOn: Binding(get: { !domainExcluded(domain) }, set: { setDomain(domain, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch)
                            }.padding(14)
                            Divider().padding(.leading, 55)
                        }
                    } else {
                        if catalog.loading { ProgressView("Applications installées…").padding(18) }
                        if apps.isEmpty && !catalog.loading { empty }
                        ForEach(apps) { app in
                            HStack(spacing: 12) {
                                AppIconView(bundleIdentifier: app.id, appName: app.name, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.system(size: 14, weight: .medium))
                                    if model.isApplicationExcludedFromCapture(app.id) && !exclusions.policy.excludes(appID: app.id) {
                                        Text("Exclue de l’enregistrement détaillé").font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if exclusions.policy.excludes(appID: app.id) { Text("Exclue").font(.system(size: 12)).foregroundStyle(.secondary) }
                                Toggle("Autoriser \(app.name)", isOn: Binding(get: { !isExcluded(app) }, set: { setApp(app, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch).disabled(app.id == ProductIdentity.bundleIdentifier)
                            }.padding(14)
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
            if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
            DisclosureGroup("Règles avancées d’enregistrement") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Les anciennes listes « autoriser uniquement » restent conservées.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Ouvrir la configuration") { model.openConfiguration() }.buttonStyle(.bordered)
                }.padding(.top, 10)
            }.font(.system(size: 13))
        }
        .onAppear { catalog.load() }
        .alert("Reconnaître ce site pour l’exclure ?", isPresented: Binding(get: { pendingDomain != nil }, set: { if !$0 { pendingDomain = nil } })) {
            Button("Annuler", role: .cancel) { pendingDomain = nil }
            Button("Exclure le site") {
                guard let domain = pendingDomain else { return }
                if exclusions.update({ $0.inspectDomainsForExclusions = true; if !$0.domains.contains(domain) { $0.domains.append(domain) } }) {
                    pendingDomain = nil; newDomain = ""; notice = "Site exclu. Les anciennes données sont conservées."
                }
            }
        } message: { Text("Goalong lira le nom du site pour appliquer vos exclusions, sans conserver l’adresse complète si son enregistrement est désactivé.") }
        .alert("Exclusion non modifiée", isPresented: Binding(get: { exclusions.error != nil }, set: { if !$0 { exclusions.error = nil } })) {
            Button("Fermer", role: .cancel) {}
        } message: { Text(exclusions.error ?? "") }
    }
    private var empty: some View { Text("Aucun résultat").font(.system(size: 13)).foregroundStyle(.secondary).padding(24) }
    private func isExcluded(_ app: GoalongApplicationChoice) -> Bool { exclusions.policy.excludes(appID: app.id) || model.isApplicationExcludedFromCapture(app.id) }
    private func domainExcluded(_ domain: String) -> Bool { exclusions.policy.excludes(domain: domain) || model.isDomainExcludedFromCapture(domain) }
    private func setApp(_ app: GoalongApplicationChoice, enabled: Bool) {
        if enabled {
            if exclusions.update({ $0.applications.removeValue(forKey: app.id) }) {
                model.setApplicationCaptureEnabled(true, bundleIdentifier: app.id)
            }
        } else {
            guard exclusions.update({ $0.applications[app.id] = app.name }) else { notice = nil; return }
        }
        guard exclusions.error == nil else { notice = nil; return }
        notice = enabled ? "Autorisation modifiée pour la suite." : "Application exclue. Les anciennes données sont conservées."
    }
    private func setDomain(_ domain: String, enabled: Bool) {
        if enabled {
            if exclusions.update({ $0.domains.removeAll { $0 == domain } }) { model.setDomainCaptureEnabled(true, host: domain) }
        } else if !exclusions.policy.inspectDomainsForExclusions { pendingDomain = domain }
        else { _ = exclusions.update { if !$0.domains.contains(domain) { $0.domains.append(domain) } } }
    }
    private func addDomain() {
        do {
            let list = try PrivacyScopeInput.domains(newDomain)
            guard list.count == 1, let domain = list.first else { domainError = "Ajoutez un site à la fois."; return }
            domainError = nil; setDomain(domain, enabled: false)
            if pendingDomain == nil { newDomain = "" }
        } catch { domainError = "Saisissez un site, par exemple exemple.fr." }
    }
}
#endif
#if os(macOS)
@MainActor struct GoalongOnboardingExclusions: View {
    @ObservedObject var model: DashboardViewModel
    @State private var appText = ""
    @State private var website = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApplicationScopePickerButton(text: $appText)
                .onChange(of: appText) { value in
                    let existing = model.settingsDraft.excludedApplicationsText.components(separatedBy: .newlines)
                    model.settingsDraft.excludedApplicationsText = Array(Set(existing + value.components(separatedBy: .newlines))).filter { !$0.isEmpty }.sorted().joined(separator: "\n")
                    message = "Applications exclues de l’enregistrement détaillé."
                }
            HStack {
                TextField("Site à exclure · exemple.fr", text: $website).textFieldStyle(.roundedBorder)
                Button("Ajouter") {
                    do {
                        let domains = try PrivacyScopeInput.domains(website)
                        let existing = model.settingsDraft.excludedDomainsText.components(separatedBy: .newlines)
                        model.settingsDraft.excludedDomainsText = Array(Set(existing + domains)).filter { !$0.isEmpty }.sorted().joined(separator: "\n")
                        website = ""; message = "Site exclu. Sans lecture des adresses, le navigateur entier est exclu."
                    } catch { message = "Saisissez un site valide." }
                }.disabled(website.isEmpty)
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}
#endif
