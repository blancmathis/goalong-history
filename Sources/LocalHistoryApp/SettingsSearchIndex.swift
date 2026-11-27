#if os(macOS)
import SwiftUI

/// T-057 idée 8 (maquette): the search of the Settings finds what you want to DO and the words you READ on a screen,
/// not only the name of a section. Each entry says where it lives (« Stockage › Conservation ») and what it does.
struct SettingsSearchEntry: Identifiable, Hashable {
    enum Kind: Hashable { case setting, command }
    let id: String
    let kind: Kind
    /// Where it lives, from the pane to the group, shown as a path.
    let path: [String]
    /// What you do there, as the label of the control.
    let title: String
    /// Words of the screen and synonyms; not shown.
    let words: String
    let symbol: String
    /// Opens a pane; nil for a page or a command that has its own destination.
    let pane: SettingsPane?
    var breadcrumb: String { path.joined(separator: " › ") }
}

enum SettingsSearchIndex {
    /// The labels below are the ones of the real controls (GoalongStorageSettings, SettingsPage, GoalongMotionSettings…).
    static let entries: [SettingsSearchEntry] = [
        .init(id: "storage-retention", kind: .setting, path: ["Stockage", "Conservation"], title: "Modifier la durée de conservation",
              words: "conservation conserver garder durée historique effacer ancien jours mois", symbol: "internaldrive", pane: .storage),
        .init(id: "storage-erase", kind: .setting, path: ["Stockage", "Gestion des données"], title: "Effacer une partie de l’historique",
              words: "supprimer effacer vider historique données espace disque", symbol: "trash", pane: .storage),
        .init(id: "perm-calendar", kind: .setting, path: ["Autorisations macOS", "Agenda et rappels"], title: "Autoriser l’accès à l’agenda",
              words: "agenda calendrier rappels événements créneaux accès permission", symbol: "calendar", pane: .permissions),
        .init(id: "apps-exclude", kind: .setting, path: ["Apps et sites", "Exclusions"], title: "Exclure une app ou un site du suivi",
              words: "ignorer exclure exclusions masquer application navigateur domaine", symbol: "app.badge.checkmark", pane: .applications),
        .init(id: "rec-idle", kind: .setting, path: ["Enregistrement", "Suivi"], title: "Délai sans interaction",
              words: "inactivité présence absence écran allumé appels vidéo réunion minutes", symbol: "record.circle", pane: .recording),
        .init(id: "rec-private", kind: .setting, path: ["Enregistrement", "Confidentialité avancée"], title: "Fenêtres privées",
              words: "navigation privée incognito paramètres adresses url", symbol: "eye.slash", pane: .recording),
        .init(id: "home-login", kind: .setting, path: ["Réglages", "Démarrage"], title: "Ouvrir Goalong à l’ouverture de session",
              words: "démarrage démarrer ouverture session login arrière-plan quitter fermer", symbol: "power", pane: .home),
        .init(id: "home-motion", kind: .setting, path: ["Réglages", "Affichage"], title: "Animations",
              words: "animations mouvement réduire transitions affichage", symbol: "wand.and.sparkles", pane: .home),
        .init(id: "home-keyboard", kind: .setting, path: ["Réglages", "Clavier"], title: "Rétroéclairage du clavier",
              words: "clavier luminosité rétroéclairage plages horaires", symbol: "keyboard", pane: .home),
        .init(id: "chatgpt", kind: .setting, path: ["Analyse ChatGPT", "Consignes"], title: "Personnaliser les consignes du bilan",
              words: "chatgpt analyse prompt consignes bilan pseudonyme données", symbol: "sparkles", pane: .chatGPT),
        .init(id: "site-daily", kind: .setting, path: ["Envoyer au site Goalong", "Fréquence"], title: "Envoi quotidien",
              words: "site compte goalong partager envoyer synchroniser quotidien fréquence", symbol: "arrow.up.circle", pane: .website),
        .init(id: "adv-version", kind: .setting, path: ["Avancé", "Version"], title: "Version et mise à jour",
              words: "version mise à jour build vérifier installer développeur diagnostic", symbol: "wrench.and.screwdriver", pane: .advanced),
        .init(id: "jev", kind: .setting, path: ["Garde-fous", "Règles"], title: "Réglages de Jev",
              words: "jev surveillance temps réel clé api typesafe rappel distraction pause", symbol: "eye.circle", pane: nil),
        .init(id: "cmd-report", kind: .command, path: ["Aide"], title: "Signaler un problème…",
              words: "signaler problème bug aide support diagnostic envoyer", symbol: "stethoscope", pane: nil),
        .init(id: "cmd-pause", kind: .command, path: ["Aide"], title: "Tout suspendre, pour une activité sensible",
              words: "suspendre pause arrêter historique analyses envois sensible confidentiel", symbol: "pause.circle", pane: nil),
        .init(id: "cmd-welcome", kind: .command, path: ["Aide"], title: "Revoir le démarrage",
              words: "démarrage accueil présentation premiers pas tutoriel", symbol: "sparkles", pane: nil),
    ]

