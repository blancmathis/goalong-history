#if os(macOS)
import Foundation
import SwiftUI
import Charts
import LocalHistoryCore

/// Pure presentation. Native snapshot tests render this without opening user stores.
struct GoalongAnalyticsContent: View {
    let payload: GoalongAnalyticsPayload
    @Binding var focusMinutes: Int
    var onDay: (Date) -> Void = { _ in }
    var onHistory: () -> Void = {}
    var onProjects: () -> Void = {}
    var onHistoryDay: (Date) -> Void = { _ in }
    var onRecap: (Date) -> Void = { _ in }
    @State private var grouping: GoalongActivityUsageGrouping = .sites
    @State private var allCards = false
    @State private var module = "all"
    @State private var hourly = true
    @State private var fullDay = false
    @State private var selectedUsage: GoalongActivityUsageItem?
    @State private var showingAllToClassify = false
    @State private var exportMessage: String?
    @ObservedObject private var classification = GoalongUsageClassificationStore.shared

    private var current: GoalongLocalAnalytics.Period { payload.current }
    private var isDay: Bool { current.days.count == 1 }
    private var focus: [GoalongLocalAnalytics.Focus] { current.focus(minimumMinutes: focusMinutes) }
    private var focusSeconds: Double { current.focusSeconds(minimumMinutes: focusMinutes) }
    private var sparse: Bool { current.activeSeconds > 0 && current.activeSeconds < 600 }
    private var summary: GoalongActivitySummary {
        GoalongActivitySummary(period: current, previous: payload.previous, now: payload.isPreview ? payload.updatedAt : Date())
    }
    private var usageItems: [GoalongActivityUsageItem] {
        GoalongActivityProjection.usage(current, grouping: grouping, previous: payload.previous)
    }
    /// Main usages that are neither ruled nor classified automatically, by time.
    private var itemsToClassify: [GoalongActivityUsageItem] {
        guard !payload.isPreview else { return [] }
        return usageItems.filter { $0.classificationKey != nil && classification.verdict(for: $0) == nil && $0.dominantClass == nil
            && $0.unclassifiedSeconds >= 60 }
            .sorted { $0.unclassifiedSeconds > $1.unclassifiedSeconds }
    }

