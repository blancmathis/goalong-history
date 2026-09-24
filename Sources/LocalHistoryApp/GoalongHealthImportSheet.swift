#if os(macOS)
import AppKit
import LocalHistoryQueryCLI
import SwiftUI
import UniformTypeIdentifiers

struct GoalongHealthImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var host = GoalongWebsiteWindowHost()
    @State private var file: URL?
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var through = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var selected = Set(GoalongHealthGroup.allCases)
    @State private var preferred: [GoalongHealthGroup: String] = [:]
    @State private var result: GoalongHealthImportResult?
    @State private var payload: Data?
    @State private var days: [[String: Any]] = []
    @State private var previewDate = ""
    @State private var savedDates: [String] = []
    @State private var savedDate = ""
    @State private var message: String?
    @State private var error: String?
    @State private var busy = false
    @State private var readTask: Task<GoalongHealthImportResult, Error>?
    @State private var sourceChoices: [GoalongHealthGroup: [String]] = [:]
    @State private var exactData = false
    @State private var consent = false
    @AppStorage("goalong.website.origin") private var origin = ""
    @AppStorage("goalong.website.tokenFilePath") private var tokenFilePath = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "heart.text.clipboard").font(.title).foregroundStyle(LHTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apple Santé").font(.title2.weight(.semibold))
                    Text("Sommeil, récupération et activité. Vous choisissez ce qui reste sur ce Mac et ce qui part sur Goalong.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    inputSection
                    if !savedDates.isEmpty {
                        HStack {
                            Picker("Déjà sur ce Mac", selection: $savedDate) {
                                Text("Choisir une journée").tag("")
                                ForEach(savedDates, id: \.self) { Text($0).tag($0) }
                            }
                            Button("Afficher") { readSaved() }.disabled(savedDate.isEmpty)
                            Button("Mettre à la corbeille") { trashSavedDay() }.disabled(savedDate.isEmpty)
                        }
                    }
                    if file != nil { selectionSection }
                    if !days.isEmpty { previewSection }
                    if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(LHTheme.success).textSelection(.enabled) }
                    if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(busy)
            Divider()
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(readTask != nil ? "Lecture locale de l’export…" : "Opération en cours…").font(.caption)
                    if readTask != nil { Button("Annuler la lecture") { readTask?.cancel() } }
                } else { Text("Données déclaratives · aucun score de productivité calculé").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }.padding(16)
        }
        .frame(minWidth: 690, idealWidth: 800, maxWidth: 950, minHeight: 550, idealHeight: 720)
        .background(GoalongWebsiteWindowReader(host: host))
        .onAppear { savedDates = (try? GoalongHealthArchive.dates(root: AppPaths.applicationSupportDirectory)) ?? [] }
        .onChange(of: from) { _ in invalidate() }
        .onChange(of: through) { _ in invalidate() }
        .onChange(of: selected) { _ in invalidate() }
        .onChange(of: preferred) { _ in invalidate() }
        .onChange(of: origin) { _ in consent = false }
        .onChange(of: tokenFilePath) { _ in consent = false }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Importer depuis votre iPhone").font(.headline)
            Text("Dans Santé : Résumé → votre profil → Exporter toutes les données de santé. Envoyez le fichier au Mac par AirDrop, décompressez-le puis sélectionnez export.xml.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choisir export.xml…", action: chooseFile).buttonStyle(LHPrimaryButtonStyle())
                if let file { Text(file.lastPathComponent).font(.caption); Button("Oublier ce fichier") { self.file = nil; sourceChoices = [:]; preferred = [:]; invalidate() } }
            }
            Text("Le fichier complet est lu sur ce Mac. Les dossiers médicaux, médicaments, trajets GPS et autres données non proposées ici sont exclus.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Choisir les dates et les données").font(.headline)
            HStack {
                DatePicker("Du", selection: $from, displayedComponents: .date)
                DatePicker("Au", selection: $through, displayedComponents: .date)
            }
            ForEach(GoalongHealthGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(group.title, isOn: Binding(get: { selected.contains(group) }, set: { if $0 { selected.insert(group) } else { selected.remove(group) } }))
                    if selected.contains(group), let choices = sourceChoices[group], choices.count > 1 {
                        Picker("Source", selection: Binding(get: { preferred[group] ?? "" }, set: { preferred[group] = $0.isEmpty ? nil : $0 })) {
                            Text("Automatique : une source par jour").tag("")
                            ForEach(choices, id: \.self) { Text($0).tag($0) }
                        }.font(.caption).padding(.leading, 20)
                    }
                }
            }
            Text("Les durées de sommeil sont réparties à minuit dans le fuseau \(TimeZone.current.identifier). Une nuit peut donc apparaître sur deux journées. Une valeur absente reste inconnue.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Préparer l’aperçu local", action: prepare).disabled(selected.isEmpty)
        }
    }
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack { Text("Votre sélection").font(.headline); Spacer(); Text("\(days.count) journée(s)").font(.subheadline).foregroundStyle(.secondary) }
            if let result {
                ForEach(result.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Les moyennes cardiaques décrivent les échantillons disponibles. Les entraînements et l’activité quotidienne peuvent se recouper : leurs durées et calories ne s’additionnent pas.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Journée", selection: $previewDate) {
                ForEach(days.compactMap { $0["date"] as? String }, id: \.self) { Text($0).tag($0) }
            }
            ForEach(Array(days.filter { $0["date"] as? String == previewDate }.enumerated()), id: \.offset) { _, day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(day["date"] as? String ?? "Journée").font(.headline)
                    let health = day["health"] as? [String: Any] ?? [:]
                    let metrics = health["metrics"] as? [[String: Any]] ?? []
                    ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.metricNames[metric["key"] as? String ?? ""] ?? "Mesure").font(.subheadline)
                                Text(metric["source"] as? String ?? "").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Self.formatted(metric)).font(.subheadline.monospacedDigit())
                        }
                    }
                    let workouts = health["workouts"] as? [[String: Any]] ?? []
                    ForEach(Array(workouts.enumerated()), id: \.offset) { _, workout in
                        HStack {
                            Image(systemName: "figure.run").foregroundStyle(LHTheme.accent)
                            Text(Self.sport(workout["sport"] as? String ?? ""))
                            Spacer()
                            Text(Self.duration(workout["durationSeconds"] as? Double ?? 0))
                            if let distance = workout["distanceMeters"] as? Double { Text(String(format: "%.2f km", distance / 1000)) }
                        }.font(.subheadline)
                    }
                }.padding(14).background(LHTheme.pageBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            if let payload {
                GoalongDisclosureGroup("Voir les données exactes", isExpanded: $exactData) {
                    ScrollView([.vertical, .horizontal]) { Text(String(decoding: payload, as: UTF8.self)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10) }.frame(height: 220)
                }
                HStack {
                    if result != nil { Button("Conserver sur ce Mac", action: saveLocally) }
                    Button("Exporter pour Goalong…", action: exportFile)
                }
                Text("Conserver remplace uniquement les journées Santé de cette sélection. L’historique d’écran reste conservé.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Envoyer au site Goalong").font(.headline)
                TextField("Adresse du site Goalong (https://…)", text: $origin).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Choisir mon fichier d’accès…", action: chooseToken)
                    if !tokenFilePath.isEmpty { Text(URL(fileURLWithPath: tokenFilePath).lastPathComponent).font(.caption); Button("Oublier") { tokenFilePath = "" } }
                }
                Text("Créez cet accès depuis Sources et connexions sur le site. Seules les mesures de cet aperçu seront transmises ; vos autorisations Santé explicites sur le site détermineront leur visibilité.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("J’autorise l’envoi de ces données Santé au site indiqué.", isOn: $consent)
                Button("Envoyer les données relues", action: sendReviewedHealth).buttonStyle(LHPrimaryButtonStyle())
                    .disabled(!consent || origin.isEmpty || tokenFilePath.isEmpty)
            }
        }
    }

    private func invalidate() { payload = nil; result = nil; days = []; consent = false; message = nil; error = nil }
    private func setPayload(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["source"] as? String == "apple-health", let rows = object?["days"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        days = rows; payload = data; consent = false; previewDate = rows.last?["date"] as? String ?? ""
    }
    private func chooseFile() {
        guard let window = host.window else { return }
        let panel = NSOpenPanel(); panel.title = "Choisir l’export Apple Santé"
        panel.allowedContentTypes = [.xml]; panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            file = url; preferred = [:]; sourceChoices = [:]; invalidate()
        }
    }
    private func prepare() {
        guard let file else { return }
        let options = GoalongHealthImportOptions(from: from, through: through, groups: selected, preferredSources: preferred)
        invalidate(); busy = true
        let task = Task.detached(priority: .userInitiated) { try GoalongHealthImport.read(file: file, options: options) }
        readTask = task
        Task { @MainActor in
            defer { busy = false; readTask = nil }
            do {
                let value = try await task.value
                result = value; sourceChoices = value.sources; try setPayload(value.payload)
            } catch { self.error = String(describing: error) }
        }
    }
    private func saveLocally() {
        guard let result else { return }
        do {
            try GoalongHealthArchive.save(result, root: AppPaths.applicationSupportDirectory)
            savedDates = try GoalongHealthArchive.dates(root: AppPaths.applicationSupportDirectory)
            message = "\(result.dayCount) journée(s) Santé conservée(s) sur ce Mac. Aucun envoi effectué."
        } catch { self.error = String(describing: error) }
    }
    private func readSaved() {
        invalidate(); file = nil
        do { try setPayload(GoalongHealthArchive.read(day: savedDate, root: AppPaths.applicationSupportDirectory)) }
        catch { self.error = String(describing: error) }
    }
    private func trashSavedDay() {
        guard let window = host.window, !savedDate.isEmpty else { return }
        let date = savedDate
        do { _ = try GoalongHealthArchive.read(day: date, root: AppPaths.applicationSupportDirectory) }
        catch { self.error = String(describing: error); return }
        let confirmation = NSAlert()
        confirmation.messageText = "Retirer les données Santé du \(date) de ce Mac ?"
        confirmation.informativeText = "Le fichier compact de cette journée sera déplacé dans la corbeille. L’export Apple original, le temps d’écran et les données déjà envoyées au site seront conservés. Vous gérez les données du site séparément dans votre compte."
        confirmation.addButton(withTitle: "Mettre à la corbeille"); confirmation.addButton(withTitle: "Annuler")
        confirmation.beginSheetModal(for: window) { choice in
            guard choice == .alertFirstButtonReturn else { return }
            let url = AppPaths.applicationSupportDirectory.appendingPathComponent("health").appendingPathComponent(date + ".json")
            busy = true
            NSWorkspace.shared.recycle([url]) { _, failure in
                DispatchQueue.main.async {
                    busy = false
                    if failure != nil { error = "Cette journée Santé n’a pas pu être déplacée dans la corbeille." }
                    else {
                        invalidate(); savedDate = ""
                        savedDates = (try? GoalongHealthArchive.dates(root: AppPaths.applicationSupportDirectory)) ?? []
                        message = "Journée Santé retirée de ce Mac. Le fichier reste récupérable dans la corbeille."
                    }
                }
            }
        }
    }
    private func exportFile() {
        guard let payload, let window = host.window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "goalong-sante.json"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try GoalongSiteAnalysisExportWriter.write(payload, to: url); message = "Sélection exportée. Le fichier complet Apple Santé reste sur votre Mac." }
            catch { self.error = "Le fichier sélectionné n’a pas pu être enregistré." }
        }
    }
    private func chooseToken() {
        guard let window = host.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.resolvesAliases = false; panel.allowedContentTypes = []; panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let review = try GoalongSiteSubmission.reviewTokenFile(file: url)
                if review.requiresProtection {
                    let alert = NSAlert(); alert.messageText = "Protéger ce fichier d’accès ?"
                    alert.informativeText = "Seul votre compte macOS pourra lire ce fichier (permissions 0600)."
                    alert.addButton(withTitle: "Protéger ce fichier"); alert.addButton(withTitle: "Annuler")
                    alert.beginSheetModal(for: window) { choice in
                        guard choice == .alertFirstButtonReturn else { return }
                        do { try GoalongSiteSubmission.protectTokenFile(file: url, reviewed: review); tokenFilePath = url.path }
                        catch { self.error = String(describing: error) }
                    }
                } else { _ = try GoalongSiteSubmission.readToken(file: url); tokenFilePath = url.path }
            } catch { self.error = String(describing: error) }
        }
    }
    private func sendReviewedHealth() {
        guard let payload, consent else { return }
        let target = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = URL(fileURLWithPath: tokenFilePath)
        busy = true; error = nil; message = nil; consent = false
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await Task.detached { try GoalongSiteSubmission.send(payload: payload, origin: target, tokenFile: token) }.value
                message = "Données reçues par Goalong. Vous pouvez maintenant les consulter et choisir leurs partages sur le site."
            } catch { self.error = String(describing: error) }
        }
    }
    static let metricNames = ["steps": "Pas", "walkingRunningMeters": "Distance à pied / course", "cyclingMeters": "Distance à vélo",
        "activeEnergyKcal": "Énergie active", "exerciseSeconds": "Exercice", "standSeconds": "Temps debout", "flights": "Étages montés",
        "sleepSeconds": "Sommeil", "inBedSeconds": "Au lit", "awakeSeconds": "Éveillé", "sleepUnspecifiedSeconds": "Sommeil sans stade",
        "sleepCoreSeconds": "Sommeil léger", "sleepDeepSeconds": "Sommeil profond", "sleepREMSeconds": "Sommeil paradoxal",
        "heartRateBPM": "Fréquence cardiaque moyenne", "heartRateMinBPM": "Fréquence minimale observée", "heartRateMaxBPM": "Fréquence maximale observée",
        "restingHeartRateBPM": "Fréquence au repos", "walkingHeartRateBPM": "Fréquence moyenne à la marche", "heartRateVariabilityMS": "Variabilité cardiaque (SDNN)",
        "respiratoryRate": "Fréquence respiratoire", "oxygenPercent": "Oxygène sanguin", "vo2Max": "VO₂ max estimée"]
    static func formatted(_ metric: [String: Any]) -> String {
        guard let value = metric["value"] as? Double, let unit = metric["unit"] as? String else { return "Non disponible" }
        if unit == "s" { return duration(value) }
        if unit == "m" { return String(format: "%.2f km", value / 1000) }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "fr_FR"); formatter.maximumFractionDigits = 1
        return (formatter.string(from: NSNumber(value: value)) ?? "—") + (unit == "count" ? "" : " \(unit)")
    }
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded()); return "\(minutes / 60) h \(minutes % 60) min"
    }
    static func sport(_ raw: String) -> String {
        let kind = raw.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        return ["Running": "Course", "Walking": "Marche", "Cycling": "Vélo", "Swimming": "Natation", "Hiking": "Randonnée", "Yoga": "Yoga", "TraditionalStrengthTraining": "Musculation", "FunctionalStrengthTraining": "Renforcement", "Other": "Entraînement"][kind] ?? kind
    }
}
#endif
