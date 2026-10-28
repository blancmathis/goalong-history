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
        mutation(&next)
        // A mutation that changes nothing must not bump the revision, stop the senders or notify.
        if next == policy { error = nil; return true }
        next.revision = UUID().uuidString; next.effectiveFrom = Date()
        do {
            try next.save(in: root)
            let saved = GoalongPrivacyPolicy.load(in: root)
            guard saved == next else { throw NSError(domain: "GoalongPrivacy", code: 3) }
            GoalongPrivacyPolicyCache.invalidate(in: root)
            policy = saved; error = nil
            Task { @MainActor in
                ChatGPTRecapRuntime.shared.stop()
                // A running plan pauses with its cause; a plan the user paused keeps its state.
                let sender = GoalongWebsiteAutoSender.shared
                if sender.enabled { sender.stop(reason: GoalongWebsiteAutoSender.exclusionsChangedReason) }
            }
            NotificationCenter.default.post(name: .goalongExclusionsDidChange, object: nil)
            return true
        } catch { self.error = "Modification non appliquée : \(GoalongUserFacingError.message(error))"; return false }
    }
}

struct GoalongApplicationChoice: Identifiable, Equatable {
    let id: String
    let name: String
    /// False for an exclusion whose application is not on this Mac (e.g. a default password manager).
    var installed = true
}

/// Readable names for the protected applications excluded by default, even when absent.
enum GoalongKnownApplications {
    static let names: [String: String] = [
        "com.apple.passwords": "Mots de passe",
        "com.apple.keychainaccess": "Trousseau d’accès",
        "com.agilebits.onepassword7": "1Password 7",
        "com.1password.1password": "1Password",
        "com.bitwarden.desktop": "Bitwarden",
        "com.lastpass.lastpass": "LastPass",
        "com.dashlane.dashlane": "Dashlane",
        "org.keepassxc.keepassxc": "KeePassXC",
        "in.sinew.enpass-desktop": "Enpass",
        "com.callpod.keepermac": "Keeper",
        "org.torproject.torbrowser": "Tor Browser",
        "net.mullvad.mullvadbrowser": "Mullvad Browser",
        "com.apple.safaritechnologypreview.passwords": "Mots de passe (Safari Technology Preview)",
    ]
    static func name(for bundleIdentifier: String) -> String? { names[bundleIdentifier.lowercased()] }
    static func isDefaultExclusion(_ bundleIdentifier: String) -> Bool {
        RecorderConfig.default.excludedBundleIdentifiers.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }
}

