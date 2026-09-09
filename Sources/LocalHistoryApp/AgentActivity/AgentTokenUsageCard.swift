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
                    Label("AI usage · selected day", systemImage: "chart.bar")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if scanning { ProgressView().controlSize(.small) }
                }
                Text(usage.observedTotal.map { $0.formatted() + " tokens observed" } ?? "Usage unavailable")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Local logs · \(TimeZone.current.identifier). Tokens are not subscription quotas or a bill.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let analyzedAt {
                    Text("Analyzed \(analyzedAt.formatted(date: .omitted, time: .shortened)) · Refresh the day to update")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if usage.partial || usage.rows.isEmpty {
                    Text("Partial coverage: missing counters and unavailable sources remain unknown. Forks with replayed history may be excluded.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(Array(Set(usage.rows.map { $0.provider.rawValue })).sorted(), id: \.self) { provider in
                    let totals = usage.rows.filter { $0.provider.rawValue == provider }.flatMap(\.events).compactMap(\.total)
                    Text("\(provider): \(totals.isEmpty ? "Unknown" : totals.reduce(0, +).formatted()) tokens observed")
                        .font(.system(size: 12, weight: .medium))
                }
                DisclosureGroup("Provider, model & conversation details") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(usage.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.provider.rawValue) · \(row.model)").fontWeight(.semibold)
                                Text(row.session).lineLimit(1)
                                Text("Input \(number(row.sum(\.input))) · Output \(number(row.sum(\.output))) · Total \(number(row.sum(\.total)))")
                                Text("Cache read \(number(row.sum(\.cacheRead))) · Cache write \(number(row.sum(\.cacheWrite))) · Reasoning \(number(row.sum(\.reasoning)))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Input includes identified cache tokens. Codex reasoning is included in output; neither is added again to the total. OpenCode totals are shown only when explicitly recorded. Unknown means the log does not establish the value. These day totals are independent of conversation search filters.")
                            .foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(.top, 8)
                }.font(.system(size: 12))
            }
        }
    }
    private func number(_ value: Int64?) -> String { value?.formatted() ?? "Unknown" }
}
#endif
