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
    @ObservedObject private var classification = GoalongUsageClassificationStore.shared
    @State private var search = ""
    @State private var showsAll = false
    @State private var sort: GoalongActivityUsageSort = .duration

    var body: some View {
        let all = items
        let matching = GoalongActivityPresentation.usage(all, search: search, sort: sort)
        let visible = showsAll || !search.isEmpty ? matching : Array(matching.prefix(8))
        return LHCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { title; Spacer(minLength: 8); groupingPicker; exportButton }
                        VStack(alignment: .leading, spacing: 12) { title; HStack { groupingPicker; exportButton } }
                    }
                    HStack(spacing: 14) {
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Rechercher une application ou un site", text: $search)
                                .textFieldStyle(.plain).font(.system(size: 13))
                                .accessibilityIdentifier("activity-usage-search")
                            if !search.isEmpty {
                                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).accessibilityLabel("Effacer la recherche")
                            }
                        }.padding(10).background(LHTheme.secondaryText.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        Picker("Trier les usages", selection: $sort) {
                            ForEach(GoalongActivityUsageSort.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).fixedSize().accessibilityIdentifier("activity-usage-sort")
                    }
                    HStack(spacing: 8) {
                        Text(search.isEmpty ? "\(all.count) usage\(all.count > 1 ? "s" : "") · \(GoalongAnalyticsFormatting.duration(totalSeconds)) observées"
                            : "\(matching.count) résultat(s) · \(GoalongAnalyticsFormatting.duration(matching.reduce(0) { $0 + $1.seconds })) dans la sélection")
                        Spacer(minLength: 0)
                        Text("Durée / part du temps actif")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(20)
                Divider()
                if visible.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(search.isEmpty ? "Aucun usage attribuable pour le moment" : "Aucun usage ne correspond à cette recherche")
                            .font(.system(size: 14, weight: .medium))
                        Text(search.isEmpty ? "Les périodes privées et sans observation restent séparées." : "Essayez le nom d’une application ou un domaine.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(22)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { item in
                            GoalongActivityUsageRow(item: item, total: totalSeconds,
                                rule: isPreview ? nil : classification.verdict(for: item),
                                canClassify: !isPreview && item.classificationKey != nil,
                                onClassify: { classification.set($0, for: item) },
                                onSelect: { onSelect(item) })
                            if item.id != visible.last?.id { Divider().padding(.leading, 70).padding(.trailing, 20) }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if matching.count > 8 && search.isEmpty {
                        Button(showsAll ? "Réduire la liste" : "Voir les \(matching.count) usages") { showsAll.toggle() }
                            .buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
                            .accessibilityIdentifier("activity-usage-show-all")
                    }
                    Text(grouping == .sites
                        ? "Un site remplace le temps de son navigateur : aucune minute n’est comptée deux fois. Cliquez sur un usage pour voir ses horaires, ou sur son étiquette pour le classer."
                        : "Les sites sont inclus dans leur navigateur. Le total reste identique ; seule la répartition change.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = classification.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    }
                }.padding(20)
            }
        }
        .onChange(of: grouping) { _ in showsAll = false }
        .onChange(of: sort) { _ in showsAll = false }
        .accessibilityIdentifier("activity-usage")
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Applications et sites").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("Où est passé votre temps ?").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var exportButton: some View {
        if let onExport {
            Button(action: onExport) { Label("Exporter", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered).controlSize(.small).disabled(isPreview || items.isEmpty)
                .help("Exporter les durées par jour, application et site (CSV)")
                .accessibilityIdentifier("activity-usage-export")
        }
    }

    private var groupingPicker: some View {
        Picker("Regrouper les usages", selection: $grouping) {
            ForEach(GoalongActivityUsageGrouping.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
            .accessibilityIdentifier("activity-usage-grouping")
    }
}

struct GoalongActivityUsageRow: View {
    let item: GoalongActivityUsageItem
    let total: TimeInterval
    var rule: GoalongUsageClass? = nil
    var canClassify = false
    var onClassify: (GoalongUsageClass?) -> Void = { _ in }
    let onSelect: () -> Void
    @State private var hovering = false
    private var share: Double { min(1, max(0, item.seconds / max(1, total))) }
    private var shownClass: GoalongUsageClass? { rule ?? item.dominantClass }
    private var barColor: Color {
        switch shownClass {
        case .work?: return GoalongActivityClassStyle.color(.work)
        case .other?: return GoalongActivityClassStyle.color(.other)
        case nil: return GoalongActivityClassStyle.color(.unclassified)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 14) {
                    GoalongActivityUsageIcon(item: item, size: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1).help(item.displayName)
                            Spacer(minLength: 12)
                            if let delta { deltaLabel(delta) }
                            Text(GoalongAnalyticsFormatting.duration(item.seconds))
                                .font(.system(size: 14, weight: .semibold)).monospacedDigit().fixedSize()
                            Text(String(format: "%.0f %%", share * 100))
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 43, alignment: .trailing)
                        }
                        HStack(spacing: 14) {
                            Text(item.isWebsite ? "Site web" : "Application").font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 68, alignment: .leading)
                            GeometryReader { geometry in
                                Capsule().fill(LHTheme.separator.opacity(0.6))
                                Capsule().fill(barColor).frame(width: geometry.size.width * share)
                            }.frame(height: 4).accessibilityHidden(true)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.displayName)
            .accessibilityValue("\(GoalongAnalyticsFormatting.duration(item.seconds)), \(Int((share * 100).rounded())) pour cent du temps actif, \(classLabel)")
            .accessibilityHint("Ouvrir les horaires et la répartition par journée")
            classMenu
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? LHTheme.text : LHTheme.secondaryText).padding(.leading, 2)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(hovering ? LHTheme.accent.opacity(0.055) : Color.clear)
        .onHover { hovering = $0 }
    }

    private var delta: TimeInterval? {
        guard let before = item.previousSeconds else { return nil }
        let value = item.seconds - before
        return abs(value) >= 300 ? value : nil
    }

    private func deltaLabel(_ value: TimeInterval) -> some View {
        Text((value > 0 ? "+" : "−") + GoalongAnalyticsFormatting.duration(abs(value)))
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
            .help("Par rapport à la période précédente de même durée")
    }

    private var classLabel: String {
        switch (rule, item.dominantClass) {
        case (.work?, _): return "Travail"
        case (.other?, _): return "Hors travail"
        case (nil, .work?): return "Travail · auto"
        case (nil, .other?): return "Hors travail · auto"
        case (nil, nil): return "À classer"
        }
    }

    @ViewBuilder private var classMenu: some View {
        if canClassify {
            // A native pull-down button: visibly clickable, keyboard accessible.
            Menu {
                Button { onClassify(.work) } label: { Label("Travail", systemImage: rule == .work ? "checkmark" : "briefcase") }
                Button { onClassify(.other) } label: { Label("Hors travail", systemImage: rule == .other ? "checkmark" : "cup.and.saucer") }
                Divider()
                Button { onClassify(nil) } label: { Label("Classement automatique", systemImage: rule == nil ? "checkmark" : "wand.and.stars") }
            } label: {
                Text(classLabel).font(.system(size: 11, weight: rule == nil ? .regular : .semibold))
            }
            .menuIndicator(.hidden).controlSize(.small).fixedSize()
            .help("Classer \(item.displayName) : s’applique à tout votre historique, sans modifier les journaux.")
            .accessibilityLabel("Classement de \(item.displayName) : \(classLabel)")
            .accessibilityIdentifier("activity-usage-class")
        } else {
            Text(classLabel).font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText).fixedSize()
                .accessibilityHidden(true)
        }
    }
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
