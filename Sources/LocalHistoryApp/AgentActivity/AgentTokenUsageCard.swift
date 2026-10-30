#if os(macOS)
import SwiftUI
import AgentActivity

struct AgentTokenUsageCard: View {
    /// Nil until the selected day has a complete analysis (selecting a day clears it).
    let usage: AgentDailyTokenUsage?
    let scanning: Bool
    let analyzedAt: Date?

    /// What the card says about the day: still loading, no AI conversation, or real figures.
    struct Summary: Equatable {
        var headline: String
        var detail: String?
        var showsPartialCoverage: Bool
    }

    static func summary(usage: AgentDailyTokenUsage?, scanning: Bool) -> Summary {
        guard let usage else {
            return scanning
                ? Summary(headline: "Analyse du jour en cours…", detail: nil, showsPartialCoverage: false)
                : Summary(headline: "Usage indisponible",
                          detail: "Ce jour n’a pas encore été analysé entièrement. Actualisez la journée pour relancer l’analyse.",
                          showsPartialCoverage: false)
        }
        if usage.rows.isEmpty && !usage.partial {
            return Summary(headline: "Aucune conversation IA ce jour", detail: nil, showsPartialCoverage: false)
        }
        let headline = usage.observedTotal.map { $0.formatted(.number.locale(locale)) + " tokens observés" } ?? "Usage indisponible"
        return Summary(headline: headline, detail: nil, showsPartialCoverage: usage.partial)
    }

    /// Readable zone name (« heure d’Europe centrale »), not the raw identifier.
    static func zoneName(_ zone: TimeZone = .current) -> String {
        zone.localizedName(for: .generic, locale: locale) ?? zone.identifier
    }

    var body: some View {
        let summary = Self.summary(usage: usage, scanning: scanning)
        let rows = usage?.rows ?? []
        LHCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Usage de l’IA, jour sélectionné", systemImage: "chart.bar")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if scanning { ProgressView().controlSize(.small) }
                }
                Text(summary.headline)
                    .font(LHTheme.figureFont(26))
                if let detail = summary.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                Text("Journaux locaux, \(Self.zoneName()). Les tokens ne correspondent ni à un quota d’abonnement ni à une facture.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                if let analyzedAt {
                    Text("Analysé à \(analyzedAt.formatted(.dateTime.hour().minute().locale(Self.locale))), actualisez la journée pour mettre à jour")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                if summary.showsPartialCoverage {
                    Text("Couverture partielle : les compteurs manquants et sources indisponibles restent inconnus. Les copies de conversations rejouées peuvent être exclues.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                ForEach(Array(Set(rows.map(\.provider))).sorted { $0.frenchName.localizedStandardCompare($1.frenchName) == .orderedAscending }) { provider in
                    let totals = rows.filter { $0.provider == provider }.flatMap(\.events).compactMap(\.total)
                    Text("\(provider.frenchName) : \(totals.isEmpty ? "inconnu" : totals.reduce(0, +).formatted(.number.locale(Self.locale)) + " tokens observés")")
                        .font(.system(size: 12, weight: .medium))
                }
                if !rows.isEmpty {
                GoalongDisclosureGroup("Détails par outil, modèle et conversation") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.provider.frenchName), \(row.model)").fontWeight(.semibold)
                                Text(row.session).lineLimit(1)
                                Text("Entrée \(number(row.sum(\.input))), Sortie \(number(row.sum(\.output))), Total \(number(row.sum(\.total)))")
                                Text("Cache lu \(number(row.sum(\.cacheRead))), Cache écrit \(number(row.sum(\.cacheWrite))), Raisonnement \(number(row.sum(\.reasoning)))")
                                    .foregroundStyle(LHTheme.secondaryText)
                            }
                        }
                        Text("L’entrée inclut les tokens de cache identifiés. Le raisonnement de Codex est inclus dans la sortie ; aucun des deux n’est ajouté une seconde fois au total. Les totaux OpenCode ne sont affichés que lorsqu’ils sont enregistrés explicitement. « Inconnu » signifie que le journal ne permet pas d’établir la valeur. Ces totaux du jour ne dépendent pas des filtres de recherche.")
                            .foregroundStyle(LHTheme.secondaryText)
                    }.font(.system(size: 12)).padding(.top, 8)
                }.font(.system(size: 12))
                }
            }
        }
    }
    private func number(_ value: Int64?) -> String { value.map { $0.formatted(.number.locale(Self.locale)) } ?? "inconnu" }
    static let locale = Locale(identifier: "fr_FR")
}
#endif
