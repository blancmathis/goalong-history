#if os(macOS)
import AppKit
import SwiftUI
import LocalHistoryCore
import LocalHistoryQueryCLI

@MainActor struct GoalongWebsiteSharingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GoalongWebsiteSharingModel
    @ObservedObject private var autoSender: GoalongWebsiteAutoSender
    @AppStorage("goalong.website.origin") private var origin = ""
    @AppStorage("goalong.website.tokenFilePath") private var tokenPath = ""
    @State private var exactData = false
    @State private var advanced = false
    @State private var appSearch = ""

    init(model: GoalongWebsiteSharingModel? = nil, initialDay: Date? = nil) {
        let resolved = model ?? GoalongWebsiteSharingModel()
        if let initialDay { resolved.presentSingleDay(initialDay) }
        _model = StateObject(wrappedValue: resolved)
        _autoSender = ObservedObject(wrappedValue: resolved.autoSender)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Envoyer à Goalong").font(.system(size: 24, weight: .semibold))
                    Text(model.preview == nil ? "1. Choisir les données" : "2. Vérifier l’envoi")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy).accessibilityIdentifier("sharing-close")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    account
                    if let approved = model.preview {
                        preview(approved)
                    } else {
                        delivery
                        selection
                    }
                    if autoSender.savedConfiguration != nil {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(autoSender.enabled ? "Envoi quotidien activé" : "Envoi quotidien en pause").font(.system(size: 13, weight: .medium))
                                if let day = autoSender.lastSuccess { Text("Dernière journée reçue : \(day)").font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if autoSender.enabled { Button("Mettre en pause") { autoSender.stop() }.buttonStyle(.bordered) }
                            GoalongHelpButton(text: autoSender.status)
                        }
                    }
                    if let status = model.status {
                        Label(status, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(LHTheme.success)
                            .accessibilityIdentifier("sharing-success")
                        Button("Voir la journée sur le site") { openSite(fragment: "history") }.buttonStyle(.bordered)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("sharing-error")
                    }
                    if model.preview == nil {
                        GoalongDisclosureGroup("Outils avancés") {
                            Button("Récap relu ou connexion manuelle…") { advanced = true }.buttonStyle(.bordered).padding(.top, 10)
                        }.font(.system(size: 13))
                    }
                }.padding(24)
            }.disabled(model.busy)
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 840, maxWidth: 980, minHeight: 560, idealHeight: 760, maxHeight: 900)
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .environment(\.locale, Locale(identifier: "fr_FR"))
        .environment(\.timeZone, sharingCalendar.timeZone)
        .environment(\.calendar, sharingCalendar)
        .interactiveDismissDisabled(model.busy)
        .task { if model.catalog == nil { await model.loadCatalog() } }
        .onChange(of: model.draft.date) { _ in Task { await model.loadCatalog() } }
        .onChange(of: model.draft.includeWebsites) { _ in Task { await model.loadCatalog() } }
        .onReceive(NotificationCenter.default.publisher(for: .goalongWebsiteConnected)) { _ in model.connectionChanged() }
        .onChange(of: origin) { _ in model.connectionChanged() }
        .onChange(of: tokenPath) { _ in model.connectionChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .goalongExclusionsDidChange)) { _ in model.connectionChanged(); Task { await model.loadCatalog() } }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in
            model.cancelPreparation()
            if !GoalongGlobalPause.isPaused() { Task { await model.loadCatalog() } }
        }
        .onDisappear { model.cancelPreparation() }
        .sheet(isPresented: $advanced) { GoalongWebsiteConnectionSheet() }
    }
    private var account: some View {
        GoalongSettingsGroup(title: "Destination") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connected ? "Votre compte Goalong" : "Compte non relié").font(.system(size: 14, weight: .medium))
                    Text(connected ? (URL(string: origin)?.host ?? "Liaison enregistrée") : "Relier le compte ne transmet aucune activité.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(connected ? "Règles du site" : "Relier mon compte") { openSite(fragment: connected ? "privacy" : "settings") }
                    .buttonStyle(.bordered)
            }
            if connected {
                Text("Visibilité : vos règles du site s’appliquent après l’envoi.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var connected: Bool { !tokenPath.isEmpty && !origin.isEmpty }
    private var delivery: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Fréquence", selection: $model.draft.delivery) {
                Text("Une fois").tag(GoalongWebsiteShareDraft.Delivery.once)
                Text("Chaque jour").tag(GoalongWebsiteShareDraft.Delivery.daily)
            }.pickerStyle(.segmented).accessibilityIdentifier("sharing-delivery")
            if model.draft.delivery == .daily {
                HStack {
                    DatePicker("La veille, après", selection: scheduleTime, displayedComponents: .hourAndMinute).datePickerStyle(.field)
                    Spacer()
                    GoalongHelpButton(text: "Fuseau : \(model.draft.timezone). L’envoi se fait lorsque Goalong est ouvert et le Mac connecté. Seule la veille est envoyée. Les journées plus anciennes ne sont pas rattrapées. La sélection ne s’élargit jamais automatiquement.")
                }
                Text("Nouvelles applications, nouveaux sites et textes exclus.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var sharingCalendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: model.draft.timezone) ?? .current; return value
    }
    private var scheduleTime: Binding<Date> {
        Binding(get: { sharingCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: model.draft.hour, minute: model.draft.minute)) ?? Date() },
                set: { model.draft.hour = sharingCalendar.component(.hour, from: $0); model.draft.minute = sharingCalendar.component(.minute, from: $0) })
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 18) {
            DatePicker(model.draft.delivery == .daily ? "Journée d’exemple" : "Journée à envoyer", selection: $model.draft.date,
                       in: ...Date(), displayedComponents: .date).datePickerStyle(.field)
                .accessibilityIdentifier("sharing-selected-date")
            if model.loading {
                ProgressView("Lecture sur ce Mac…").font(.system(size: 13))
            } else if let catalog = model.catalog {
                GoalongSettingsGroup(title: "Appareils") {
                    GoalongSharingSelector(title: "Choisir les appareils", symbol: "desktopcomputer", items: catalog.devices.map {
                        .init(id: $0.id, title: $0.name, detail: $0.screenSeconds.map(GoalongReadableSharePreview.duration) ?? "Durée non transmise",
                              symbol: $0.kind == "phone" ? "iphone" : $0.kind == "tablet" ? "ipad" : "desktopcomputer")
                    }, selection: $model.draft.deviceIDs)
                }
                GoalongSettingsGroup(title: "Applications") {
                    Toggle("Inclure des applications", isOn: $model.draft.includeApplications).toggleStyle(.switch)
                    if model.draft.includeApplications { applicationChoices }
                }
                GoalongSettingsGroup(title: "Sites web") {
                    Toggle("Inclure des sites", isOn: $model.draft.includeWebsites).toggleStyle(.switch)
                        .disabled(!model.draft.anonymousApplicationIDs.intersection(model.draft.applicationIDs).isEmpty)
                    if model.draft.includeWebsites {
                        if catalog.websites.isEmpty && !model.draft.applicationIDs.isEmpty {
                            Text("Aucun site pour cette journée. L’aperçu des applications reste disponible.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        GoalongSharingSelector(title: "Domaines uniquement", symbol: "globe", items: catalog.websites.map {
                            .init(id: $0.domain, title: $0.domain, detail: GoalongReadableSharePreview.duration($0.seconds))
                        }, selection: $model.draft.websiteDomains)
                    }
                    if !model.draft.anonymousApplicationIDs.intersection(model.draft.applicationIDs).isEmpty {
                        Text("Les domaines sont retirés pour préserver le masquage des applications.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                GoalongDisclosureGroup("Nom des appareils") {
                    Toggle("Inclure leurs noms personnels", isOn: $model.draft.includeDeviceNames).toggleStyle(.checkbox).padding(.top, 10)
                }.font(.system(size: 13))
                Text("Les textes ne sont pas inclus. Les adresses locales ou non valides sont ignorées.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Aucune donnée disponible pour cette journée.").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("Réessayer") { Task { await model.loadCatalog() } }.buttonStyle(.bordered)
            }
        }
    }
    private var availableApps: [GoalongSiteSelectionCatalog.Application] {
        var rows: [String: GoalongSiteSelectionCatalog.Application] = [:]
        for device in model.catalog?.devices ?? [] where model.draft.deviceIDs.contains(device.id) {
            for app in device.applications { rows[app.id] = app }
        }
        return rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var applicationChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if availableApps.count > 5 { TextField("Rechercher une application…", text: $appSearch).textFieldStyle(.roundedBorder) }
            if availableApps.isEmpty { Text("Choisissez un appareil disposant de données.").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Button("Sélectionner les résultats") {
                    model.draft.applicationIDs.formUnion(availableApps.filter { appSearch.isEmpty || $0.name.localizedStandardContains(appSearch) }.map(\.id))
                }
                Button("Tout exclure") { model.draft.applicationIDs.removeAll(); model.draft.anonymousApplicationIDs.removeAll() }
            }.buttonStyle(.borderless).font(.system(size: 12))
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(availableApps.filter { appSearch.isEmpty || $0.name.localizedStandardContains(appSearch) }) { app in
                        HStack(spacing: 12) {
                            AppIconView(bundleIdentifier: app.id, appName: app.name, size: 28)
                            Text(app.name).font(.system(size: 13)).lineLimit(2)
                            Spacer()
                            Picker("Envoi de \(app.name)", selection: Binding(get: {
                                !model.draft.applicationIDs.contains(app.id) ? 0 : model.draft.anonymousApplicationIDs.contains(app.id) ? 1 : 2
                            }, set: { choice in
                                if choice == 0 { model.draft.applicationIDs.remove(app.id); model.draft.anonymousApplicationIDs.remove(app.id) }
                                else {
                                    model.draft.applicationIDs.insert(app.id)
                                    if choice == 1 { model.draft.anonymousApplicationIDs.insert(app.id); model.draft.includeWebsites = false }
                                    else { model.draft.anonymousApplicationIDs.remove(app.id) }
                                }
                            })) {
                                Text("Ne rien envoyer").tag(0)
                                Text("Durée sans nom").tag(1)
                                Text("Nom et durée").tag(2)
                            }.labelsHidden().frame(width: 168)
                        }.padding(.vertical, 3)
                    }
                }
            }.frame(maxHeight: 230)
            let absent = model.draft.applicationIDs.subtracting(Set(availableApps.map(\.id)))
            if !absent.isEmpty {
                HStack {
                    Text("\(absent.count) choix d’autres journées conservés").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retirer") { model.draft.applicationIDs.subtract(absent); model.draft.anonymousApplicationIDs.subtract(absent) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
    private func preview(_ approved: GoalongWebsiteSharingModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Aperçu local du \(approved.draft.day)").font(.system(size: 14, weight: .medium))
                Spacer()
                Button("Modifier") { model.invalidate() }.buttonStyle(.bordered)
            }
            if let data = try? GoalongReadableShareData(payload: approved.payload) {
                GoalongReadableSharePreview(data: data)
            } else {
                Label("Aperçu non lisible. L’envoi est bloqué.", systemImage: "exclamationmark.circle").foregroundStyle(LHTheme.warning)
            }
            if model.draft.delivery == .daily {
                Toggle("J’autorise ces données chaque jour, sans élargir la sélection.", isOn: $model.reviewed)
                    .toggleStyle(.checkbox).font(.system(size: 13)).accessibilityIdentifier("sharing-confirm-review")
            }
            GoalongDisclosureGroup("Données techniques", isExpanded: $exactData) {
                ScrollView([.horizontal, .vertical]) {
                    Text(String(decoding: approved.payload, as: UTF8.self)).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).padding(12)
                }.frame(height: 180)
            }.font(.system(size: 13))
            Text("Mettre en pause n’efface pas les données déjà reçues.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var footer: some View {
        HStack {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.preview == nil ? (model.selectionHint ?? "Aperçu local · rien n’est envoyé.") : "La confirmation autorise l’envoi.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if model.preview == nil {
                Button("Voir l’aperçu") { Task { await model.prepare(origin: origin, tokenPath: tokenPath) } }
                    .buttonStyle(LHPrimaryButtonStyle()).accessibilityIdentifier("sharing-preview")
                    .disabled(model.busy || model.loading || model.catalog == nil || model.draft.validationMessage != nil )
            } else if !connected || model.preview?.credentialFingerprint.isEmpty == true {
                Button("Relier mon compte") { openSite(fragment: "settings") }.buttonStyle(LHPrimaryButtonStyle())
            } else {
                Button(model.draft.delivery == .daily ? "Activer l’envoi quotidien" : "Envoyer cette journée") {
                    if model.draft.delivery == .once { model.reviewed = true }
                    Task { await model.confirm(origin: origin, tokenPath: tokenPath) }
                }.buttonStyle(LHPrimaryButtonStyle()).accessibilityIdentifier("sharing-send")
                    .disabled(model.busy || (model.draft.delivery == .daily && !model.reviewed) || (model.preview.flatMap { try? GoalongReadableShareData(payload: $0.payload) } == nil))
            }
        }.padding(20).background(LHTheme.cardBackground)
    }
    private func openSite(fragment: String) {
        let site = origin.isEmpty ? "https://goalong.spry-crumb-3668.chatgpt.site" : origin
        guard let endpoint = try? GoalongSiteSubmission.endpoint(origin: site), var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/goalong.dc.html"; parts.fragment = fragment
        if let url = parts.url { _ = GoalongWorkspaceOpenPolicy.open(url, purpose: .goalongWebsite) }
    }
}