    var body: some View {
        let summary = self.summary
        let items = usageItems
        let showsClassification = showsClassificationCard(summary)
        VStack(alignment: .leading, spacing: 20) {
            coverage
            if current.observedSeconds > 0 {
                metrics(summary)
                insightsCard(summary, items: items, showsClassification: showsClassification)
                if showsClassification { classificationCard(summary) }
                rhythmCard
                if !isDay && current.observedDays.count >= 2 { heatmapCard(summary) }
                usageCard(items)
                projectsCard
                rhythmDetails
            } else {
                emptyState
                projectsCard
            }
            methodology
            HStack {
                Label(payload.isPreview ? "Données fictives · non enregistrées" : "Calcul local · aucun envoi", systemImage: "internaldrive")
                Spacer()
                Text("Actualisé à \(time(payload.updatedAt))")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .sheet(item: $selectedUsage) { item in
            GoalongActivityUsageDetail(item: item, period: current, grouping: grouping,
                isPreview: payload.isPreview, onHistoryDay: { day in
                    selectedUsage = nil
                    if !payload.isPreview { onHistoryDay(day) }
                })
        }
        .sheet(isPresented: $showingAllToClassify) { classificationSheet }
        .accessibilityIdentifier("activity-content")
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(payload.isPreview ? "Simulation locale" : "Observations Goalong · Ce Mac", systemImage: "lock.shield")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if !isDay {
                    Text("\(current.daysWithObservations)/\(current.days.count) jours avec activité mesurée")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if current.incompleteDays > 0 {
                Label("\(current.incompleteDays) jour(s) illisible(s) ou incomplet(s), exclus des totaux. Actualisez ou consultez l’historique.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(LHTheme.warning)
            } else if !isDay && current.daysWithObservations < current.days.count {
                Label("Les jours sans données restent vides : ils ne sont pas comptés comme des journées à zéro.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if payload.isPreview {
                Text("Journées complètes simulées, y compris aujourd’hui. Ces chiffres ne représentent pas votre activité.")
                    .foregroundStyle(LHTheme.warning)
            } else if current.days.contains(where: { Calendar.current.isDateInToday($0.date) }) {
                Text("Journée en cours · seules les observations reçues sont incluses.").foregroundStyle(.secondary)
            }
            if sparse {
                Text("Vos premières observations sont déjà visibles. Le graphique adapte son échelle aux petites durées.")
                    .foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    private func metrics(_ summary: GoalongActivitySummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                activeTile(summary); workTile(summary); concentrationTile(summary); switchesTile(summary)
            }.frame(minWidth: 880)
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) { activeTile(summary); workTile(summary) }
                HStack(alignment: .top, spacing: 12) { concentrationTile(summary); switchesTile(summary) }
            }
        }.accessibilityIdentifier("activity-primary-metrics")
    }

    private func activeTile(_ summary: GoalongActivitySummary) -> some View {
        let detail: String
        if let bounds = summary.dayBounds {
            detail = "De \(GoalongActivitySummary.time(bounds.start)) à \(GoalongActivitySummary.time(bounds.end))"
        } else if isDay {
            detail = "Activité observée au premier plan"
        } else {
            detail = "Total \(duration(current.activeSeconds)) · \(current.daysWithObservations)/\(current.days.count) jours observés"
                + (summary.averageExcludesToday ? " · moyenne sans aujourd’hui, en cours" : "")
        }
        let value = isDay ? duration(current.activeSeconds) : (summary.averageActivePerDay.map(duration) ?? "—")
        return metric("Temps actif", value: value, unit: isDay ? nil : "/ jour", detail: detail,
                      comparison: summary.comparison, primary: true)
    }

    private func workTile(_ summary: GoalongActivitySummary) -> some View {
        if summary.workIsMeasurable {
            let value = isDay ? duration(summary.workSeconds) : (summary.averageWorkPerDay.map(duration) ?? "—")
            return metric("Travail", value: value, unit: isDay ? nil : "/ jour",
                          detail: "\(percent(summary.workShare)) du temps actif · \(percent(summary.otherSeconds / max(1, summary.activeSeconds))) hors travail")
        }
        return metric("Travail", value: "À classer", detail: summary.activeSeconds > 0
            ? "\(percent(summary.unclassifiedShare)) du temps n’est pas encore classé. Classez vos usages ci-dessous."
            : "Aucune activité à classer", compact: true)
    }

    private func concentrationTile(_ summary: GoalongActivitySummary) -> some View {
        if summary.workIsMeasurable, let block = summary.longestWorkBlock {
            let blocks = summary.workBlocks.count
            return metric("Concentration", value: duration(block.workSeconds),
                          detail: "Plus long bloc de travail · \(blocks) bloc\(blocks > 1 ? "s" : "") de 25 min ou plus")
        }
        let longest = summary.longestSequence
        return metric("Concentration", value: longest.map { duration($0.seconds) } ?? "—",
                      detail: longest.map { "Plus longue période dans \(GoalongActivityPresentation.displayName($0.host ?? $0.application))" }
                        ?? "Aucune période continue mesurée")
    }

    private func switchesTile(_ summary: GoalongActivitySummary) -> some View {
        guard let perHour = summary.changesPerActiveHour, let every = summary.secondsPerChange else {
            return metric("Changements d’app", value: "—", detail: "Pas assez d’activité pour mesurer les changements")
        }
        return metric("Changements d’app", value: "\(Int(perHour.rounded()))", unit: "/ h",
                      detail: "Un changement d’app ou de site toutes les \(GoalongActivitySummary.shortInterval(every)) · \(summary.contextChanges) au total")
    }

    private func metric(_ title: String, value: String, unit: String? = nil, detail: String,
                        comparison: GoalongActivitySummary.Comparison? = nil, primary: Bool = false,
                        compact: Bool = false) -> some View {
        LHCard(padding: 17) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: compact ? 22 : (primary ? 30 : 26), weight: .semibold))
                        .tracking(-0.6).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(primary ? LHTheme.accent : LHTheme.text)
                    if let unit { Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
                }
                if let comparison, abs(comparison.delta) >= 60 {
                    let up = comparison.delta > 0
                    Label("\(up ? "+" : "−")\(duration(abs(comparison.delta))) vs \(comparison.label)",
                          systemImage: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }.accessibilityElement(children: .combine)
    }

    // MARK: - Insights and classification

    private func showsClassificationCard(_ summary: GoalongActivitySummary) -> Bool {
        !itemsToClassify.isEmpty && summary.unclassifiedShare >= 0.15
    }

    /// "À retenir" only adds what the four tiles and the classification card do not already say.
    static func additionalInsights(_ insights: [GoalongActivitySummary.Insight], isDay: Bool,
                                   showsClassification: Bool) -> [GoalongActivitySummary.Insight] {
        insights.filter { insight in
            switch insight.id {
            case "switches", "comparison", "work": return false
            case "bounds": return !isDay
            case "classify": return !showsClassification
            default: return true
            }
        }
    }

    private func insightsCard(_ summary: GoalongActivitySummary, items: [GoalongActivityUsageItem],
                              showsClassification: Bool) -> some View {
        let insights = Self.additionalInsights(
            summary.insights(topUsage: items.first, biggestChange: GoalongActivitySummary.biggestChange(items)),
            isDay: isDay, showsClassification: showsClassification)
        return Group {
            if !insights.isEmpty {
                LHCard {
                    VStack(alignment: .leading, spacing: 12) {
                        heading("À retenir")
                        ForEach(insights) { insight in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: insight.symbol).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(insight.tone == .attention ? LHTheme.warning
                                        : insight.tone == .positive ? LHTheme.success : LHTheme.accent)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(insight.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("activity-insights")
            }
        }
    }

    private func classificationCard(_ summary: GoalongActivitySummary) -> some View {
        let pending = itemsToClassify
        return LHCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    heading("Classez vos usages pour mesurer votre travail")
                    Text("\(percent(summary.unclassifiedShare)) de votre temps actif n’est pas encore classé. Un clic suffit : le choix s’applique à tout votre historique, passé et futur, et reste modifiable dans la liste des applications.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(pending.prefix(6))) { item in
                        classificationRow(item)
                        if item.id != pending.prefix(6).last?.id { Divider() }
                    }
                }
                if pending.count > 6 {
                    Button("Voir les \(pending.count) usages à classer") { showingAllToClassify = true }
                        .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                }
            }
        }.accessibilityIdentifier("activity-classification")
    }

    private func classificationRow(_ item: GoalongActivityUsageItem) -> some View {
        HStack(spacing: 12) {
            GoalongActivityUsageIcon(item: item, size: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(duration(item.unclassifiedSeconds)) à classer · \(item.isWebsite ? "site web" : "application")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { classification.set(.work, for: item) } label: { Label("Travail", systemImage: "briefcase") }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Classer \(item.displayName) comme travail")
            Button { classification.set(.other, for: item) } label: { Label("Hors travail", systemImage: "cup.and.saucer") }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Classer \(item.displayName) hors travail")
        }.padding(.vertical, 8)
    }

    private var classificationSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usages à classer").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Terminé") { showingAllToClassify = false }.keyboardShortcut(.defaultAction)
            }
            Text("Travail ou hors travail : le choix s’applique à tout l’historique et reste modifiable.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(itemsToClassify) { item in
                        classificationRow(item)
                        Divider()
                    }
                    if itemsToClassify.isEmpty {
                        Label("Tous vos usages de cette période sont classés.", systemImage: "checkmark.circle")
                            .foregroundStyle(LHTheme.success).padding(.vertical, 20)
                    }
                }
            }.frame(maxHeight: 460)
        }.padding(24).frame(width: 560)
    }

    // MARK: - Rhythm

    private var rhythmCard: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        heading(isDay ? "Rythme de la journée" : "Rythme sur \(current.days.count) jours")
                        Text(isDay ? (hourly || sparse ? "Temps actif par heure, selon son classement" : "Quelle app ou quel site, à quel moment")
                             : "Temps actif par jour · cliquez sur un jour pour l’ouvrir")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDay {
                        Toggle("Journée entière", isOn: $fullDay).toggleStyle(.checkbox)
                            .font(.system(size: 12)).fixedSize().accessibilityIdentifier("activity-full-day")
                        Picker("Affichage du rythme", selection: $hourly) {
                            Text("Par heure").tag(true)
                            Text("Chronologie").tag(false)
                        }.labelsHidden().pickerStyle(.segmented).fixedSize().disabled(sparse)
                            .accessibilityIdentifier("activity-rhythm-mode")
                    }
                }
                if isDay, let day = current.days.first {
                    if hourly || sparse {
                        GoalongHourlyClassChart(day: day, dateRange: chartDateRange, hourStride: hourStride)
                    } else {
                        GoalongUsageTimelineChart(day: day, grouping: grouping, dateRange: chartDateRange, hourStride: hourStride)
                    }
                    GoalongActivityClassLegend()
                    GoalongDisclosureGroup("Heures et valeurs") {
                        VStack(spacing: 8) {
                            ForEach(day.hours(minimumMinutes: focusMinutes).filter { $0.seconds > 0 }) { hour in
                                HStack {
                                    Text("\(time(hour.start))–\(time(hour.end))")
                                    Spacer()
                                    Text(duration(hour.seconds) + " actives")
                                    if hour.workSeconds > 0 { Text("· " + duration(hour.workSeconds) + " de travail").foregroundStyle(.secondary) }
                                }.font(.system(size: 12)).accessibilityElement(children: .combine)
                            }
                            Text(fullDay ? "Vue complète · les heures sans données restent non observées."
                                : "Vue centrée sur les heures observées · cochez Journée entière pour afficher 0 h – 24 h.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Examiner cette journée dans l’historique") { onHistoryDay(day.date) }
                                .buttonStyle(.borderless).disabled(payload.isPreview)
                        }.padding(.top, 10)
                    }.font(.system(size: 12))
                } else {
                    GoalongDailyClassChart(period: current, dateRange: dateRange, onDay: onDay)
                    GoalongActivityClassLegend()
                    GoalongDisclosureGroup("Explorer les jours et leurs valeurs") {
                        VStack(spacing: 0) {
                            ForEach(current.days) { day in
                                Button { onDay(day.date) } label: {
                                    HStack {
                                        Text(GoalongActivitySummary.weekdayDate(day.date)).frame(width: 110, alignment: .leading)
                                        Text(GoalongActivityProjection.dayLabel(day))
                                        if day.seconds(.work) > 0 {
                                            Text("· \(duration(day.seconds(.work))) de travail").foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right").font(.caption)
                                    }.font(.system(size: 12)).padding(.vertical, 9).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Explorer le \(shortDate(day.date))")
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                }
            }
        }.accessibilityIdentifier("activity-primary-chart")
    }

    private func heatmapCard(_ summary: GoalongActivitySummary) -> some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    heading("Quand êtes-vous actif ?")
                    Text("Minutes actives en moyenne, par jour de la semaine et par heure")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                GoalongWeekHourHeatmap(period: current)
            }
        }
    }

    private func usageCard(_ items: [GoalongActivityUsageItem]) -> some View {
        // Aggregate outside the search view: typing only filters the small usage list.
        VStack(alignment: .leading, spacing: 8) {
            GoalongActivityUsageList(items: items, totalSeconds: current.activeSeconds, grouping: $grouping,
                isPreview: payload.isPreview,
                onExport: {
                    exportMessage = GoalongActivityExport.save(period: current, grouping: grouping, rules: classification.rules)
                }) { selectedUsage = $0 }
            if let exportMessage {
                Label(exportMessage, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
        }
    }

    private var projectsCard: some View {
        let cards = payload.cards.filter { module == "all" || $0.module == module }
        let visible = allCards ? cards : Array(cards.prefix(3))
        return LHCard {
            VStack(alignment: .leading, spacing: 14) {
                heading("Bilan et projets")
                if !payload.cards.isEmpty {
                    Picker("Rubrique", selection: $module) {
                        Text("Tous les éléments").tag("all")
                        Text("Bilans quotidiens").tag("dailyRecap")
                        ForEach(GoalongProfileAnalysis.modules, id: \.self) { key in
                            Text(GoalongProfileAnalysis.labels[key] ?? key).tag(key)
                        }
                    }.pickerStyle(.menu).labelsHidden().frame(maxWidth: 280, alignment: .leading)
                }
                if cards.isEmpty {
                    Text(payload.cards.isEmpty ? "Aucun bilan enregistré sur cette période. L’analyse IA est facultative." : "Aucun élément enregistré dans cette rubrique.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(visible) { card in
                    GoalongDisclosureGroup {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(.init(card.summary)).textSelection(.enabled)
                            if !card.caveat.isEmpty { Label(card.caveat, systemImage: "info.circle").foregroundStyle(.secondary) }
                            if card.module == "dailyRecap", let day = cardDay(card.day) {
                                Button("Ouvrir le bilan et ses sources") { onRecap(day) }
                                    .buttonStyle(.borderless).disabled(payload.isPreview)
                            }
                        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 9)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card.title).font(.system(size: 13, weight: .medium))
                            Text("\(cardDay(card.day).map { GoalongUIFormat.day($0) } ?? card.day) · \(payload.isPreview ? "Exemple fictif · " : "")\(statusLabel(card.status))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if cards.count > 3 {
                    Button(allCards ? "Réduire" : "Voir les \(cards.count) éléments") { allCards.toggle() }
                        .buttonStyle(.borderless).font(.system(size: 12))
                }
                Button(isDay ? "Comprendre mon travail" : "Analyser une journée…", action: onProjects)
                    .buttonStyle(.bordered).controlSize(.small).disabled(payload.isPreview).accessibilityIdentifier("analytics-projects")
                if let notice = payload.archiveNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(LHTheme.warning)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("activity-reports")
    }

    private var rhythmDetails: some View {
        LHCard {
            GoalongDisclosureGroup("Détails : focus, blocs de travail et comparaison") {
                VStack(alignment: .leading, spacing: 18) {
                    GoalongFocusExplanation(hasFocus: !focus.isEmpty, minimumMinutes: $focusMinutes)
                    HStack(alignment: .top, spacing: 24) {
                        detailValue("Focus observé", duration(focusSeconds), "\(focus.count) séquence(s) ≥ \(focusMinutes) min")
                        detailValue("Plus longue séquence", duration(current.days.flatMap(\.sequences).map(\.seconds).max() ?? 0),
                                    "même application et même site")
                        detailValue("Changements de contexte", "\(current.contextChanges)", "app ou site différent")
                        Spacer(minLength: 0)
                    }
                    if !focus.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Plus longues séquences de focus").font(.system(size: 12, weight: .semibold))
                            ForEach(focus.sorted { $0.seconds > $1.seconds }.prefix(5)) { block in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(GoalongActivityPresentation.displayName(block.host ?? block.application)).font(.system(size: 13, weight: .medium))
                                        Text("\(shortDate(block.start)) · \(time(block.start))–\(time(block.end))")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(duration(block.seconds)).font(.system(size: 13)).monospacedDigit()
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                    let blocks = current.workBlocks(minimumMinutes: 25)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Blocs de travail").font(.system(size: 12, weight: .semibold))
                        Text("Travail continu d’au moins 25 minutes ; un détour de deux minutes au plus (message, recherche, courte pause) ne coupe pas le bloc.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if blocks.isEmpty {
                            Text(current.workSeconds > 0 ? "Aucun bloc de 25 minutes ou plus sur cette période."
                                 : "Classez vos usages de travail pour voir apparaître vos blocs.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(blocks.sorted { $0.workSeconds > $1.workSeconds }.prefix(5)) { block in
                            HStack {
                                Text("\(shortDate(block.start)) · \(time(block.start))–\(time(block.end))")
                                Spacer()
                                Text(duration(block.workSeconds)).monospacedDigit()
                            }.font(.system(size: 12)).accessibilityElement(children: .combine)
                        }
                    }
                    comparisonDetails
                }.fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }.font(.system(size: 14, weight: .medium))
        }
    }

    private func detailValue(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private var comparisonDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comparaison avec la période précédente").font(.system(size: 12, weight: .semibold))
            Text("Période sélectionnée : \(duration(current.activeSeconds)) · \(current.daysWithObservations)/\(current.days.count) jours avec activité mesurée.")
            Text("Période précédente : \(payload.previous.observedSeconds > 0 ? duration(payload.previous.activeSeconds) : "—") · \(payload.previous.daysWithObservations)/\(payload.previous.days.count) jours avec activité mesurée.")
            if let first = payload.previous.days.first, let last = payload.previous.days.last {
                Text("Référence : \(shortDate(first.date)) – \(shortDate(last.date)).")
            }
            Text("Les comparaisons utilisent la moyenne des jours observés (ou la veille à la même heure pour aujourd’hui). Un écart de temps ne mesure pas l’efficacité.")
                .foregroundStyle(.secondary)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    /// Today with nothing yet is a day that has not started, not a missing archive.
    private var isEmptyToday: Bool {
        isDay && current.eventCount == 0 && current.incompleteDays == 0
            && current.days.contains { Calendar.current.isDateInToday($0.date) }
    }

    private var emptyState: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 12) {
                heading(current.incompleteDays > 0 ? "Lecture incomplète" : current.eventCount > 0 ? "Les premières traces sont reçues"
                    : isEmptyToday ? "Pas encore d’activité aujourd’hui" : "Pas encore d’enregistrement")
                if current.eventCount > 0 {
                    Text("\(current.eventCount) observations reçues").font(.system(size: 15, weight: .medium)).monospacedDigit()
                        .accessibilityIdentifier("analytics-first-observations")
                }
                Text(current.incompleteDays > 0
                    ? "Certaines sources n’ont pas pu être lues. Cela ne signifie pas une absence d’activité."
                    : current.eventCount > 0
                    ? "La durée devient mesurable dès que deux observations d’activité sont assez proches. Aucune minute n’est inventée entre des traces isolées."
                    : isEmptyToday
                    ? "Vos durées, vos apps et votre rythme apparaissent ici dès les premières minutes d’utilisation de ce Mac."
                    : "Choisissez une autre date ou consultez les sources dans l’historique. Une absence de données n’est pas une journée à zéro.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !isEmptyToday {
                    Button("Consulter l’historique", action: onHistory).buttonStyle(.bordered).disabled(payload.isPreview)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var methodology: some View {
        GoalongDisclosureGroup("Comment lire ces chiffres ?") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Temps actif = Travail + Hors travail + À classer. Le travail et le focus sont inclus dans l’actif ; ce ne sont pas des heures supplémentaires.")
                Text("Vos choix (Travail / Hors travail) priment sur le classement automatique, qui n’est retenu qu’à partir de 50 % de confiance. Sans classement, le temps reste à classer, pas à zéro. Hors travail ne signifie pas procrastination.")
                Text("Les moyennes par jour ne comptent que les jours observés. Aujourd’hui est comparé à hier à la même heure ; une période, à la moyenne de la précédente.")
                Text("Une séquence de focus conserve la même application et le même domaine. Changer d’outil pour un même projet peut interrompre cette mesure ; elle ne mesure ni l’attention ni l’efficacité.")
                Text("Un écart de plus de deux minutes entre observations ou une interruption de collecte coupe la continuité. Les appels, lectures et présentations observés au premier plan comptent même sans clavier ni souris. Les périodes sans saisie et sans signal d’usage, privées ou non observées restent distinctes. Rien n’est prolongé avant la première trace ou après la dernière.")
                Text("Le Temps d’écran Apple garde ses propres sources et appareils. Il n’est jamais additionné aux observations Goalong. Les conversations et le temps machine ne s’ajoutent pas non plus au temps actif.")
                Text("Les bilans et projets sont des analyses déjà enregistrées. Consulter cette page ne lance aucun agent. Sport, sommeil et travail hors ordinateur ne sont pas déduits de l’activité du Mac.")
            }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }.font(.system(size: 12, weight: .medium))
    }

    private var hourStride: Int {
        let hours = chartDateRange.upperBound.timeIntervalSince(chartDateRange.lowerBound) / 3600
        return hours > 16 ? 4 : hours > 8 ? 2 : 1
    }
    private var chartDateRange: ClosedRange<Date> {
        guard isDay, let day = current.days.first else { return dateRange }
        return GoalongActivityPresentation.chartRange(day, fullDay: fullDay)
    }
    private var dateRange: ClosedRange<Date> {
        let first = current.days.first?.date ?? payload.updatedAt
        let last = current.days.last?.date ?? first
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last)
    }
    private func middleOfDay(_ day: Date) -> Date { Calendar.current.date(byAdding: .hour, value: 12, to: day) ?? day }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader) }
    private func duration(_ value: Double) -> String { GoalongAnalyticsFormatting.duration(value) }
    private func percent(_ share: Double) -> String { "\(Int((max(0, min(1, share)) * 100).rounded()))\u{00A0}%" }
    private func time(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute()) }
    private func shortDate(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)) }
    private func cardDay(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(title) }.font(.system(size: 11))
    }
    private func kindLabel(_ kind: GoalongLocalAnalytics.Kind) -> String {
        switch kind {
        case .work: return "Travail classé"; case .other: return "Autres usages"; case .unclassified: return "À préciser"
        case .idle: return "Sans interaction"; case .concealed: return "Privé / suspendu"; case .unobserved: return "Non observé"
        }
    }
    private func kindColor(_ kind: GoalongLocalAnalytics.Kind) -> Color {
        switch kind {
        case .work: return LHTheme.accent; case .other: return LHTheme.warning; case .unclassified: return LHTheme.secondaryText
        case .idle: return LHTheme.privateTint; case .concealed: return LHTheme.teal.opacity(0.45); case .unobserved: return LHTheme.separator
        }
    }
    private func statusLabel(_ value: String) -> String {
        switch value { case "observed": return "Observé"; case "inferred": return "Déduit"; case "declared": return "Déclaré"; default: return "À préciser" }
    }
}
#endif
