#if os(macOS)
import Foundation
import SwiftUI
import Charts
import LocalHistoryCore

/// Where the classification of work stands, as Activité should explain it.
struct GoalongWorkStatus: Equatable {
    var hasDefinition = true
    var isClassifying = false
    var progress: String? = nil
    var problem: String? = nil
    /// Opening Activité sends contexts not yet classified to ChatGPT (automatic, consented, connected).
    var classifiesOnOpen = false
    static let preview = GoalongWorkStatus()
}

/// Pure presentation. Native snapshot tests render this without opening user stores.
struct GoalongAnalyticsContent: View {
    let payload: GoalongAnalyticsPayload
    @Binding var focusMinutes: Int
    var workStatus = GoalongWorkStatus.preview
    var onDay: (Date) -> Void = { _ in }
    var onWork: () -> Void = {}
    /// Opens the correction of the day on screen; the task is the one clicked, if any.
    var onReview: (String?) -> Void = { _ in }
    var onClassify: () -> Void = {}
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
    @State private var exportMessage: String?
    @State private var allTasks = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        let summary = self.summary
        let items = usageItems
        let showsClassification = showsWorkCard(summary)
        let tasks = current.tasks
        VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
            if current.observedSeconds > 0 {
                hero(summary)
                if showsClassification { workCard(summary) }
                if !tasks.isEmpty { tasksSection(tasks) }
                insightsSection(summary, items: items, showsClassification: showsClassification)
                rhythmSection
                usageCard(items)
                projectsSection
            } else {
                emptyState
                projectsSection
            }
            VStack(alignment: .leading, spacing: 4) {
                if current.observedSeconds > 0 { rhythmDetails }
                methodology
                Text(payload.isPreview ? "Données fictives, non enregistrées."
                     : workStatus.classifiesOnOpen
                     ? "Durées calculées sur ce Mac ; nouveaux contextes classés par ChatGPT. Actualisé à \(time(payload.updatedAt))."
                     : "Calculé sur ce Mac, sans envoi. Actualisé à \(time(payload.updatedAt)).")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText)
                    .padding(.top, 12).padding(.leading, 6)
            }
        }
        .sheet(item: $selectedUsage) { item in
            GoalongActivityUsageDetail(item: item, period: current, grouping: grouping,
                isPreview: payload.isPreview, onHistoryDay: { day in
                    selectedUsage = nil
                    if !payload.isPreview { onHistoryDay(day) }
                })
                .goalongControls()
        }
        .accessibilityIdentifier("activity-content")
    }

    // MARK: - Hero: the figure and the thread

    /// The one headline of the page: how long, then the day itself as a thread.
    private func hero(_ summary: GoalongActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 24) {
                headline(summary)
                figures(summary)
            }
            .accessibilityIdentifier("activity-primary-metrics")
            if isDay, let day = current.days.first {
                GoalongDayThread(day: day, range: chartDateRange, hourStride: hourStride)
            } else {
                GoalongThreadWeave(period: current, onDay: onDay)
            }
            coverage
        }
    }

    private func headline(_ summary: GoalongActivitySummary) -> some View {
        let value = isDay ? duration(current.activeSeconds) : (summary.averageActivePerDay.map(duration) ?? "—")
        let details = headlineDetails(summary)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(value).font(LHTheme.heroFont).tracking(LHTheme.heroTracking)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .goalongNumericTransition()
                    .animation(reduceMotion ? nil : LHTheme.settle, value: value)
                Text(isDay ? "actives" : "actives par jour")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
            }
            ForEach(details, id: \.self) { line in
                Text(line).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Temps actif")
        .accessibilityValue("\(value)\(isDay ? "" : " par jour"). \(details.joined(separator: ". "))")
    }

    private func headlineDetails(_ summary: GoalongActivitySummary) -> [String] {
        var lines: [String] = []
        if let bounds = summary.dayBounds {
            lines.append("De \(GoalongActivitySummary.time(bounds.start)) à \(GoalongActivitySummary.time(bounds.end))")
        } else if isDay {
            lines.append("Activité observée au premier plan")
        } else {
            let days = current.daysWithObservations
            lines.append("\(duration(current.activeSeconds)) sur \(days) jour\(days > 1 ? "s" : "") observé\(days > 1 ? "s" : "")"
                + (summary.averageExcludesToday ? ", moyenne sans aujourd’hui" : ""))
        }
        if let comparison = summary.comparison, abs(comparison.delta) >= 60 {
            let reference = comparison.label.hasPrefix("les ") ? "aux " + comparison.label.dropFirst(4) : "à " + comparison.label
            lines.append("\(comparison.delta > 0 ? "+" : "−")\(duration(abs(comparison.delta))) par rapport \(reference)")
        }
        return lines
    }

    /// The three supporting figures: plain columns, no tiles.
    private func figures(_ summary: GoalongActivitySummary) -> some View {
        HStack(alignment: .top, spacing: 24) {
            workFigure(summary); concentrationFigure(summary); switchesFigure(summary)
        }
    }

    private func workFigure(_ summary: GoalongActivitySummary) -> some View {
        if summary.workIsMeasurable {
            let value = isDay ? duration(summary.workSeconds) : (summary.averageWorkPerDay.map(duration) ?? "—")
            return figure("Travail", value: value, unit: isDay ? nil : "/ jour", mark: LHTheme.workData,
                          detail: "\(percent(summary.workShare)) du temps actif",
                          help: "\(percent(summary.workShare)) du temps actif, \(percent(summary.otherSeconds / max(1, summary.activeSeconds))) hors travail")
        }
        let detail: String
        if summary.activeSeconds == 0 { detail = "Aucune activité à classer" }
        else if !workStatus.hasDefinition { detail = "Décrivez votre travail pour le mesurer" }
        else if workStatus.isClassifying { detail = "Classement selon votre définition" }
        else { detail = "\(percent(summary.unclassifiedShare)) du temps reste à classer" }
        return figure("Travail", value: workStatus.isClassifying ? "En cours" : "À classer", mark: LHTheme.workData,
                      detail: detail, help: nil)
    }

    private func concentrationFigure(_ summary: GoalongActivitySummary) -> some View {
        if summary.workIsMeasurable, let block = summary.longestWorkBlock {
            let blocks = summary.workBlocks.count
            return figure("Plus longue session de travail", value: duration(block.workSeconds),
                          detail: block.task.map { "Sur \($0)" } ?? "Sur une même tâche",
                          help: "Plus longue session sur une même tâche. \(blocks) session\(blocks > 1 ? "s" : "") de 25 min ou plus.")
        }
        let longest = summary.longestSequence
        return figure("Plus longue séquence", value: longest.map { duration($0.seconds) } ?? "—",
                      detail: longest.map { "Dans \(GoalongActivityPresentation.displayName($0.host ?? $0.application))" }
                        ?? "Aucune période continue",
                      help: "Plus longue période continue dans une même app ou un même site.")
    }

    private func switchesFigure(_ summary: GoalongActivitySummary) -> some View {
        guard let perHour = summary.changesPerActiveHour, let every = summary.secondsPerChange else {
            return figure("Changements d’app", value: "—", detail: "Pas assez d’activité", help: nil)
        }
        let sameTask = current.sameTaskChanges
        return figure("Changements d’app", value: "\(Int(perHour.rounded()))", unit: "/ h",
                      detail: "Un toutes les \(GoalongActivitySummary.shortInterval(every))",
                      help: "\(summary.contextChanges) changements d’app ou de site au total"
                        + (sameTask > 0 ? ", dont \(sameTask) sans quitter la tâche." : "."))
    }

    private func figure(_ title: String, value: String, unit: String? = nil, mark: Color? = nil,
                        detail: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let mark {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(mark).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(LHTheme.figureFont(22)).tracking(-0.4).lineLimit(1).minimumScaleFactor(0.7)
                    .goalongNumericTransition()
                    .animation(reduceMotion ? nil : LHTheme.settle, value: value)
                if let unit { Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText) }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? detail)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help ?? "")
    }

    /// Only what changes how the figures should be read; nothing when the period is complete.
    @ViewBuilder private var coverage: some View {
        let today = !payload.isPreview && current.days.contains { Calendar.current.isDateInToday($0.date) }
        if current.incompleteDays > 0 {
            GoalongNote("\(current.incompleteDays) jour(s) illisible(s) ou incomplet(s), exclus des totaux. Actualisez ou consultez l’historique.",
                        tone: .warning)
        } else if sparse {
            GoalongNote("Vos premières observations sont déjà visibles. Le graphique adapte son échelle aux petites durées.")
        } else if !isDay && current.daysWithObservations < current.days.count {
            GoalongNote("\(current.daysWithObservations) jours sur \(current.days.count) ont une activité mesurée. Les jours sans données restent vides : ils ne comptent pas comme des journées à zéro.")
        } else if today && isDay {
            Text("Journée en cours : seules les observations déjà reçues sont incluses.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText)
        }
    }

    // MARK: - Insights and classification

    /// Explains why work is not measured yet and offers the one useful next step.
    private func showsWorkCard(_ summary: GoalongActivitySummary) -> Bool {
        guard !payload.isPreview, summary.activeSeconds > 0 else { return false }
        return !workStatus.hasDefinition || workStatus.isClassifying || summary.unclassifiedShare >= 0.15
    }

    /// "À retenir" only adds what the headline figures and the classification card do not already say.
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

    private func insightsSection(_ summary: GoalongActivitySummary, items: [GoalongActivityUsageItem],
                                 showsClassification: Bool) -> some View {
        let insights = Self.additionalInsights(
            summary.insights(topUsage: items.first, biggestChange: GoalongActivitySummary.biggestChange(items)),
            isDay: isDay, showsClassification: showsClassification)
        return Group {
            if !insights.isEmpty {
                GoalongSection(title: "À retenir") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(insights) { insight in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: insight.symbol).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(insight.tone == .attention ? LHTheme.warning
                                        : insight.tone == .positive ? LHTheme.success : LHTheme.secondaryText)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(insight.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }.accessibilityIdentifier("activity-insights")
            }
        }
    }

    private func workCard(_ summary: GoalongActivitySummary) -> some View {
        LHCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if !workStatus.hasDefinition {
                        heading("Qu’est-ce qui compte comme travail pour vous ?")
                        Text("Décrivez votre travail avec vos mots : un agent classe ensuite chaque moment selon ce que vous faisiez. Goalong ne décide jamais qu’une app ou un site est productif.")
                    } else if workStatus.isClassifying {
                        heading("Classement en cours")
                        Text(workStatus.progress ?? "L’agent applique votre définition aux nouveaux contextes de la journée.")
                    } else {
                        heading("\(percent(summary.unclassifiedShare)) de votre temps reste à classer")
                        Text(workStatus.problem ?? "Seuls les contextes nouveaux sont envoyés ; ceux déjà classés ne repartent pas.")
                    }
                }.font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if workStatus.isClassifying {
                    ProgressView().controlSize(.small)
                } else if !workStatus.hasDefinition || workStatus.problem != nil {
                    Button(workStatus.hasDefinition ? "Ouvrir Mon travail" : "Définir mon travail", action: onWork)
                        .buttonStyle(LHPrimaryButtonStyle()).accessibilityIdentifier("activity-define-work")
                } else {
                    Button("Classer maintenant", action: onClassify).buttonStyle(LHSecondaryButtonStyle())
                        .accessibilityIdentifier("activity-classify-now")
                }
            }
        }.accessibilityIdentifier("activity-classification")
    }

    private func tasksSection(_ tasks: [GoalongWorkTask]) -> some View {
        let total = max(1, tasks.reduce(0) { $0 + $1.seconds })
        let visible = allTasks ? tasks : Array(tasks.prefix(5))
        return GoalongSection(title: "Tâches", subtitle: "Votre travail par projet, quelles que soient les applications") {
            if !payload.isPreview {
                Button("Corriger") { onReview(nil) }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                    .accessibilityIdentifier("activity-tasks-review")
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(visible) { task in
                    if payload.isPreview {
                        taskRow(task, total: total).help(task.name)
                    } else {
                        Button { onReview(task.name) } label: { taskRow(task, total: total) }
                            .buttonStyle(.plain)
                            .help("\(task.name) · cliquer pour corriger son classement")
                            .accessibilityHint("Ouvre la correction du classement de cette tâche")
                    }
                }
                if tasks.count > 5 {
                    Button(allTasks ? "Réduire" : "Voir les \(tasks.count) tâches") { allTasks.toggle() }
                        .buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                }
            }
        }.accessibilityIdentifier("activity-tasks")
    }

    private func taskRow(_ task: GoalongWorkTask, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(task.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(taskDetail(task)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                Spacer(minLength: 8)
                Text(duration(task.seconds)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text(percent(task.seconds / total)).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(LHTheme.secondaryText).frame(width: 42, alignment: .trailing)
            }
            GoalongShareBar(share: task.seconds / total, color: LHTheme.workData)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func taskDetail(_ task: GoalongWorkTask) -> String {
        task.mainApplications.prefix(3).map { GoalongActivityPresentation.displayName($0) }.joined(separator: ", ")
    }

    // MARK: - Rhythm

    private var rhythmSection: some View {
        GoalongSection(title: isDay ? "Heure par heure" : "Jour par jour",
                       subtitle: isDay ? (hourly || sparse ? nil : "Quelle app ou quel site, à quel moment")
                           : "Cliquez sur un jour pour l’ouvrir") {
            if isDay {
                HStack(spacing: 14) {
                    Toggle("Journée entière", isOn: $fullDay).toggleStyle(.goalongCheckbox)
                        .font(.system(size: 12)).fixedSize().accessibilityIdentifier("activity-full-day")
                    GoalongSegmentedControl("Affichage du rythme", selection: $hourly, options: [true, false]) {
                        $0 ? "Par heure" : "Par usage"
                    }.controlSize(.small).disabled(sparse)
                        .accessibilityIdentifier("activity-rhythm-mode")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if isDay, let day = current.days.first {
                    if hourly || sparse {
                        GoalongHourlyClassChart(day: day, dateRange: chartDateRange, hourStride: hourStride)
                    } else {
                        GoalongUsageTimelineChart(day: day, grouping: grouping, dateRange: chartDateRange, hourStride: hourStride)
                    }
                    GoalongDisclosureGroup("Heures et valeurs") {
                        VStack(spacing: 8) {
                            ForEach(day.hours(minimumMinutes: focusMinutes).filter { $0.seconds > 0 }) { hour in
                                HStack {
                                    Text("\(time(hour.start))–\(time(hour.end))").monospacedDigit()
                                    Spacer()
                                    Text(duration(hour.seconds) + " actives")
                                    if hour.workSeconds > 0 {
                                        Text("dont " + duration(hour.workSeconds) + " de travail").foregroundStyle(LHTheme.secondaryText)
                                    }
                                }.font(.system(size: 12)).accessibilityElement(children: .combine)
                            }
                            Button("Examiner cette journée dans l’historique") { onHistoryDay(day.date) }
                                .buttonStyle(LHQuietButtonStyle()).disabled(payload.isPreview)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.top, 10)
                    }.font(.system(size: 13))
                } else {
                    GoalongDailyClassChart(period: current, dateRange: dateRange, onDay: onDay)
                    GoalongDisclosureGroup("Jours et valeurs") {
                        VStack(spacing: 0) {
                            ForEach(current.days) { day in
                                Button { onDay(day.date) } label: {
                                    HStack {
                                        Text(GoalongActivitySummary.weekdayDate(day.date)).frame(width: 110, alignment: .leading)
                                        Text(GoalongActivityProjection.dayLabel(day))
                                        if day.seconds(.work) > 0 {
                                            Text("dont \(duration(day.seconds(.work))) de travail").foregroundStyle(LHTheme.secondaryText)
                                        }
                                        Spacer(minLength: 8)
                                        GoalongRowChevron(size: 10)
                                    }.font(.system(size: 12)).padding(.vertical, 8).padding(.horizontal, 6).contentShape(Rectangle())
                                }.buttonStyle(LHNavigationButtonStyle(cornerRadius: 6))
                                    .accessibilityLabel("Explorer le \(shortDate(day.date))")
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 13))
                }
            }
        }.accessibilityIdentifier("activity-primary-chart")
    }

    private func usageCard(_ items: [GoalongActivityUsageItem]) -> some View {
        // Aggregate outside the search view: typing only filters the small usage list.
        VStack(alignment: .leading, spacing: 8) {
            GoalongActivityUsageList(items: items, totalSeconds: current.activeSeconds, grouping: $grouping,
                isPreview: payload.isPreview,
                onExport: {
                    exportMessage = GoalongActivityExport.save(period: current, grouping: grouping)
                }) { selectedUsage = $0 }
            if let exportMessage {
                Label(exportMessage, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
        }
    }

    private var projectsSection: some View {
        let cards = payload.cards.filter { module == "all" || $0.module == module }
        let visible = allCards ? cards : Array(cards.prefix(3))
        return GoalongSection(title: "Bilans et projets",
                              subtitle: payload.cards.isEmpty ? "Aucun bilan enregistré sur cette période. L’analyse par IA est facultative." : nil) {
            Button(isDay ? "Comprendre mon travail" : "Analyser une journée…", action: onProjects)
                .buttonStyle(LHSecondaryButtonStyle()).controlSize(.small).disabled(payload.isPreview).accessibilityIdentifier("analytics-projects")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if !payload.cards.isEmpty {
                    Picker("Rubrique", selection: $module) {
                        Text("Tous les éléments").tag("all")
                        Text("Bilans quotidiens").tag("dailyRecap")
                        ForEach(GoalongProfileAnalysis.modules, id: \.self) { key in
                            Text(GoalongProfileAnalysis.labels[key] ?? key).tag(key)
                        }
                    }.pickerStyle(.menu).labelsHidden().frame(maxWidth: 260, alignment: .leading)
                    if cards.isEmpty {
                        Text("Aucun élément enregistré dans cette rubrique.")
                            .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    }
                }
                ForEach(visible) { card in
                    GoalongDisclosureGroup {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(.init(card.summary)).textSelection(.enabled)
                            if !card.caveat.isEmpty { Text(card.caveat).foregroundStyle(LHTheme.secondaryText) }
                            if card.module == "dailyRecap", let day = cardDay(card.day) {
                                Button("Ouvrir le bilan et ses sources") { onRecap(day) }
                                    .buttonStyle(LHQuietButtonStyle()).disabled(payload.isPreview)
                            }
                        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title).font(.system(size: 13, weight: .medium))
                            Text("\(cardDay(card.day).map { GoalongUIFormat.day($0) } ?? card.day), \(payload.isPreview ? "exemple fictif, " : "")\(statusLabel(card.status).lowercased())")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        }.padding(.vertical, 5)
                    }
                }
                if cards.count > 3 {
                    Button(allCards ? "Réduire" : "Voir les \(cards.count) éléments") { allCards.toggle() }
                        .buttonStyle(LHQuietButtonStyle()).font(.system(size: 13)).padding(.leading, 6)
                }
                if let notice = payload.archiveNotice {
                    GoalongNote(notice, tone: .warning)
                }
            }
        }.accessibilityIdentifier("activity-reports")
    }

    private var rhythmDetails: some View {
        GoalongDisclosureGroup("Focus, sessions de travail et comparaison") {
            VStack(alignment: .leading, spacing: 18) {
                GoalongFocusExplanation(hasFocus: !focus.isEmpty, minimumMinutes: $focusMinutes)
                HStack(alignment: .top, spacing: 24) {
                    detailValue("Focus observé", duration(focusSeconds), "\(focus.count) séquence(s) ≥ \(focusMinutes) min")
                    detailValue("Plus longue séquence", duration(current.days.flatMap(\.sequences).map(\.seconds).max() ?? 0),
                                "même tâche, ou même app et même site")
                    detailValue("Changements de contexte", "\(current.contextChanges)", "app ou site différent")
                    Spacer(minLength: 0)
                }
                if !focus.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Plus longues séquences de focus").font(.system(size: 13, weight: .semibold))
                        ForEach(focus.sorted { $0.seconds > $1.seconds }.prefix(5)) { block in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(block.task ?? GoalongActivityPresentation.displayName(block.host ?? block.application)).font(.system(size: 13, weight: .medium))
                                    Text("\(shortDate(block.start)), \(time(block.start))–\(time(block.end))")
                                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                }
                                Spacer()
                                Text(duration(block.seconds)).font(.system(size: 13)).monospacedDigit()
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
                let blocks = current.workBlocks(minimumMinutes: 25)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sessions de travail").font(.system(size: 13, weight: .semibold))
                    Text("Au moins 25 minutes sur une même tâche, même en changeant d’application ; un détour de deux minutes au plus (message, recherche, courte pause) ne coupe pas la session.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    if blocks.isEmpty {
                        Text(current.workSeconds > 0 ? "Aucune session de 25 minutes ou plus sur cette période."
                             : "Décrivez votre travail dans Mon travail pour voir apparaître vos sessions.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    ForEach(blocks.sorted { $0.workSeconds > $1.workSeconds }.prefix(5)) { block in
                        HStack {
                            Text("\(shortDate(block.start)), \(time(block.start))–\(time(block.end))")
                            if let task = block.task { Text(task).foregroundStyle(LHTheme.secondaryText).lineLimit(1) }
                            Spacer()
                            Text(duration(block.workSeconds)).monospacedDigit()
                        }.font(.system(size: 12)).accessibilityElement(children: .combine)
                    }
                }
                comparisonDetails
            }.fixedSize(horizontal: false, vertical: true).padding(.top, 12).padding(.bottom, 8)
        }.font(.system(size: 13))
    }

    private func detailValue(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text(caption).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
        }.accessibilityElement(children: .combine)
    }

    private var comparisonDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comparaison avec la période précédente").font(.system(size: 13, weight: .semibold))
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

    @ViewBuilder private var emptyState: some View {
        if current.eventCount == 0 && current.incompleteDays == 0 {
            GoalongEmptyState(
                title: isEmptyToday ? "Pas encore d’activité aujourd’hui" : "Pas encore d’enregistrement",
                message: isEmptyToday
                    ? "Vos durées, vos apps et votre rythme apparaissent ici dès les premières minutes d’utilisation de ce Mac."
                    : "Choisissez une autre date ou consultez les sources dans l’historique. Une absence de données n’est pas une journée à zéro.") {
                if !isEmptyToday {
                    Button("Consulter l’historique", action: onHistory).buttonStyle(LHSecondaryButtonStyle()).disabled(payload.isPreview)
                }
            }
        } else {
            observationsState
        }
    }

    private var observationsState: some View {
        VStack(alignment: .leading, spacing: 12) {
            GoalongEmptyState(
                title: current.incompleteDays > 0 ? "Lecture incomplète" : current.eventCount > 0 ? "Les premières traces sont reçues"
                    : isEmptyToday ? "Pas encore d’activité aujourd’hui" : "Pas encore d’enregistrement",
                message: current.incompleteDays > 0
                    ? "Certaines sources n’ont pas pu être lues. Cela ne signifie pas une absence d’activité."
                    : current.eventCount > 0
                    ? "La durée devient mesurable dès que deux observations d’activité sont assez proches. Aucune minute n’est inventée entre des traces isolées."
                    : isEmptyToday
                    ? "Vos durées, vos apps et votre rythme apparaissent ici dès les premières minutes d’utilisation de ce Mac."
                    : "Choisissez une autre date ou consultez les sources dans l’historique. Une absence de données n’est pas une journée à zéro.") {
                if !isEmptyToday {
                    Button("Consulter l’historique", action: onHistory).buttonStyle(LHSecondaryButtonStyle()).disabled(payload.isPreview)
                }
            }
            if current.eventCount > 0 {
                Text(current.eventCount > 1 ? "\(current.eventCount) observations reçues" : "1 observation reçue").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(LHTheme.secondaryText)
                    .accessibilityIdentifier("analytics-first-observations")
            }
        }
    }

    private var methodology: some View {
        GoalongDisclosureGroup("Comment lire ces chiffres ?") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Temps actif = Travail + Hors travail + À classer. Le travail et le focus sont inclus dans l’actif ; ce ne sont pas des heures supplémentaires.")
                Text("Goalong ne décide jamais qu’une app ou un site est productif. Un agent applique votre définition (Mon travail) à chaque contexte — app, site et titre de fenêtre — et vos corrections priment. Sans verdict, le temps reste à classer, pas à zéro. Hors travail ne signifie pas procrastination.")
                Text("Les moyennes par jour ne comptent que les jours observés. Aujourd’hui est comparé à hier à la même heure ; une période, à la moyenne de la précédente.")
                Text("La plus longue session de travail suit une même tâche, même en changeant d’application. Sans tâche connue, Goalong montre à la place la plus longue séquence dans une même app ou un même site. Aucune des deux ne mesure l’attention ni l’efficacité.")
                Text("Un écart de plus de deux minutes entre observations ou une interruption de collecte coupe la continuité. Les appels, lectures et présentations observés au premier plan comptent même sans clavier ni souris. Les périodes sans saisie et sans signal d’usage, privées ou non observées restent distinctes. Rien n’est prolongé avant la première trace ou après la dernière.")
                Text("Le Temps d’écran Apple garde ses propres sources et appareils. Il n’est jamais additionné aux observations Goalong. Les conversations et le temps machine ne s’ajoutent pas non plus au temps actif.")
                Text("Les bilans et projets sont des analyses déjà enregistrées. "
                     + (workStatus.classifiesOnOpen
                        ? "Le classement automatique est activé : ouvrir cette page envoie à votre compte ChatGPT les contextes pas encore classés, selon vos choix de données. "
                        : "Consulter cette page ne lance ni classement ni bilan. ")
                     + "Sport, sommeil et travail hors ordinateur ne sont pas déduits de l’activité du Mac.")
            }.font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.bottom, 8)
        }.font(.system(size: 13))
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
    private func heading(_ text: String) -> some View {
        Text(text).font(LHTheme.cardTitleFont).foregroundStyle(LHTheme.text).accessibilityAddTraits(.isHeader)
    }
    private func duration(_ value: Double) -> String { GoalongAnalyticsFormatting.duration(value) }
    private func percent(_ share: Double) -> String { "\(Int((max(0, min(1, share)) * 100).rounded()))\u{00A0}%" }
    private func time(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute()) }
    private func shortDate(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)) }
    private func cardDay(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
    private func statusLabel(_ value: String) -> String {
        switch value { case "observed": return "Observé"; case "inferred": return "Déduit"; case "declared": return "Déclaré"; default: return "À préciser" }
    }
}
#endif