    /// A word of 7 letters or more matches by its first 6 (« conservation » finds « conserver »). Every word must match.
    static func search(_ raw: String, in entries: [SettingsSearchEntry] = entries) -> [SettingsSearchEntry] {
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        func stem(_ t: String) -> String { t.count >= 7 ? String(t.prefix(6)) : t }
        let scored: [(SettingsSearchEntry, Int)] = entries.compactMap { entry in
            var score = 0
            for token in tokens {
                let key = stem(token)
                if entry.title.localizedStandardContains(key) { score += 3 }
                else if entry.path.joined(separator: " ").localizedStandardContains(key) { score += 2 }
                else if entry.words.localizedStandardContains(key) { score += 1 }
                else { return nil }
            }
            return (entry, score + (entry.kind == .command ? 1 : 0))
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Results under the persistent search field: one row per control, its path, and where it leads.
struct SettingsSearchResults: View {
    let query: String
    var entries: [SettingsSearchEntry] = SettingsSearchIndex.entries
    var onOpen: (SettingsSearchEntry) -> Void = { _ in }

    var body: some View {
        let found = SettingsSearchIndex.search(query, in: entries)
        VStack(alignment: .leading, spacing: 8) {
            if found.isEmpty {
                LHCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rien ne correspond à « \(query) ».").font(.system(size: 13, weight: .medium))
                        Text("Essayez un mot de l’écran (conservation, agenda) ou une action (suspendre, signaler).")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(found.count == 1 ? "1 résultat" : "\(found.count) résultats")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                    .accessibilityIdentifier("settings-search-count")
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(found) { entry in
                            Button { onOpen(entry) } label: { row(entry) }
                                .buttonStyle(LHNavigationButtonStyle(cornerRadius: 0))
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("settings-search-\(entry.id)")
                            if entry != found.last { GoalongRowDivider() }
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: SettingsSearchEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.highlighted(entry.title, query: query)).font(.system(size: 13, weight: .medium))
                Text(entry.breadcrumb).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 12)
            if entry.kind == .command {
                Text("Commande").font(.system(size: 11, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(LHTheme.insetBackground))
            }
            GoalongRowChevron()
        }
        .padding(.horizontal, LHTheme.cardInset).frame(minHeight: 56).contentShape(Rectangle())
    }

    /// The matching words in the accent colour; the rest as is.
    static func highlighted(_ title: String, query: String) -> AttributedString {
        var text = AttributedString(title)
        for token in query.split(whereSeparator: \.isWhitespace) {
            let key = token.count >= 7 ? String(token.prefix(6)) : String(token)
            if let range = title.range(of: key, options: [.caseInsensitive, .diacriticInsensitive]),
               let start = AttributedString.Index(range.lowerBound, within: text), let end = AttributedString.Index(range.upperBound, within: text) {
                text[start..<end].foregroundColor = LHTheme.accent
            }
        }
        return text
    }
}
#endif