@MainActor final class GoalongApplicationCatalog: ObservableObject {
    @Published var apps: [GoalongApplicationChoice] = []
    @Published var loading = false
    #if DEBUG
    /// Test gallery only: a fixed, invented list instead of this Mac's installed apps.
    static var galleryApplications: [GoalongApplicationChoice]?
    #endif
    func load() {
        guard !loading else { return }
        #if DEBUG
        if let fixed = Self.galleryApplications {
            apps = fixed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return
        }
        #endif
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
        for (id, name) in exclusions.policy.applications where values[id.lowercased()] == nil {
            values[id.lowercased()] = Self.choice(id: id, storedName: name)
        }
        for id in model.appliedSettings.excludedApplicationsText.components(separatedBy: .newlines) where !id.isEmpty && values[id.lowercased()] == nil {
            values[id.lowercased()] = Self.choice(id: id, storedName: nil)
        }
        // Absent applications (default password-manager exclusions…) only clutter the
        // list of this Mac's apps; they stay listed under Exclusions and in search.
        return values.values.filter { item in
            (search.isEmpty || item.name.localizedStandardContains(search) || item.id.localizedStandardContains(search))
                && (!excludedOnly || isExcluded(item))
                && (item.installed || excludedOnly || !search.isEmpty)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func choice(id: String, storedName: String?) -> GoalongApplicationChoice {
        #if DEBUG
        // Test gallery: an app is installed when the invented list has it; LaunchServices is never asked.
        if let fixed = GoalongApplicationCatalog.galleryApplications {
            if let app = fixed.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
                return .init(id: id, name: storedName ?? app.name)
            }
            return .init(id: id, name: storedName ?? GoalongKnownApplications.name(for: id) ?? id, installed: false)
        }
        #endif
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return .init(id: id, name: storedName ?? url.deletingPathExtension().lastPathComponent)
        }
        return .init(id: id, name: storedName ?? GoalongKnownApplications.name(for: id) ?? id, installed: false)
    }
    private var domains: [String] {
        let observed = model.snapshot.trackedUsage.filter { $0.kind == .website }.compactMap(\.host)
        let old = model.appliedSettings.excludedDomainsText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(Set(observed + exclusions.policy.domains + old)).filter {
            (search.isEmpty || $0.localizedStandardContains(search)) && (!excludedOnly || domainExcluded($0))
        }.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                Text("Désactivez une app ou un site pour l’exclure du suivi détaillé et des prochains envois.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                GoalongHelpButton(text: "Le suivi détaillé et les prochains envois respectent ces exclusions. Les historiques locaux d’Apple et des outils IA restent séparés ; ils ne sont pas effacés. Les textes et totaux impossibles à filtrer sont bloqués. Une ancienne exclusion limitée au suivi détaillé est indiquée comme telle.")
            }
            GoalongSegmentedControl("Type", selection: $sites, options: [false, true], fills: true) { $0 ? "Sites web" : "Applications" }
            HStack {
                GoalongSearchField("Rechercher par nom…", text: $search)
                Toggle("Exclusions seulement", isOn: $excludedOnly).toggleStyle(.goalongCheckbox).fixedSize()
            }
            if sites {
                HStack {
                    TextField("Ajouter un site · exemple.fr", text: $newDomain).textFieldStyle(GoalongFieldStyle()).onSubmit(addDomain)
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
                                Image(systemName: "globe").font(.system(size: 13)).frame(width: 24).foregroundStyle(LHTheme.secondaryText)
                                Text(domain).font(.system(size: 13, weight: .medium))
                                Spacer()
                                let parent = parentRule(for: domain)
                                Text(parent.map { "Exclu par \($0)" } ?? (domainExcluded(domain) ? "Exclu" : "Autorisé"))
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                Toggle("Autoriser \(domain)", isOn: Binding(get: { !domainExcluded(domain) }, set: { setDomain(domain, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.goalongSwitchOnly).controlSize(.small)
                                    .disabled(parent != nil)
                                    .help(parent.map { "Pour autoriser ce site, retirez d’abord la règle « \($0) » : elle autoriserait aussi ses autres sous-domaines." } ?? "")
                            }.padding(.horizontal, LHTheme.cardInset).frame(minHeight: 44)
                            if domain != domains.last { GoalongRowDivider(inset: LHTheme.cardInset + 36) }
                        }
                    } else {
                        if catalog.loading { ProgressView("Applications installées…").padding(18) }
                        if apps.isEmpty && !catalog.loading { empty }
                        ForEach(apps) { app in
                            HStack(spacing: 12) {
                                AppIconView(bundleIdentifier: app.id, appName: app.name, size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.system(size: 13, weight: .medium))
                                    if !app.installed {
                                        Text(GoalongKnownApplications.isDefaultExclusion(app.id)
                                             ? "Non installée · protégée par défaut" : "Non installée sur ce Mac")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    } else if model.isApplicationExcludedFromCapture(app.id) && !exclusions.policy.excludes(appID: app.id) {
                                        Text("Exclue de l’enregistrement").font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if exclusions.policy.excludes(appID: app.id) { Text("Exclue").font(.system(size: 12)).foregroundStyle(.secondary) }
                                Toggle("Autoriser \(app.name)", isOn: Binding(get: { !isExcluded(app) }, set: { setApp(app, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.goalongSwitchOnly).controlSize(.small)
                                    .disabled(ProductIdentity.isGoalong(app.id))
                            }.padding(.horizontal, LHTheme.cardInset).frame(minHeight: 44)
                            if app.id != apps.last?.id { GoalongRowDivider(inset: LHTheme.cardInset + 36) }
                        }
                    }
                }
            }
            if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
            GoalongDisclosureGroup("Règles avancées d’enregistrement") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Les anciennes listes « autoriser uniquement » restent conservées.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Ouvrir la configuration") { model.openConfiguration() }.buttonStyle(LHSecondaryButtonStyle())
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
    /// The rule, other than the host itself, that excludes this host (« example.fr » for docs.example.fr).
    /// Same matching as `URLRedactor.domain`: lowercase, surrounding dots and spaces trimmed, suffix after a dot.
    nonisolated static func parentDomainRule(for host: String, in rules: [String]) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return rules.lazy.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .first { !$0.isEmpty && host.hasSuffix("." + $0) }
    }
    private func parentRule(for domain: String) -> String? {
        let draft = model.settingsDraft.excludedDomainsText.components(separatedBy: .newlines)
        let applied = model.appliedSettings.excludedDomainsText.components(separatedBy: .newlines)
        return Self.parentDomainRule(for: domain, in: exclusions.policy.domains + draft + applied)
    }
    private func domainExcluded(_ domain: String) -> Bool { exclusions.policy.excludes(domain: domain) || model.isDomainExcludedFromCapture(domain) }
    private func setApp(_ app: GoalongApplicationChoice, enabled: Bool) {
        if enabled {
            if exclusions.update({ policy in
                policy.applications.keys.filter { $0.caseInsensitiveCompare(app.id) == .orderedSame }
                    .forEach { policy.applications.removeValue(forKey: $0) }
            }) {
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
            if let parent = parentRule(for: domain) {
                notice = "Ce site est exclu par la règle « \(parent) ». Retirez cette règle pour l’autoriser."
                return
            }
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
/// Pure list edits for the onboarding exclusions (unit-tested).
enum GoalongOnboardingExclusionEdit {
    static func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).filter { !$0.isEmpty } }
    static func merged(_ text: String, adding values: [String]) -> String {
        Array(Set(lines(text) + values.filter { !$0.isEmpty })).sorted().joined(separator: "\n")
    }
    static func removing(_ value: String, from text: String) -> String {
        lines(text).filter { $0 != value }.joined(separator: "\n")
    }
    /// Adds the typed site(s) to the draft. Throws when the text is not a valid site.
    static func addDomains(_ input: String, to settings: inout DashboardSettingsDraft) throws {
        let domains = try PrivacyScopeInput.domains(input)
        settings.excludedDomainsText = merged(settings.excludedDomainsText, adding: domains)
    }
    /// Items of `current` that are not in `baseline` (what the user added; default exclusions are never listed).
    static func added(current: String, baseline: String) -> [String] {
        let base = Set(lines(baseline))
        return lines(current).filter { !base.contains($0) }
    }
    enum PendingWebsiteResult: Equatable { case nothingPending, added, invalid }
    /// Validation step of « Valider mes choix »: a typed site is added to the draft; an invalid one blocks and is kept.
    static func commitPendingWebsite(_ pending: inout String, to settings: inout DashboardSettingsDraft) -> PendingWebsiteResult {
        guard !pending.trimmingCharacters(in: .whitespaces).isEmpty else { return .nothingPending }
        do { try addDomains(pending, to: &settings); pending = ""; return .added } catch { return .invalid }
    }
}

@MainActor struct GoalongOnboardingExclusions: View {
    @ObservedObject var model: DashboardViewModel
    /// Owned by the onboarding so a site typed but not yet added is not lost when « Valider mes choix » is pressed.
    @Binding var website: String
    @State private var appText = ""
    @State private var message: String?
    private static let defaults = DashboardSettingsDraft(config: .default)
    private var domains: [String] {
        GoalongOnboardingExclusionEdit.added(current: model.settingsDraft.excludedDomainsText, baseline: Self.defaults.excludedDomainsText)
    }
    private var applications: [String] {
        GoalongOnboardingExclusionEdit.added(current: model.settingsDraft.excludedApplicationsText, baseline: Self.defaults.excludedApplicationsText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApplicationScopePickerButton(text: $appText)
                .onChange(of: appText) { value in
                    let picked = value.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    guard !picked.isEmpty else { return }
                    appText = ""
                    model.settingsDraft.excludedApplicationsText = GoalongOnboardingExclusionEdit.merged(
                        model.settingsDraft.excludedApplicationsText, adding: picked)
                    announce("Application ajoutée à la liste d’exclusion.")
                }
            HStack {
                TextField("Site à exclure · exemple.fr", text: $website).textFieldStyle(GoalongFieldStyle())
                    .onSubmit { add() }
                Button("Ajouter") { add() }.disabled(website.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(applications + domains, id: \.self) { item in
                HStack {
                    Text(item).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Retirer") { remove(item) }.buttonStyle(.plain).foregroundStyle(LHTheme.secondaryText)
                        .accessibilityLabel("Retirer \(item) des exclusions")
                }
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
    private func announce(_ text: String) {
        message = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text])
    }
    private func remove(_ item: String) {
        model.settingsDraft.excludedApplicationsText = GoalongOnboardingExclusionEdit.removing(item, from: model.settingsDraft.excludedApplicationsText)
        model.settingsDraft.excludedDomainsText = GoalongOnboardingExclusionEdit.removing(item, from: model.settingsDraft.excludedDomainsText)
        announce("Exclusion retirée.")
    }
    private func add() {
        guard !website.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try GoalongOnboardingExclusionEdit.addDomains(website, to: &model.settingsDraft)
            website = ""
            announce(model.settingsDraft.captureURLs
                ? "Site ajouté. Il sera exclu une fois vos choix validés."
                : "Site ajouté. La lecture des adresses est désactivée : le navigateur entier sera exclu une fois vos choix validés.")
        } catch { announce("Saisissez un site comme exemple.fr, sans espace ni chemin.") }
    }
}
#endif
