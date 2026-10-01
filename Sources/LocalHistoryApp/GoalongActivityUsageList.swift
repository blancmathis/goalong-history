#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// An explorable ranking of one set of foreground intervals, not a second total.
struct GoalongActivityUsageList: View {
    let items: [GoalongActivityUsageItem]
    let totalSeconds: TimeInterval
    @Binding var grouping: GoalongActivityUsageGrouping
    var isPreview = false
    var onExport: (() -> Void)? = nil
    let onSelect: (GoalongActivityUsageItem) -> Void
    @State private var search = ""
    @State private var showsAll = false
    @State private var sort: GoalongActivityUsageSort = .duration

    var body: some View {
        let all = items
        let matching = GoalongActivityPresentation.usage(all, search: search, sort: sort)
        let visible = showsAll || !search.isEmpty ? matching : Array(matching.prefix(8))
        return GoalongSection(title: "Applications et sites") {
            HStack(spacing: 10) {
                GoalongHelpButton(text: grouping == .sites
                    ? "Un site remplace le temps de son navigateur : aucune minute n’est comptée deux fois. Cliquez sur un usage pour voir ses horaires et les tâches qu’il a servies."
                    : "Les sites sont inclus dans leur navigateur. Le total reste identique ; seule la répartition change.")
                groupingPicker
                exportButton
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    GoalongSearchField("Rechercher une application ou un site", text: $search, identifier: "activity-usage-search",
                                       trailing: search.isEmpty ? nil : "\(matching.count) résultat\(matching.count > 1 ? "s" : "")")
                    Picker("Trier les usages", selection: $sort) {
                        ForEach(GoalongActivityUsageSort.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize().accessibilityIdentifier("activity-usage-sort")
                }
                LHCard(padding: 0) {
                    if visible.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(search.isEmpty ? "Aucun usage attribuable pour le moment" : "Aucun usage ne correspond à cette recherche")
                                .font(.system(size: 13, weight: .medium))
                            Text(search.isEmpty ? "Les périodes privées et sans observation restent séparées." : "Essayez le nom d’une application ou un domaine.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(LHTheme.cardInset)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { item in
                                GoalongActivityUsageRow(item: item, total: totalSeconds, onSelect: { onSelect(item) })
                                if item.id != visible.last?.id { GoalongRowDivider(inset: LHTheme.cardInset + 40) }
                            }
                        }
                    }
                }
                if matching.count > 8 && search.isEmpty {
                    Button(showsAll ? "Réduire la liste" : "Voir les \(matching.count) usages") { showsAll.toggle() }
                        .buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                        .accessibilityIdentifier("activity-usage-show-all")
                }
            }
        }
        .onChange(of: grouping) { _ in showsAll = false }
        .onChange(of: sort) { _ in showsAll = false }
        .accessibilityIdentifier("activity-usage")
    }

    @ViewBuilder private var exportButton: some View {
        if let onExport {
            Button(action: onExport) { Label("Exporter", systemImage: "square.and.arrow.down") }
                .buttonStyle(LHSecondaryButtonStyle()).controlSize(.small).disabled(isPreview || items.isEmpty)
                .help("Exporter les durées par jour, application et site (CSV)")
                .accessibilityIdentifier("activity-usage-export")
        }
    }

    private var groupingPicker: some View {
        GoalongSegmentedControl("Regrouper les usages", selection: $grouping,
                                options: GoalongActivityUsageGrouping.allCases) { $0.title }
            .controlSize(.small)
            .accessibilityIdentifier("activity-usage-grouping")
    }
}

/// One usage: what, how long, which share, and what that time was. The whole row opens it.
struct GoalongActivityUsageRow: View {
    let item: GoalongActivityUsageItem
    let total: TimeInterval
    let onSelect: () -> Void
    private var share: Double { min(1, max(0, item.seconds / max(1, total))) }
    private var barColor: Color {
        switch item.dominantClass {
        case .work?: return GoalongActivityClassStyle.color(.work)
        case .other?: return GoalongActivityClassStyle.color(.other)
        case nil: return GoalongActivityClassStyle.color(.unclassified)
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                GoalongActivityUsageIcon(item: item, size: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 12)
                        if let delta { deltaLabel(delta) }
                        Text(classLabel).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize()
                        Text(GoalongAnalyticsFormatting.duration(item.seconds))
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .frame(minWidth: 58, alignment: .trailing).fixedSize()
                        Text(String(format: "%.0f %%", share * 100))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(LHTheme.secondaryText)
                            .frame(width: 40, alignment: .trailing)
                    }
                    GoalongShareBar(share: share, color: barColor)
                }
                GoalongRowChevron(size: 10)
            }
            .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(LHNavigationButtonStyle(cornerRadius: 0))
        .help(item.mainTasks.isEmpty ? item.displayName
              : "Tâches : " + item.mainTasks.prefix(3).map(\.name).joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityValue("\(GoalongAnalyticsFormatting.duration(item.seconds)), \(Int((share * 100).rounded())) pour cent du temps actif, \(classLabel)")
        .accessibilityHint("Ouvrir les horaires et la répartition par journée")
        .accessibilityAddTraits(.isButton)
    }

    private var delta: TimeInterval? {
        guard let before = item.previousSeconds else { return nil }
        let value = item.seconds - before
        return abs(value) >= 300 ? value : nil
    }

    private func deltaLabel(_ value: TimeInterval) -> some View {
        Text((value > 0 ? "+" : "−") + GoalongAnalyticsFormatting.duration(abs(value)))
            .font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(LHTheme.tertiaryText)
            .help("Par rapport à la période précédente de même durée")
    }

    private var classLabel: String { item.classLabel }
}

struct GoalongActivityUsageIcon: View {
    let item: GoalongActivityUsageItem
    var size: CGFloat = 36
    var body: some View {
        Group {
            if item.isWebsite { WebsiteIconView(host: item.name, size: size) }
            else { AppIconView(bundleIdentifier: item.bundleIdentifier, appName: item.displayName, size: size) }
        }
    }
}
#endif