struct GoalongSharingSelector: View {
    struct Item: Identifiable { let id: String; let title: String; let detail: String; var symbol: String? = nil }
    let title: String
    let symbol: String
    let items: [Item]
    @Binding var selection: Set<String>
    @State private var search = ""
    private var absent: [String] { selection.subtracting(Set(items.map(\.id))).sorted() }
    private var visible: [Item] { items.filter { search.isEmpty || $0.title.localizedStandardContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Text("\(selection.intersection(Set(items.map(\.id))).count) / \(items.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if items.count > 4 {
                TextField("Rechercher…", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("Rechercher dans \(title)")
            }
            HStack(spacing: 12) {
                Button("Sélectionner les résultats") { selection.formUnion(visible.map(\.id)) }.disabled(visible.isEmpty)
                Button("Tout décocher") { selection.removeAll() }.disabled(selection.isEmpty)
            }.buttonStyle(.borderless).font(.caption)
            if !absent.isEmpty {
                GoalongDisclosureGroup("\(absent.count) choix enregistrés absents de cette journée") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ils restent autorisés pour les prochains envois s’ils réapparaissent. Retirez ceux que vous ne souhaitez plus autoriser.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(absent, id: \.self) { id in
                            HStack {
                                Text(id).font(.caption).lineLimit(2).textSelection(.enabled)
                                Spacer()
                                Button("Retirer") { selection.remove(id) }.buttonStyle(.borderless)
                                    .accessibilityLabel("Retirer l’autorisation de \(id)")
                            }
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
            if visible.isEmpty {
                Text(items.isEmpty ? "Aucun élément enregistré pour cette sélection." : "Aucun résultat. Essayez un autre nom.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { item in
                            Toggle(isOn: Binding(get: { selection.contains(item.id) }, set: {
                                if $0 { selection.insert(item.id) } else { selection.remove(item.id) }
                            })) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol ?? symbol).foregroundStyle(.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.callout).lineLimit(1)
                                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }.toggleStyle(.checkbox).padding(.vertical, 8).padding(.horizontal, 9)
                                .background(selection.contains(item.id) ? LHTheme.accent.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("\(title) : \(item.title)")
                        }
                    }
                }.frame(height: min(CGFloat(visible.count) * 54, 210))
            }
        }
    }
}
#endif
