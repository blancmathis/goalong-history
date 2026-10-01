#if os(macOS)
import SwiftUI
import AgentActivity

struct AgentTokenUsageCard: View {
    let usage: AgentDailyTokenUsage
    let scanning: Bool
    let analyzedAt: Date?
    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Usage de l’IA · jour sélectionné", systemImage: "chart.bar")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if scanning { ProgressView().controlSize(.small) }
                }
                Text(usage.observedTotal.map { $0.formatted(.number.locale(Self.locale)) + " tokens observés" } ?? "Usage indisponible")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Journaux locaux · fuseau \(TimeZone.current.identifier). Les tokens ne correspondent ni à un quota d’abonnement ni à une facture.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let analyzedAt {
                    Text("Analysé à \(analyzedAt.formatted(.dateTime.hour().minute().locale(Self.locale))) · actualisez la journée pour mettre à jour")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if usage.partial || usage.rows.isEmpty {
                    Text("Couverture partielle : les compteurs manquants et sources indisponibles restent inconnus. Les copies de conversations rejouées peuvent être exclues.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(Array(Set(usage.rows.map { $0.provider.rawValue })).sorted(), id: \.self) { provider in
                    let totals = usage.rows.filter { $0.provider.rawValue == provider }.flatMap(\.events).compactMap(\.total)
                    Text("\(provider) : \(totals.isEmpty ? "inconnu" : totals.reduce(0, +).formatted(.number.locale(Self.locale)) + " tokens observés")")
                        .font(.system(size: 12, weight: .medium))
                }
                GoalongDisclosureGroup("Détails par outil, modèle et conversation") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(usage.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.provider.rawValue) · \(row.model)").fontWeight(.semibold)
                                Text(row.session).lineLimit(1)
                                Text("Entrée \(number(row.sum(\.input))) · Sortie \(number(row.sum(\.output))) · Total \(number(row.sum(\.total)))")
                                Text("Cache lu \(number(row.sum(\.cacheRead))) · Cache écrit \(number(row.sum(\.cacheWrite))) · Raisonnement \(number(row.sum(\.reasoning)))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("L’entrée inclut les tokens de cache identifiés. Le raisonnement de Codex est inclus dans la sortie ; aucun des deux n’est ajouté une seconde fois au total. Les totaux OpenCode ne sont affichés que lorsqu’ils sont enregistrés explicitement. « Inconnu » signifie que le journal ne permet pas d’établir la valeur. Ces totaux du jour ne dépendent pas des filtres de recherche.")
                            .foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(.top, 8)
                }.font(.system(size: 12))
            }
        }
    }
    private func number(_ value: Int64?) -> String { value.map { $0.formatted(.number.locale(Self.locale)) } ?? "inconnu" }
    private static let locale = Locale(identifier: "fr_FR")
}
#endif
