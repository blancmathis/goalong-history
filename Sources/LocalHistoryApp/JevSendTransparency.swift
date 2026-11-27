#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// What leaves the Mac, in words. Display only: these lists describe the existing payloads, they never change them.
enum JevSendFields {
    struct Field: Equatable { let name: String; let detail: String }

    /// One-line summary shown before the full list.
    static func jevSummary(includesExcerpt: Bool) -> String {
        "Vos critères de travail et exemples hors travail, plus les 15 dernières secondes d’activité (app ou site, titre, interactions)"
            + (includesExcerpt ? ", avec un bref extrait du texte affiché." : ".")
    }
    static let classificationSummary = "Les contextes nouveaux de votre journée, vos tâches connues, quelques réponses passées et la note du jour."

    static func jev(includesExcerpt: Bool) -> [Field] {
        var fields = [
            Field(name: "Critères de travail", detail: "projets, outils, contenus de travail et ce qui n’en est pas, tels que vous les avez écrits"),
            Field(name: "Exemples hors travail", detail: "ceux que vous avez écrits"),
            Field(name: "App ou site", detail: "l’application ou le domaine au premier plan"),
            Field(name: "Titre", detail: "le titre de la fenêtre, quand il est disponible"),
            Field(name: "Action", detail: "indice d’interaction (frappe, clic, défilement, lecture) ; les gestes identiques sont regroupés"),
            Field(name: "Surface", detail: "le type de fenêtre ou de page"),
            Field(name: "Action en cours", detail: "la phrase décrivant ce que vous faites (règle ou séance active), si elle tient dans l’envoi"),
        ]
        fields.append(Field(name: "Extrait du texte affiché",
            detail: includesExcerpt ? "un bref passage visible, filtré, hors champs de saisie" : "non envoyé (option désactivée)"))
        return fields
    }

    static let classification: [Field] = [
        Field(name: "Application, site, titre", detail: "de chaque contexte à classer (clés a, s, t)"),
        Field(name: "Minutes", detail: "la durée de chaque contexte (m)"),
        Field(name: "Voisins", detail: "le contexte avant et après : « travail : tâche » ou « hors travail » (n)"),
        Field(name: "Extrait visible", detail: "un bref passage du texte affiché, si vous l’avez autorisé (x)"),
        Field(name: "Tâches connues", detail: "jusqu’à 20 noms de tâches déjà vus, pour réutiliser le même nom (K)"),
        Field(name: "Réponses passées", detail: "jusqu’à 10 de vos réponses les plus proches : app, site, titre, verdict, tâche (E)"),
        Field(name: "Note du jour", detail: "votre note, filtrée et limitée à 280 caractères (N)"),
        Field(name: "Votre définition du travail", detail: "projets, outils, contenus, et ce qui n’est pas du travail"),
    ]

    static func retryText(at date: Date) -> String {
        "Nouvel essai automatique à \(GoalongUIFormat.time(date))."
    }
}

struct JevSendFieldsList: View {
    let fields: [JevSendFields.Field]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fields, id: \.name) { field in
                (Text(field.name).fontWeight(.medium) + Text(" : " + field.detail).foregroundColor(LHTheme.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Jamais envoyés : captures d’écran, vidéos, fenêtres privées, apps ou sites exclus.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12))
    }
}

/// Summary first, every field behind a disclosure.
struct JevSendFieldsDisclosure: View {
    let includesExcerpt: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(JevSendFields.jevSummary(includesExcerpt: includesExcerpt))
                .font(.callout).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            GoalongDisclosureGroup("Voir tous les champs envoyés") {
                JevSendFieldsList(fields: JevSendFields.jev(includesExcerpt: includesExcerpt)).padding(.top, 8)
            }
            .accessibilityIdentifier("jev-send-fields")
        }
    }
}

struct JevRetryTimeNote: View {
    let at: Date?
    var body: some View {
        if let at {
            Text(JevSendFields.retryText(at: at)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .accessibilityIdentifier("jev-retry-time")
        }
    }
}
#endif
