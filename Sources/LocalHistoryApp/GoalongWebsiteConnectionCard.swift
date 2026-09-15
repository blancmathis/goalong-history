#if os(macOS)
import AppKit
import Foundation
import LocalHistoryCore
import LocalHistoryQueryCLI
import SwiftUI

extension Notification.Name { static let goalongWebsiteConnected = Notification.Name("goalong.website.connected") }

/// Explicit pairing and reviewed export. Credentials stay in private files, outside preferences.
@MainActor struct GoalongWebsiteConnectionCard: View {
    @AppStorage("goalong.website.tokenFilePath") private var tokenPath = ""
    @AppStorage("goalong.website.origin") private var origin = ""
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @State private var showsConnection = false
    @State private var disconnecting = false
    @State private var credentialAvailable = false
    var body: some View {
        GoalongSettingsGroup(title: "Compte Goalong") {
            HStack(spacing: 14) {
                Image(systemName: "link").font(.system(size: 20)).foregroundStyle(LHTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(credentialAvailable ? "Liaison enregistrée" : "Compte non relié").font(.system(size: 15, weight: .semibold))
                    Text(credentialAvailable ? (URL(string: origin)?.host ?? "Goalong") : "La liaison ne transmet aucune activité.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if credentialAvailable {
                    Button("Déconnecter") { disconnecting = true }.buttonStyle(.bordered)
                } else {
                    Button("Relier mon compte") { openWebsite() }.buttonStyle(LHPrimaryButtonStyle())
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sender.enabled ? "Envoi quotidien activé" : "Envois automatiques désactivés").font(.system(size: 13, weight: .medium))
                    if let day = sender.lastSuccess { Text("Dernière journée reçue : \(day)").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer()
                if sender.enabled { Button("Mettre en pause") { sender.stop() }.buttonStyle(.bordered) }
                Button("Choisir les données…") { showsConnection = true }.buttonStyle(.bordered).disabled(!credentialAvailable)
            }
        }
        .onAppear {
            refreshCredential()
            if UserDefaults.standard.bool(forKey: "goalong.website.openAfterPairing") {
                UserDefaults.standard.set(false, forKey: "goalong.website.openAfterPairing"); showsConnection = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongWebsiteConnected)) { _ in
            refreshCredential(); UserDefaults.standard.set(false, forKey: "goalong.website.openAfterPairing"); showsConnection = true
        }
        .onChange(of: tokenPath) { _ in refreshCredential() }
        .sheet(isPresented: $showsConnection) { GoalongWebsiteSharingSheet() }
        .alert("Déconnecter ce compte ?", isPresented: $disconnecting) {
            Button("Annuler", role: .cancel) {}
            Button("Déconnecter") {
                sender.forget(); tokenPath = ""; origin = ""; credentialAvailable = false
                for key in ["goalong.website.accountID", "goalong.website.accountCredentialFingerprint"] { UserDefaults.standard.removeObject(forKey: key) }
            }
        } message: { Text("Les prochains envois seront arrêtés. Les données déjà reçues restent sur le site. Un envoi déjà commencé peut encore aboutir.") }
    }
    private func refreshCredential() {
        credentialAvailable = !origin.isEmpty && !tokenPath.isEmpty
            && (try? GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath))) != nil
    }
    private func openWebsite() {
        let site = origin.isEmpty ? "https://goalong.spry-crumb-3668.chatgpt.site" : origin
        guard let endpoint = try? GoalongSiteSubmission.endpoint(origin: site),
              var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/goalong.dc.html"; parts.fragment = "settings"
        if let url = parts.url { _ = GoalongWorkspaceOpenPolicy.open(url, purpose: .goalongWebsite) }
    }
}

