#if os(macOS)
import AppKit
import SwiftUI
import LocalHistoryQueryCLI

@MainActor struct GoalongWebsiteSharingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GoalongWebsiteSharingModel
    @ObservedObject private var autoSender: GoalongWebsiteAutoSender
    @AppStorage("goalong.website.origin") private var origin = ""
    @AppStorage("goalong.website.tokenFilePath") private var tokenPath = ""
    @State private var exactData = false
    @State private var advanced = false

    init(model: GoalongWebsiteSharingModel? = nil) {
        let resolved = model ?? GoalongWebsiteSharingModel()
        _model = StateObject(wrappedValue: resolved)
        _autoSender = ObservedObject(wrappedValue: resolved.autoSender)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    account
                    delivery
                    if autoSender.savedConfiguration != nil {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(LHTheme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(autoSender.status).font(.callout)
                                if let day = autoSender.lastSuccess { Text("Dernière journée reçue : \(day)").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if autoSender.enabled { Button("Mettre en pause") { autoSender.stop() }.buttonStyle(.bordered) }
                        }.padding(14).background(LHTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    selection
                    preview
                    if let status = model.status {
                        Label(status, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(LHTheme.success)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("sharing-success")
                        Button("Voir mon historique sur le site") { openSite(fragment: "history") }.buttonStyle(.bordered)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(LHTheme.warning)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityIdentifier("sharing-error")
                    }
                    DisclosureGroup("Récap, analyse relue ou connexion manuelle") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Les textes et analyses peuvent contenir des informations personnelles. Ils se partagent séparément, après relecture, et ne sont jamais ajoutés à l’envoi quotidien.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Préparer un partage ponctuel avancé…") { advanced = true }.buttonStyle(.bordered)
                        }.padding(.top, 8)
                    }.font(.callout)
                }.padding(24)
            }.disabled(model.busy)
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 740, maxWidth: 820, minHeight: 560, idealHeight: 720, maxHeight: 780)
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .environment(\.locale, Locale(identifier: "fr_FR"))
        .environment(\.timeZone, sharingCalendar.timeZone)
        .environment(\.calendar, sharingCalendar)
        .interactiveDismissDisabled(model.busy)
        .task { if model.catalog == nil { await model.loadCatalog() } }
        .onChange(of: model.draft.date) { _ in Task { await model.loadCatalog() } }
        .onChange(of: model.draft.includeWebsites) { _ in Task { await model.loadCatalog() } }
        .onChange(of: origin) { _ in model.connectionChanged() }
        .onChange(of: tokenPath) { _ in model.connectionChanged() }
        .onDisappear { model.cancelPreparation() }
        .sheet(isPresented: $advanced) { GoalongWebsiteConnectionSheet() }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 15) {
            Image(systemName: "arrow.up.doc").font(.system(size: 24, weight: .medium))
                .foregroundStyle(LHTheme.accent).frame(width: 48, height: 48)
                .background(LHTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("GOALONG HISTORY").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                Text("Partager avec GoLong").font(.system(size: 24, weight: .semibold))
                Text("Vos données. Vos choix. Aucun envoi sans votre accord.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                .buttonStyle(.borderless).accessibilityLabel("Fermer le partage")
                .keyboardShortcut(.cancelAction).disabled(model.busy)
        }.padding(24)
    }
    private var account: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(LHTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(tokenPath.isEmpty || origin.isEmpty ? "Reliez votre compte avant d’envoyer" : "Destination : votre compte GoLong").font(.callout.weight(.semibold))
                Text(origin.isEmpty ? "La liaison n’envoie aucune activité." : origin).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("L’envoi au compte et le partage à d’autres personnes sont distincts. Vos règles actives sur le site s’appliqueront aux données reçues.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(tokenPath.isEmpty || origin.isEmpty ? "Relier mon compte" : "Règles du site") {
                openSite(fragment: tokenPath.isEmpty || origin.isEmpty ? "settings" : "privacy")
            }.buttonStyle(.bordered)
        }
    }
    private var delivery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode d’envoi", selection: $model.draft.delivery) {
                Text("Partager une fois").tag(GoalongWebsiteShareDraft.Delivery.once)
                Text("Synchroniser chaque jour").tag(GoalongWebsiteShareDraft.Delivery.daily)
            }.pickerStyle(.segmented).controlSize(.large).accessibilityIdentifier("sharing-delivery")
            if model.draft.delivery == .daily {
                HStack(alignment: .top, spacing: 16) {
                    DatePicker("À partir de", selection: scheduleTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field).frame(width: 190)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.draft.timezone).font(.callout.weight(.medium))
                        Text("La veille uniquement, lorsque l’app est ouverte et le Mac connecté. Au prochain lancement après cette heure, la veille est traitée ; les journées plus anciennes ne sont pas rattrapées.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Label("Nouveaux appareils, applications et domaines exclus. Récaps, conversations et textes libres jamais envoyés automatiquement.", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Un seul envoi de la journée choisie. Aucun envoi quotidien n’est activé par cette action.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var sharingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: model.draft.timezone) ?? .current
        return calendar
    }
    private var scheduleTime: Binding<Date> {
        Binding(get: {
            sharingCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: model.draft.hour, minute: model.draft.minute)) ?? Date()
        }, set: {
            model.draft.hour = sharingCalendar.component(.hour, from: $0)
            model.draft.minute = sharingCalendar.component(.minute, from: $0)
        })
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("1", "Choisir les données")
            HStack {
                DatePicker(model.draft.delivery == .daily ? "Journée d’exemple" : "Journée à partager", selection: $model.draft.date,
                           in: ...Date(), displayedComponents: .date).datePickerStyle(.field)
                Spacer()
                Button { Task { await model.loadCatalog() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.loading)
            }
            if model.loading {
                ProgressView("Lecture des données déjà enregistrées sur ce Mac…").font(.callout)
            } else if let catalog = model.catalog {
                VStack(alignment: .leading, spacing: 12) {
                    GoalongSharingSelector(title: "Appareils", symbol: "desktopcomputer", items: catalog.devices.map {
                        .init(id: $0.id, title: $0.name, detail: $0.screenSeconds.map(duration) ?? "Durée indisponible")
                    }, selection: $model.draft.deviceIDs)
                    Text("Les durées totales des appareils cochés sont incluses, y compris le temps des applications dont les noms restent masqués. Fuseau des données : \(catalog.timezone).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Inclure le nom personnel des appareils", isOn: $model.draft.includeDeviceNames).font(.callout)
                    Text("Désactivé : nom générique et identifiant pseudonymisé, sans le nom personnel de l’appareil.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Applications et durées", isOn: $model.draft.includeApplications).font(.callout.weight(.medium))
                    if model.draft.includeApplications {
                        GoalongSharingSelector(title: "Applications autorisées", symbol: "app", items: applicationItems,
                                               selection: $model.draft.applicationIDs)
                    }
                    Toggle("Répartition horaire des appareils choisis", isOn: $model.draft.includeHourly).font(.callout.weight(.medium))
                    Text("Uniquement si elle a été enregistrée. Les horaires ne sont jamais reconstitués à partir d’un total.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Domaines web observés sur ce Mac", isOn: $model.draft.includeWebsites).font(.callout.weight(.medium))
                    if model.draft.includeWebsites {
                        GoalongSharingSelector(title: "Domaines autorisés", symbol: "globe", items: catalog.websites.map {
                            .init(id: $0.domain, title: $0.domain, detail: duration($0.seconds))
                        }, selection: $model.draft.websiteDomains)
                        Text("Cette source vient de ce Mac, indépendamment des appareils ci-dessus. Domaines uniquement : ni URL complète, ni titre de page, ni contenu.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18).background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            } else {
                Text("Aucune journée disponible pour cette sélection. Choisissez une autre date ou vérifiez les sources autorisées dans les réglages.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.draft.includeWebsites {
                    Button("Continuer sans les domaines web") { model.draft.includeWebsites = false }.buttonStyle(.bordered)
                }
            }
        }
    }
    private var applicationItems: [GoalongSharingSelector.Item] {
        var rows: [String: GoalongSharingSelector.Item] = [:]
        for device in model.catalog?.devices ?? [] where model.draft.deviceIDs.contains(device.id) {
            for app in device.applications {
                rows[app.id] = .init(id: app.id, title: app.name, detail: "Application enregistrée sur les appareils choisis")
            }
        }
        return rows.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("2", "Vérifier avant d’autoriser")
            if let approved = model.preview {
                HStack(spacing: 16) {
                    summary("Appareils", "\(approved.transmittedCounts.devices)")
                    summary("Lignes d’apps", "\(approved.transmittedCounts.applications)")
                    summary("Domaines", "\(approved.transmittedCounts.websites)")
                    summary("Taille", ByteCountFormatter.string(fromByteCount: Int64(approved.payload.count), countStyle: .file))
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LHTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Text("Aperçu local du \(approved.draft.day). Rien n’a encore été envoyé.").font(.callout)
                DisclosureGroup("Voir exactement les données transmises", isExpanded: $exactData) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(String(decoding: approved.payload, as: UTF8.self)).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).padding(12)
                    }.frame(height: 190).background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                }.font(.callout)
                Toggle(isOn: $model.reviewed) {
                    Text(model.draft.delivery == .daily
                         ? "J’autorise l’envoi quotidien de la veille avec ces appareils et ces champs uniquement. Les valeurs évolueront ; la sélection ne s’élargira pas."
                         : "J’ai vérifié la destination et les données. J’autorise cet envoi unique.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("sharing-confirm-review")
                Text("Vos règles de partage actives sur le site peuvent rendre ces données visibles à leurs destinataires. Décocher ou mettre en pause ne supprime pas les données déjà reçues. Un envoi n’est pas une preuve indépendante d’authenticité.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.draft.validationMessage ?? "Préparez l’aperçu local pour voir les seuls champs qui seront envoyés. Toute modification impose un nouvel aperçu.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 14) {
            if model.busy { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.busy ? "Opération en cours…" : "Votre sélection reste sous votre contrôle").font(.callout.weight(.medium))
                Text(model.preview == nil ? "L’aperçu ne transmet aucune donnée." : "Seule votre confirmation autorise l’envoi.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.preview == nil {
                Button("Préparer l’aperçu") { Task { await model.prepare(origin: origin, tokenPath: tokenPath) } }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .disabled(model.busy || model.loading || model.catalog == nil || model.draft.validationMessage != nil || origin.isEmpty || tokenPath.isEmpty)
                    .accessibilityIdentifier("sharing-preview")
            } else {
                Button(model.draft.delivery == .daily ? "Activer la synchronisation" : "Envoyer cette journée") {
                    Task { await model.confirm(origin: origin, tokenPath: tokenPath) }
                }.buttonStyle(LHPrimaryButtonStyle()).disabled(model.busy || !model.reviewed)
                    .accessibilityIdentifier("sharing-send")
            }
        }.padding(20).background(LHTheme.cardBackground)
    }
    private func sectionTitle(_ number: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(LHTheme.accent)
                .frame(width: 24, height: 24).background(LHTheme.accent.opacity(0.10), in: Circle())
            Text(text).font(.system(size: 15, weight: .semibold))
        }
    }
    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        return seconds < 3600 ? "\(seconds / 60) min" : "\(seconds / 3600) h \(String(format: "%02d", (seconds % 3600) / 60))"
    }
    private func openSite(fragment: String) {
        let site = origin.isEmpty ? "https://goalong.spry-crumb-3668.chatgpt.site" : origin
        guard let endpoint = try? GoalongSiteSubmission.endpoint(origin: site), var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/goalong.dc.html"; parts.fragment = fragment
        if let url = parts.url { _ = GoalongWorkspaceOpenPolicy.open(url, purpose: .goalongWebsite) }
    }
}

struct GoalongSharingSelector: View {
    struct Item: Identifiable { let id: String; let title: String; let detail: String }
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
                DisclosureGroup("\(absent.count) choix enregistrés absents de cette journée") {
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
                                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
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
