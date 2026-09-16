#if os(macOS)
import SwiftUI
import Foundation

struct GoalongAnalysisAppRow: View {
    let app: GoalongApplicationChoice
    @Binding var scope: GoalongAnalysisScope
    let excluded: Bool
    @State private var expanded = false
    private var mode: Int {
        guard !excluded, scope.allows(id: app.id, name: app.name) else { return 0 }
        return scope.allowsDetails(id: app.id, name: app.name) ? 2 : 1
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppIconView(bundleIdentifier: app.id.hasPrefix("name:") ? nil : app.id, appName: app.name, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 14, weight: .medium)).lineLimit(2)
                    if mode == 2 && !GoalongAnalysisField.allCases.contains(where: { scope.allows($0, id: app.id, name: app.name) }) {
                        Text("Aucun détail activé").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if mode == 2 {
                    Button(expanded ? "Masquer les options" : "Personnaliser") { expanded.toggle() }.buttonStyle(.borderless).font(.system(size: 12))
                }
                Picker("Données de \(app.name)", selection: Binding(get: { mode }, set: setMode)) {
                    Text(excluded ? "Exclue de Goalong" : "Ne rien envoyer").tag(0)
                    Text("Durée seulement").tag(1)
                    Text("Détails choisis").tag(2)
                }.labelsHidden().frame(width: 166).disabled(excluded)
            }.frame(minHeight: 47)
            if expanded && mode == 2 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 215))], spacing: 10) {
                    ForEach(GoalongAnalysisField.allCases) { field in
                        Toggle(field.title, isOn: Binding(get: { scope.allows(field, id: app.id, name: app.name) }, set: { enabled in
                            var chosen = Set(scope.perApplicationFields[app.id] ?? GoalongAnalysisField.allCases.filter { scope[keyPath: $0.keyPath] }.map(\.rawValue))
                            if enabled { chosen.insert(field.rawValue) } else { chosen.remove(field.rawValue) }
                            scope.perApplicationFields[app.id] = chosen.sorted()
                        })).toggleStyle(.checkbox).font(.system(size: 12))
                    }
                }.padding(.leading, 42).padding(.bottom, 10)
                Button("Utiliser les réglages communs") { scope.perApplicationFields.removeValue(forKey: app.id) }
                    .buttonStyle(.borderless).font(.system(size: 12)).padding(.leading, 42)
            }
        }.padding(.vertical, 6).padding(.horizontal, 8)
    }
    private func setMode(_ value: Int) {
        var allowed = Set(scope.applicationIDs ?? scope.applicationNames.keys.map { $0 })
        var details = Set(scope.detailApplicationIDs ?? scope.applicationIDs ?? scope.applicationNames.keys.map { $0 })
        if value == 0 { allowed.remove(app.id); details.remove(app.id) }
        else {
            allowed.insert(app.id)
            if value == 2 { details.insert(app.id) } else { details.remove(app.id) }
        }
        scope.applicationIDs = allowed.sorted(); scope.detailApplicationIDs = details.sorted()
        expanded = value == 2
    }
}

struct GoalongReplacementRow: View {
    @Binding var rule: GoalongTextReplacement
    let remove: () -> Void
    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Rechercher").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("Hi Charlie", text: $rule.search).textFieldStyle(.roundedBorder)
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Remplacer par").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("Projet A · vide pour supprimer", text: $rule.replacement).textFieldStyle(.roundedBorder)
                    }
                    Button(action: remove) { Image(systemName: "trash").frame(width: 30, height: 30) }.buttonStyle(.borderless).accessibilityLabel("Supprimer le remplacement")
                }
                if rule.search.isEmpty && !rule.replacement.isEmpty {
                    Text("Indiquez le texte à rechercher.").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                }
                HStack(spacing: 24) {
                    Toggle("Respecter la casse", isOn: $rule.caseSensitive).toggleStyle(.checkbox)
                    Toggle("Mot entier", isOn: $rule.wholeWord).toggleStyle(.checkbox)
                }.font(.system(size: 12))
            }
        }
    }
}

struct GoalongAnalysisHumanPreview: View {
    let text: String
    private let object: [String: Any]
    @State private var visibleLimits: [String: Int] = [:]
    init(text: String) {
        self.text = text
        self.object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(["applications_sur_ce_Mac", "temps_ecran_Apple", "details_autorises", "conversations_choisies"], id: \.self) { key in
                if let rows = object[key] as? [[String: Any]], !rows.isEmpty {
                    GoalongSettingsGroup(title: label(key)) {
                        ForEach(Array(rows.prefix(visibleLimits[key] ?? 40).enumerated()), id: \.offset) { index, row in
                            if key == "applications_sur_ce_Mac" {
                                HStack {
                                    Text(row["application"] as? String ?? "Application")
                                    Spacer()
                                    Text(GoalongReadableSharePreview.duration(row["secondes_actives"] as? Int ?? 0)).monospacedDigit()
                                }.font(.system(size: 14))
                            } else {
                                DisclosureGroup(row["application"] as? String ?? row["appareil"] as? String ?? row["titre"] as? String ?? "\(row["outil"] as? String ?? "Élément") \(index + 1)") {
                                    Text(render(row)).font(.system(size: 13)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                }.font(.system(size: 14))
                            }
                            if index < min(rows.count, visibleLimits[key] ?? 40) - 1 { Divider() }
                        }
                        if rows.count > (visibleLimits[key] ?? 40) {
                            HStack {
                                Text("\(visibleLimits[key] ?? 40) sur \(rows.count) éléments")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Afficher les suivants") { visibleLimits[key] = min(rows.count, (visibleLimits[key] ?? 40) + 40) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            if let limit = object["limite"] as? String { Label(limit, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
            if object.isEmpty { Text(text).font(.system(size: 13)).textSelection(.enabled) }
            else if !["applications_sur_ce_Mac", "temps_ecran_Apple", "details_autorises", "conversations_choisies"].contains(where: { (object[$0] as? [Any])?.isEmpty == false }) {
                Text("Aucune donnée de cette journée ne correspond aux choix actuels.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
    }
    private func label(_ key: String) -> String {
        switch key {
        case "applications_sur_ce_Mac": return "Applications et durées"
        case "temps_ecran_Apple": return "Temps d’écran Apple"
        case "details_autorises": return "Titres, textes et événements choisis"
        case "conversations_choisies": return "Conversations choisies"
        case "texte_affiche": return "Texte affiché"
        case "secondes_actives", "secondes": return "Secondes"
        case "titre": return "Titre"
        case "adresse": return "Adresse"
        case "heure": return "Heure"
        case "site": return "Site"
        case "libelle": return "Libellé"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    private func render(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { "\(label($0)) : \(render(dictionary[$0]!))" }.joined(separator: "\n\n")
        }
        if let values = value as? [Any] { return values.map(render).joined(separator: "\n\n") }
        return String(describing: value)
    }
}
#endif