struct GoalongWebsiteConnectionSheet: View {
    private let preparedAnalysis: Data?
    init(preparedAnalysis: Data? = nil) {
        self.preparedAnalysis = preparedAnalysis
        _payload = State(initialValue: preparedAnalysis)
        _previewSummary = State(initialValue: preparedAnalysis == nil ? "" : "Cartes relues et sélectionnées. Les preuves et règles privées restent locales.")
    }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var windowHost = GoalongWebsiteWindowHost()
    @AppStorage("goalong.website.origin") private var origin = ""
    // Only the user's chosen file path is remembered. The token itself stays in that file.
    @AppStorage("goalong.website.tokenFilePath") private var tokenFilePath = ""
    @State private var date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var includeApps = false
    @State private var includeHourly = false
    @State private var includeWebsites = false
    @State private var includeRecap = false
    @State private var structuredReport = false
    @State private var maskedApps = ""
    @State private var recapExcerpt = ""
    @State private var recapSections: [String] = []
    @State private var selectedRecapSections = Set<Int>()
    @State private var recapNotice = ""
    @ObservedObject private var recapRuntime = ChatGPTRecapRuntime.shared
    @State private var showsRhythmStudio = false
    @State private var contextualRhythm: GoalongContextualRhythm.Rhythm?
    @State private var rhythmContext = false
    @State private var automaticHour = 9
    @State private var includeRhythm = false
    @State private var rhythmProject = ""
    @State private var rhythmApps = ""
    @State private var rhythmTimeline = false
    @State private var rhythmTimes = false
    @ObservedObject private var autoSender = GoalongWebsiteAutoSender.shared
    @State private var payload: Data?
    @State private var devices: [(id: String, name: String)] = []
    @State private var excludedDevices: Set<String> = []
    @State private var previewSummary = ""
    @State private var status: String?
    @State private var error: String?
    @State private var busy = false
    @State private var showsExactData = false
    @State private var showsTokenPath = false
    @State private var tokenPathInput = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect to your Goalong account").font(.title2.weight(.semibold))
                    Text("Envoi dans votre compte. Les règles de partage configurées sur le site s’appliquent aux dates et champs autorisés.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Votre compte Goalong").font(.headline)
                        if !tokenFilePath.isEmpty && !origin.isEmpty {
                            Label("Accès enregistré sur ce Mac", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(LHTheme.success)
                            Text(origin).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Depuis le site, ouvrez Sources et connexions puis Relier mon Mac. L’app reçoit votre accès automatiquement.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Relier depuis le site") {
                                _ = GoalongWorkspaceOpenPolicy.open(URL(string: "https://goalong.spry-crumb-3668.chatgpt.site/goalong.dc.html#settings")!, purpose: .goalongWebsite)
                            }
                        }
                        DisclosureGroup("Connexion manuelle et options avancées") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Adresse et accès enregistrés").font(.headline)
                        TextField("Website origin, for example https://your-goalong-host", text: $origin)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Goalong website HTTPS origin")
                        Text("Create an upload-only token in the website’s Sources page and choose its downloaded file here. If needed, Goalong offers ‘Protéger ce fichier’ to restrict access to your account. Its file stays on your Mac; the token authorizes explicit sends to your chosen website and can be revoked there.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Choose token file…", action: chooseTokenFile)
                            if !tokenFilePath.isEmpty {
                                Text(URL(fileURLWithPath: tokenFilePath).lastPathComponent)
                                    .font(.caption).lineLimit(1).truncationMode(.middle)
                                Button("Forget file") { tokenFilePath = ""; status = nil }
                                    .buttonStyle(.borderless)
                            }
                        }
                        DisclosureGroup("Autre méthode : coller le chemin du fichier", isExpanded: $showsTokenPath) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("~/Downloads/goalong-token.txt", text: $tokenPathInput)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Chemin local du fichier de connexion")
                                Text("Collez le chemin du fichier téléchargé, pas la clé. Seul ce fichier sera lu ; la même protection et la même validation s’appliquent.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Valider ce fichier", action: validateTokenPath)
                                    .disabled(tokenPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.top, 6)
                        }
                        Button("Open website Sources", action: openWebsite)
                            .buttonStyle(.borderless)
                    }
                        }
                    }
                    Divider()
                    if preparedAnalysis == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("2. Choose your data").font(.headline)
                        DatePicker("Saved day", selection: $date, in: ...Date(), displayedComponents: .date)
                        Text("Device names and screen-time totals are included. Source permissions must still be enabled in Goalong. Nothing is collected or analyzed during export.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Application names and durations", isOn: $includeApps)
                        Toggle("Hourly breakdown, when recorded", isOn: $includeHourly)
                        Toggle("Website domains observed on this Mac", isOn: $includeWebsites)
                        Toggle("Saved analysis summary", isOn: $includeRecap)
                        if includeRecap {
                            recapSelection
                        }
                        TextField("Applications à masquer avant envoi (noms séparés par des virgules)", text: $maskedApps)
                        if !maskedApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Leurs noms et identifiants sont neutralisés ; leurs durées sont conservées. Les domaines et le récap sont exclus pour éviter de réintroduire ces noms.").font(.caption)
                        }
                        Toggle("Structured report for productivity", isOn: $structuredReport)
                        Toggle("Calculer le rythme à partir de Computer History", isOn: $includeRhythm)
                        if includeRhythm {
                            Button(contextualRhythm == nil ? "Analyser le contexte d'une session…" : "Choisir une autre session…") { showsRhythmStudio = true }
                            if let rhythm = contextualRhythm {
                                Text("\(rhythm.project) · \(rhythm.episodes?.count ?? 0) épisodes relus").font(.subheadline)
                                if let interpretation = rhythm.interpretation { Text(interpretation).font(.caption) }
                                Button("Retirer cette analyse") { contextualRhythm = nil; invalidatePreview() }
                            } else {
                                DisclosureGroup("Association simple par application, sans analyse du contexte") {
                                    TextField("Nom du projet", text: $rhythmProject)
                                    TextField("Applications liées au projet, séparées par des virgules", text: $rhythmApps)
                                }
                            }
                            Toggle("Inclure les épisodes simplifiés", isOn: $rhythmTimeline)
                            if contextualRhythm != nil && rhythmTimeline { Toggle("Inclure les sujets, explications et éléments de contexte relus", isOn: $rhythmContext) }
                            Toggle("Inclure l'heure de début précise", isOn: $rhythmTimes)
                            Text("Agrégats, épisodes, contexte et horaires sont des choix distincts. Relisez l'aperçu final avant de transmettre.").font(.caption)
                        }
                        if structuredReport {
                            Text("The same selected durations become an editable report. Applications are not automatically considered productive: qualify their context on the website, or let your chosen agent prepare the report before importing it. Raw events and conversations stay outside this export.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !devices.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Devices from the saved day").font(.subheadline.weight(.medium))
                                ForEach(devices, id: \.id) { device in
                                    Toggle(device.name, isOn: Binding(
                                        get: { !excludedDevices.contains(device.id) },
                                        set: { enabled in
                                            if enabled { excludedDevices.remove(device.id) }
                                            else { excludedDevices.insert(device.id) }
                                            invalidatePreview()
                                        }
                                    ))
                                }
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Partage ponctuel avancé").font(.headline)
                        Text("Les récaps et analyses sont envoyés uniquement après votre relecture. Configurez l’envoi quotidien des données chiffrées dans la fenêtre principale « Partager avec GoLong ».").font(.caption)
                        if autoSender.enabled { Button("Mettre la synchronisation en pause") { autoSender.stop() } }
                    }
                    Divider()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("3. Review before sending").font(.headline)
                        if preparedAnalysis == nil { Button(payload == nil ? "Prepare offline preview" : "Refresh offline preview", action: preparePreview)
                            .buttonStyle(.bordered) }
                        if let payload {
                            Text(previewSummary).font(.subheadline)
                            DisclosureGroup("Review exact data", isExpanded: $showsExactData) {
                                ScrollView([.horizontal, .vertical]) {
                                    Text(String(decoding: payload, as: UTF8.self))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).padding(10)
                                }
                                .frame(height: 230)
                                .background(LHTheme.pageBackground, in: RoundedRectangle(cornerRadius: 8))
                            }
                            Text("Seuls les champs affichés sont transmis, y compris les extraits de contexte si vous les avez sélectionnés. Relisez-les : les conversations et journaux complets restent hors de cet export. Les données restent déclaratives.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let status {
                            Label(status, systemImage: "checkmark.circle")
                                .font(.subheadline).foregroundStyle(LHTheme.success)
                                .textSelection(.enabled)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(LHTheme.warning)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(24)
                .disabled(busy)
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text("Sharing audiences stay under your control on the website.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send reviewed data", action: sendReviewedData)
                    .buttonStyle(LHPrimaryButtonStyle())
                    .disabled(busy || payload == nil || tokenFilePath.isEmpty || origin.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 660, height: 760)
        .background(GoalongWebsiteWindowReader(host: windowHost).frame(width: 0, height: 0))
        .interactiveDismissDisabled(busy)
        .onChange(of: date) { _ in devices = []; excludedDevices = []; recapSections = []; selectedRecapSections = []; contextualRhythm = nil; invalidatePreview() }
        .onChange(of: includeApps) { _ in invalidatePreview() }
        .onChange(of: includeHourly) { _ in invalidatePreview() }
        .onChange(of: includeWebsites) { _ in invalidatePreview() }
        .onChange(of: includeRecap) { _ in invalidatePreview() }
        .onChange(of: structuredReport) { _ in invalidatePreview() }
        .onChange(of: maskedApps) { _ in invalidatePreview() }
        .onChange(of: selectedRecapSections) { _ in invalidatePreview() }
        .onChange(of: recapSections) { _ in invalidatePreview() }
        .onChange(of: rhythmContext) { _ in invalidatePreview() }
        .onChange(of: recapRuntime.recap?.generatedAt) { _ in if includeRecap { loadSavedRecap() } }
        .sheet(isPresented: $showsRhythmStudio) { GoalongRhythmStudio(day: date, masks: splitNames(maskedApps)) { rhythm in contextualRhythm = rhythm; invalidatePreview() } }
        .onChange(of: recapExcerpt) { _ in invalidatePreview() }
        .onChange(of: includeRhythm) { _ in invalidatePreview() }
        .onChange(of: rhythmProject) { _ in invalidatePreview() }
        .onChange(of: rhythmApps) { _ in invalidatePreview() }
        .onChange(of: rhythmTimeline) { _ in invalidatePreview() }
        .onChange(of: rhythmTimes) { _ in invalidatePreview() }
        .onChange(of: origin) { _ in if preparedAnalysis == nil { invalidatePreview() }; autoSender.stop() }
        .onChange(of: tokenFilePath) { _ in if preparedAnalysis == nil { invalidatePreview() }; autoSender.stop() }
    }

    private func invalidatePreview() { payload = nil; status = nil; error = nil }

    private func chooseTokenFile() {
        guard let window = windowHost.window else {
            error = "Reopen the website connection window before choosing a token file."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose your Goalong upload-only token file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        // A nested runModal loop inside SwiftUI's connection sheet can stall selection,
        // cancellation and accessibility. Return to the normal event loop immediately.
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            DispatchQueue.main.async { reviewSelectedTokenFile(file, in: window) }
        }
    }

    private func reviewSelectedTokenFile(_ file: URL, in window: NSWindow) {
        do {
            let reviewed = try GoalongSiteSubmission.reviewTokenFile(file: file)
            if reviewed.requiresProtection {
                let confirmation = NSAlert()
                confirmation.messageText = "Protéger ce fichier ?"
                confirmation.informativeText = "Goalong limitera l’accès à « \(file.lastPathComponent) » à votre compte macOS (permissions 0600), puis le sélectionnera pour la connexion. Seul ce fichier sera modifié. Son contenu ne sera pas envoyé."
                confirmation.alertStyle = .informational
                confirmation.addButton(withTitle: "Protéger ce fichier")
                confirmation.addButton(withTitle: "Annuler")
                confirmation.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    do {
                        try GoalongSiteSubmission.protectTokenFile(file: file, reviewed: reviewed)
                        selectTokenFile(file)
                    } catch { self.error = String(describing: error) }
                }
                return
            }
            selectTokenFile(file)
        } catch { self.error = String(describing: error) }
    }

    private func validateTokenPath() {
        guard let window = windowHost.window else {
            error = "Reopen the website connection window before choosing a token file."
            return
        }
        do {
            let file = try GoalongSiteSubmission.tokenFileURL(path: tokenPathInput)
            reviewSelectedTokenFile(file, in: window)
        } catch { self.error = String(describing: error) }
    }

    private func selectTokenFile(_ file: URL) {
        do {
            _ = try GoalongSiteSubmission.readToken(file: file)
            tokenFilePath = file.path
            tokenPathInput = ""
            showsTokenPath = false
            error = nil
            status = nil
        } catch { self.error = String(describing: error) }
    }

    private func openWebsite() {
        do {
            let endpoint = try GoalongSiteSubmission.endpoint(origin: origin.trimmingCharacters(in: .whitespacesAndNewlines))
            var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            parts.path = "/goalong.dc.html"
            parts.fragment = "sources"
            if let url = parts.url, !GoalongWorkspaceOpenPolicy.open(url, purpose: .goalongWebsite) {
                error = "The configured website could not be opened. Check its origin and try again."
            }
        } catch { self.error = String(describing: error) }
    }

    private func splitNames(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private var recapSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choisissez les parties du récap produit par votre agent. Seuls les éléments cochés seront transmis.").font(.caption)
            HStack {
                Button("Charger le récap de cette journée", action: loadSavedRecap)
                Button("Produire ou actualiser avec mon agent") { recapRuntime.selectDay(date); recapRuntime.generateRecap() }
                    .disabled(recapRuntime.isGenerating || !GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis))
            }
            if recapRuntime.isGenerating { ProgressView("L'agent prépare le récap dans Goalong History…") }
            if case .connected = recapRuntime.connectionState {} else { ChatGPTAccountConnectionCard(runtime: recapRuntime) }
            ForEach(recapSections.indices, id: \.self) { index in
                Toggle(isOn: Binding(get: { selectedRecapSections.contains(index) }, set: { include in
                    if include { selectedRecapSections.insert(index) } else { selectedRecapSections.remove(index) }
                })) { Text(recapSections[index]).font(.caption).textSelection(.enabled) }
            }
            if !recapNotice.isEmpty { Text(recapNotice).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Ajouter un commentaire personnel") {
                TextEditor(text: $recapExcerpt).frame(height: 70).accessibilityLabel("Commentaire personnel du récap")
            }
            Text("L'analyse utilise les sources autorisées dans l'app. La génération et l'envoi au site sont deux actions distinctes.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func loadSavedRecap() {
        guard GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { recapNotice = "Activez l'accès aux analyses dans les réglages."; return }
        let selectedDay = date
        Task { @MainActor in
            let saved = await Task.detached { ChatGPTRecapPersistence.load(for: selectedDay, from: AppPaths.chatGPTRecapsDirectory) }.value
            guard Calendar.current.isDate(selectedDay, inSameDayAs: date), GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { return }
            recapSections = saved.map { $0.summaryLines ?? $0.markdown.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } } ?? []
            selectedRecapSections = []
            recapNotice = saved == nil ? "Aucun récap enregistré pour cette journée. Produisez-le avec votre agent, puis choisissez ses éléments." : "Récap chargé. Aucune partie n'est sélectionnée par défaut."
            invalidatePreview()
        }
    }
    private func selectedOptions() -> GoalongSiteExportOptions {
        let split: (String) -> [String] = { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        return GoalongSiteExportOptions(deviceIDs: devices.filter { !excludedDevices.contains($0.id) }.map(\.id),
            includeApplications: includeApps, includeHourly: includeHourly, includeWebsites: includeWebsites,
            includeRecap: includeRecap, structuredReport: structuredReport || includeRhythm,
            maskedApplications: split(maskedApps), recapText: includeRecap ? (recapSections.enumerated().filter { selectedRecapSections.contains($0.offset) }.map(\.element) + (recapExcerpt.isEmpty ? [] : [recapExcerpt])).joined(separator: "\n\n") : nil, recapSectionIndices: selectedRecapSections.isEmpty ? nil : selectedRecapSections.sorted(),
            rhythmProject: includeRhythm && contextualRhythm == nil ? rhythmProject : nil, rhythmApplications: split(rhythmApps),
            includeRhythmTimeline: rhythmTimeline, includeRhythmTimes: rhythmTimes, includeRhythmContext: rhythmContext, contextualRhythm: includeRhythm ? contextualRhythm : nil)
    }

    private func preparePreview() {
        let selected = devices.filter { !excludedDevices.contains($0.id) }.map(\.id)
        guard devices.isEmpty || !selected.isEmpty else { error = "Select at least one device."; return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let root = AppPaths.applicationSupportDirectory
        let options = selectedOptions()
        busy = true
        invalidatePreview()
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: day, options: options)
                }.value
                let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
                let value = (object?["days"] as? [[String: Any]])?.first
                let telemetry = value?["telemetry"] as? [String: Any]
                let rows = telemetry?["devices"] as? [[String: Any]] ?? []
                if devices.isEmpty {
                    devices = rows.compactMap { row in
                        guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                        return (id: id, name: name)
                    }
                }
                let applications = rows.reduce(0) { $0 + (($1["apps"] as? [Any])?.count ?? 0) }
                previewSummary = "\(day) · \(rows.count) devices · \(applications) application rows · \(result.count) bytes. Review the exact fields below."
                payload = result
            } catch { self.error = String(describing: error) }
            busy = false
        }
    }

    private func sendReviewedData() {
        guard let reviewedPayload = payload else { return }
        if preparedAnalysis == nil && !GoalongWebsiteAutoSender.sourcesAllowed(selectedOptions()) {
            invalidatePreview(); error = "Une source choisie a été désactivée. Préparez un nouvel aperçu."; return
        }
        let target = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenFile = URL(fileURLWithPath: tokenFilePath)
        busy = true
        error = nil
        status = nil
        Task { @MainActor in
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try GoalongSiteSubmission.send(payload: reviewedPayload, origin: target, tokenFile: tokenFile)
                }.value
                let result = try JSONSerialization.jsonObject(with: receipt) as? [String: Any] ?? [:]
                status = "Received: \(result["imported"] ?? 0) new, \(result["updated"] ?? 0) updated, \(result["skipped"] ?? 0) unchanged. Unverified. Your website sharing rules apply."
                payload = nil
            } catch { self.error = String(describing: error) }
            busy = false
        }
    }
}

/// SwiftUI sheets do not reliably appear as NSApp.keyWindow/mainWindow. Capture the
/// NSWindow that actually owns this sheet's view, without retaining the window or view.
final class GoalongWebsiteWindowHost: ObservableObject {
    weak var window: NSWindow?
}

struct GoalongWebsiteWindowReader: NSViewRepresentable {
    let host: GoalongWebsiteWindowHost

    final class ProbeView: NSView {
        weak var host: GoalongWebsiteWindowHost?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.host = host
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.host = host
        host.window = view.window
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        if view.host?.window === view.window { view.host?.window = nil }
        view.host = nil
    }
}
#endif
