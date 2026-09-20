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
    @State private var allUsage = false
    @State private var allCards = false
    @State private var module = "all"
    @State private var hourly = false
    @State private var selectedUsage: GoalongActivityUsageItem?
    @State private var selectedSegment: GoalongLocalAnalytics.Segment?

    private var current: GoalongLocalAnalytics.Period { payload.current }
    private var isDay: Bool { current.days.count == 1 }
    private var focus: [GoalongLocalAnalytics.Focus] { current.focus(minimumMinutes: focusMinutes) }
    private var focusSeconds: Double { current.focusSeconds(minimumMinutes: focusMinutes) }
    private var sparse: Bool { current.activeSeconds > 0 && current.activeSeconds < 600 }
    private var classified: Bool { GoalongActivityProjection.hasClassification(current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            coverage
            if current.observedSeconds > 0 {
                metrics
                rhythmCard
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        usageCard.frame(maxWidth: .infinity)
                        projectsCard.frame(maxWidth: .infinity)
                    }.frame(minWidth: 860)
                    VStack(spacing: 20) { usageCard; projectsCard }
                }
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
        .sheet(item: $selectedSegment) { segment in
            segmentDetail(segment)
        }
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

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                activeMetric
                workMetric
                focusMetric
            }.frame(minWidth: 560)
            VStack(spacing: 12) {
                activeMetric
                HStack(alignment: .top, spacing: 12) { workMetric; focusMetric }
            }
        }.accessibilityIdentifier("activity-primary-metrics")
    }
    private var activeMetric: some View {
        metric("Temps actif", value: duration(current.activeSeconds), detail: "Activité observée au premier plan", primary: true)
    }
    private var workMetric: some View {
        metric("Travail classé", value: classified ? duration(current.workSeconds) : "—",
            detail: classified ? "Inclus dans le temps actif · classement local" : "Activités encore à préciser")
    }
    private var focusMetric: some View {
        metric("Focus observé", value: duration(focusSeconds),
            detail: "\(focus.count) séquences ≥ \(focusMinutes) min · inclus dans l’actif")
    }
    private func metric(_ title: String, value: String, detail: String, primary: Bool = false) -> some View {
        LHCard(padding: 17) {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: primary ? 32 : 28, weight: .semibold))
                    .tracking(-0.6).monospacedDigit().foregroundStyle(primary ? LHTheme.accent : LHTheme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }

    private var rhythmCard: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    heading(isDay ? "Rythme de la journée" : "Rythme sur \(current.days.count) jours")
                    Spacer()
                    if isDay && !sparse {
                        Picker("Affichage du rythme", selection: $hourly) {
                            Text("Chronologie").tag(false)
                            Text("Heure par heure").tag(true)
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
                if isDay, let day = current.days.first {
                    if hourly || sparse { hourlyChart(day) }
                    else { timelineChart(day) }
                    if hourly || sparse {
                        HStack(spacing: 16) {
                            legend("Temps actif", color: LHTheme.accent)
                            legend("Focus inclus", color: LHTheme.teal)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(GoalongLocalAnalytics.Kind.allCases, id: \.rawValue) { kind in
                                legend(kindLabel(kind), color: kindColor(kind))
                            }
                        }
                        Text("Les zones grises sont non observées. Sélectionnez une plage pour l’examiner.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Heures et valeurs") {
                        VStack(spacing: 8) {
                            ForEach(day.hours(minimumMinutes: focusMinutes).filter { $0.seconds > 0 }) { hour in
                                HStack {
                                    Text("\(time(hour.start))–\(time(hour.end))")
                                    Spacer()
                                    Text(duration(hour.seconds) + " actives")
                                    Text("· " + duration(hour.focusSeconds) + " de focus").foregroundStyle(.secondary)
                                }.font(.system(size: 12)).accessibilityElement(children: .combine)
                            }
                            Button("Examiner cette journée dans l’historique") { onHistoryDay(day.date) }
                                .buttonStyle(.borderless).disabled(payload.isPreview)
                        }.padding(.top, 10)
                    }.font(.system(size: 12))
                } else {
                    dailyChart
                    HStack(spacing: 16) {
                        legend("Travail classé", color: LHTheme.accent)
                        legend("Autres usages", color: LHTheme.warning)
                        legend("À préciser", color: LHTheme.secondaryText)
                        legend("Focus inclus", color: LHTheme.teal)
                    }
                    Text("Sélectionnez un jour pour l’explorer, puis revenez à cette période.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    DisclosureGroup("Explorer les jours et leurs valeurs") {
                        VStack(spacing: 0) {
                            ForEach(current.days) { day in
                                Button { onDay(day.date) } label: {
                                    HStack {
                                        Text(shortDate(day.date)).frame(width: 100, alignment: .leading)
                                        Text(GoalongActivityProjection.dayLabel(day))
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right").font(.caption)
                                    }.font(.system(size: 12)).padding(.vertical, 9).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Explorer le \(shortDate(day.date))")
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                }
                comparison
            }
        }.accessibilityIdentifier("activity-primary-chart")
    }

    private func timelineChart(_ day: GoalongLocalAnalytics.Day) -> some View {
        Chart {
            ForEach(day.segments) { segment in
                RectangleMark(xStart: .value("Début", segment.start), xEnd: .value("Fin", segment.end),
                              y: .value("Lecture", "Activité"))
                    .foregroundStyle(kindColor(segment.kind))
                    .accessibilityLabel("\(kindLabel(segment.kind)), \(time(segment.start))–\(time(segment.end))")
                    .accessibilityValue(duration(segment.seconds))
            }
            ForEach(day.focus(minimumMinutes: focusMinutes)) { block in
                RectangleMark(xStart: .value("Début", block.start), xEnd: .value("Fin", block.end),
                              y: .value("Lecture", "Focus"))
                    .foregroundStyle(LHTheme.teal)
                    .accessibilityLabel("Continuité : \(block.application)")
                    .accessibilityValue(duration(block.seconds))
            }
        }
        .chartXScale(domain: dateRange).chartYScale(domain: ["Focus", "Activité"])
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
            AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).hour()); AxisTick()
        } }
        .frame(height: 112)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let x = value.location.x - geometry[proxy.plotAreaFrame].origin.x
                        guard x >= 0, x <= geometry[proxy.plotAreaFrame].width,
                              let date: Date = proxy.value(atX: x) else { return }
                        selectedSegment = day.segments.first { $0.start <= date && date < $0.end }
                    })
            }
        }
    }

    private var dailyChart: some View {
        let scale = GoalongAnalyticsChartScale(maximumSeconds: current.days.map(\.activeSeconds).max() ?? 0)
        return Chart {
            ForEach(current.days) { day in
                if day.activeSeconds > 0 {
                    ForEach([GoalongLocalAnalytics.Kind.work, .other, .unclassified], id: \.rawValue) { kind in
                        BarMark(x: .value("Jour", day.date, unit: .day), y: .value("Durée", day.seconds(kind) / scale.unitSeconds))
                            .foregroundStyle(kindColor(kind)).cornerRadius(2)
                            .accessibilityLabel("\(shortDate(day.date)), \(kindLabel(kind))")
                            .accessibilityValue(duration(day.seconds(kind)))
                    }
                    // Independent points never draw a misleading line over a missing day.
                    PointMark(x: .value("Jour", middleOfDay(day.date)), y: .value("Focus", day.focusSeconds(minimumMinutes: focusMinutes) / scale.unitSeconds))
                        .foregroundStyle(LHTheme.teal).symbolSize(28)
                        .accessibilityLabel("\(shortDate(day.date)), focus inclus")
                        .accessibilityValue(duration(day.focusSeconds(minimumMinutes: focusMinutes)))
                } else if day.observedSeconds > 0 && day.state == .ready {
                    PointMark(x: .value("Jour", middleOfDay(day.date)), y: .value("Durée", 0.0))
                        .foregroundStyle(LHTheme.secondaryText)
                        .accessibilityLabel("\(shortDate(day.date)), zéro minute active observée")
                }
            }
        }
        .chartLegend(.hidden).chartYScale(domain: 0...scale.upperBound).chartXScale(domain: dateRange)
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: current.days.count > 7 ? 4 : 1)) { _ in
            AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)); AxisTick()
        } }
        .chartYAxis { AxisMarks(position: .leading) { value in
            AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(scale.label(amount)) } }
        } }
        .frame(height: 220)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let x = value.location.x - geometry[proxy.plotAreaFrame].origin.x
                        guard x >= 0, x <= geometry[proxy.plotAreaFrame].width,
                              let date: Date = proxy.value(atX: x),
                              let day = current.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else { return }
                        onDay(day.date)
                    })
            }
        }
    }

    private func hourlyChart(_ day: GoalongLocalAnalytics.Day) -> some View {
        let hours = day.hours(minimumMinutes: focusMinutes)
        let scale = GoalongAnalyticsChartScale(maximumSeconds: hours.map(\.seconds).max() ?? 0, hourly: true)
        return Chart {
            ForEach(hours.filter { $0.seconds > 0 }) { hour in
                BarMark(x: .value("Heure", hour.start, unit: .hour), y: .value("Activité", hour.seconds / scale.unitSeconds))
                    .foregroundStyle(LHTheme.accent).cornerRadius(2)
                    .accessibilityLabel("\(time(hour.start)), activité observée")
                    .accessibilityValue(duration(hour.seconds))
                PointMark(x: .value("Heure", hour.start.addingTimeInterval(hour.end.timeIntervalSince(hour.start) / 2)),
                          y: .value("Focus", hour.focusSeconds / scale.unitSeconds))
                    .foregroundStyle(LHTheme.teal).symbolSize(25)
                    .accessibilityLabel("\(time(hour.start)), focus inclus")
                    .accessibilityValue(duration(hour.focusSeconds))
            }
        }
        .chartLegend(.hidden).chartXScale(domain: dateRange).chartYScale(domain: 0...scale.upperBound)
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
            AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).hour()); AxisTick()
        } }
        .chartYAxis { AxisMarks(position: .leading) { value in
            AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(scale.label(amount)) } }
        } }.frame(height: 200)
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 9) {
            if GoalongActivityProjection.canCompare(current, to: payload.previous) {
                let delta = current.activeSeconds - payload.previous.activeSeconds
                Text("\(delta >= 0 ? "+" : "−")\(duration(abs(delta))) de temps observé par rapport à la période précédente.")
                    .font(.system(size: 12, weight: .medium))
            }
            DisclosureGroup("Comparaison avec la période précédente") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Période sélectionnée : \(duration(current.activeSeconds)) · \(current.daysWithObservations)/\(current.days.count) jours avec activité mesurée.")
                    Text("Période précédente : \(payload.previous.observedSeconds > 0 ? duration(payload.previous.activeSeconds) : "—") · \(payload.previous.daysWithObservations)/\(payload.previous.days.count) jours avec activité mesurée.")
                    if let first = payload.previous.days.first, let last = payload.previous.days.last {
                        Text("Référence : \(shortDate(first.date)) – \(shortDate(last.date)).")
                    }
                    Text(GoalongActivityProjection.canCompare(current, to: payload.previous)
                        ? "Même durée de période. La couverture à l’intérieur des journées peut varier. Cet écart ne mesure pas l’efficacité."
                        : "Comparaison limitée : journée en cours, données manquantes ou classement différent. Aucun pourcentage de progression n’est calculé.")
                        .foregroundStyle(.secondary)
                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.top, 9)
            }.font(.system(size: 12))
        }
    }

    private var usageCard: some View {
        let items = GoalongActivityProjection.usage(current, grouping: grouping)
        let visible = allUsage ? items : Array(items.prefix(6))
        return LHCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    heading("Applications et sites")
                    Spacer(minLength: 8)
                    Picker("Regrouper les usages", selection: $grouping) {
                        ForEach(GoalongActivityUsageGrouping.allCases) { value in Text(value.title).tag(value) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                if items.isEmpty {
                    Text("Pas encore de durée active attribuable. Les périodes privées et non observées restent séparées.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(visible) { item in
                    Button { selectedUsage = item } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 9) {
                                Image(systemName: item.isWebsite ? "globe" : "app").foregroundStyle(.secondary).frame(width: 18)
                                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(item.name)
                                Spacer(minLength: 8)
                                Text(duration(item.seconds)).font(.system(size: 13)).monospacedDigit()
                                Text(String(format: "%.0f %%", item.seconds / max(1, current.activeSeconds) * 100))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            GeometryReader { geometry in
                                Capsule().fill(LHTheme.separator)
                                Capsule().fill(LHTheme.accent.opacity(0.8))
                                    .frame(width: geometry.size.width * min(1, item.seconds / max(1, items.first?.seconds ?? 1)))
                            }.frame(height: 4).accessibilityHidden(true)
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityElement(children: .combine)
                        .accessibilityHint("Ouvrir la répartition sur la période sélectionnée")
                }
                if items.count > 6 {
                    Button(allUsage ? "Réduire" : "Voir les \(items.count) usages") { allUsage.toggle() }
                        .buttonStyle(.borderless).font(.system(size: 12))
                }
                Text("Même total observé : \(duration(current.activeSeconds)). Les sites remplacent le temps du navigateur, sans s’y ajouter.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("activity-usage")
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
                    DisclosureGroup {
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
                            Text("\(card.day) · \(payload.isPreview ? "Exemple fictif · " : "")\(statusLabel(card.status))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if cards.count > 3 {
                    Button(allCards ? "Réduire" : "Voir les \(cards.count) éléments") { allCards.toggle() }
                        .buttonStyle(.borderless).font(.system(size: 12))
                }
                Button(isDay ? "Comprendre mon travail" : "Analyser une journée…", action: onProjects)
                    .buttonStyle(.bordered).controlSize(.small).disabled(payload.isPreview)
                    .accessibilityIdentifier("analytics-projects")
                if let notice = payload.archiveNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(LHTheme.warning)
                }
            }
        }.accessibilityIdentifier("activity-reports")
    }

    private var rhythmDetails: some View {
        LHCard {
            DisclosureGroup("Détails du rythme et du focus") {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Le focus décrit une continuité dans la même application et sur le même domaine, pas la concentration mentale.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Text("Séquence minimale").font(.system(size: 12))
                        Picker("Séquence minimale de focus", selection: $focusMinutes) {
                            Text("10 min").tag(10); Text("25 min").tag(25); Text("50 min").tag(50)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 225)
                            .accessibilityIdentifier("analytics-focus-threshold")
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Plus longue séquence").foregroundStyle(.secondary)
                            Text(duration(current.days.flatMap(\.sequences).map(\.seconds).max() ?? 0)).fontWeight(.semibold)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Changements de contexte").foregroundStyle(.secondary)
                            Text("\(current.contextChanges)").fontWeight(.semibold)
                        }
                        Spacer()
                    }.font(.system(size: 13))
                    if focus.isEmpty {
                        Text("Aucune séquence d’au moins \(focusMinutes) minutes. Un changement d’outil ne signifie pas une dispersion.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(focus.sorted { $0.seconds > $1.seconds }.prefix(5)) { block in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.application + (block.host.map { " · " + $0 } ?? "")).font(.system(size: 13, weight: .medium))
                                Text("\(shortDate(block.start)) · \(time(block.start))–\(time(block.end))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(duration(block.seconds)).font(.system(size: 13)).monospacedDigit()
                        }.accessibilityElement(children: .combine)
                    }
                    if focus.count > 5 { Text("Les cinq plus longues séquences sont affichées.").font(.system(size: 11)).foregroundStyle(.secondary) }
                }.fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }.font(.system(size: 14, weight: .medium))
        }
    }

    private var emptyState: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 12) {
                heading(current.incompleteDays > 0 ? "Lecture incomplète" : current.eventCount > 0 ? "Les premières traces sont reçues" : "Pas encore d’enregistrement")
                if current.eventCount > 0 {
                    Text("\(current.eventCount) observations reçues").font(.system(size: 15, weight: .medium)).monospacedDigit()
                        .accessibilityIdentifier("analytics-first-observations")
                }
                Text(current.incompleteDays > 0
                    ? "Certaines sources n’ont pas pu être lues. Cela ne signifie pas une absence d’activité."
                    : current.eventCount > 0
                    ? "La durée devient mesurable dès que deux observations d’activité sont assez proches. Aucune minute n’est inventée entre des traces isolées."
                    : "Choisissez une autre date ou consultez les sources dans l’historique. Une absence de données n’est pas une journée à zéro.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Consulter l’historique", action: onHistory).buttonStyle(.bordered).disabled(payload.isPreview)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var methodology: some View {
        DisclosureGroup("Comment lire ces chiffres ?") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Temps actif = Travail classé + Autres usages + À préciser. Le travail classé et le focus sont inclus dans l’actif ; ce ne sont pas des heures supplémentaires.")
                Text("Le classement local n’est conservé qu’à partir de 50 % de confiance. Sans classement, le travail reste à préciser, pas à zéro. Autres usages ne signifie pas procrastination.")
                Text("Une séquence de focus conserve la même application et le même domaine. Changer d’outil pour un même projet peut interrompre cette mesure ; elle ne mesure ni l’attention ni l’efficacité.")
                Text("Un écart de plus de deux minutes entre observations ou une interruption de collecte coupe la continuité. Les périodes sans interaction, privées ou non observées restent distinctes. Rien n’est prolongé avant la première trace ou après la dernière.")
                Text("Le Temps d’écran Apple garde ses propres sources et appareils. Il n’est jamais additionné aux observations Goalong. Les conversations et le temps machine ne s’ajoutent pas non plus au temps actif.")
                Text("Les bilans et projets sont des analyses déjà enregistrées. Consulter cette page ne lance aucun agent. Sport, sommeil et travail hors ordinateur ne sont pas déduits de l’activité du Mac.")
            }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }.font(.system(size: 12, weight: .medium))
    }

    private func segmentDetail(_ segment: GoalongLocalAnalytics.Segment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(kindLabel(segment.kind))
            Text("\(shortDate(segment.start)) · \(time(segment.start))–\(time(segment.end))")
            Text(duration(segment.seconds)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
            if let application = segment.application { Text(application + (segment.host.map { " · " + $0 } ?? "")) }
            if segment.kind == .unobserved { Text("Aucune activité n’est déduite de cette plage sans observations.").foregroundStyle(.secondary) }
            HStack {
                Button("Fermer") { selectedSegment = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Ouvrir cette journée dans l’historique") {
                    selectedSegment = nil
                    if !payload.isPreview { onHistoryDay(Calendar.current.startOfDay(for: segment.start)) }
                }.disabled(payload.isPreview)
            }
        }.font(.system(size: 13)).padding(24).frame(width: 480)
    }

    private var dateRange: ClosedRange<Date> {
        let first = current.days.first?.date ?? payload.updatedAt
        let last = current.days.last?.date ?? first
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last)
    }
    private func middleOfDay(_ day: Date) -> Date { Calendar.current.date(byAdding: .hour, value: 12, to: day) ?? day }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader) }
    private func duration(_ value: Double) -> String { GoalongAnalyticsFormatting.duration(value) }
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

private struct GoalongActivityUsageDetail: View {
    let item: GoalongActivityUsageItem
    let period: GoalongLocalAnalytics.Period
    let grouping: GoalongActivityUsageGrouping
    let isPreview: Bool
    let onHistoryDay: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(item.name).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(GoalongAnalyticsFormatting.duration(item.seconds)) sur la période sélectionnée\(isPreview ? " · exemple fictif" : "")")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(period.days) { day in
                        let seconds = GoalongActivityProjection.seconds(for: item, in: day, grouping: grouping)
                        if seconds > 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(GoalongUIFormat.day(day.date)).fontWeight(.medium)
                                    Spacer()
                                    Text(GoalongAnalyticsFormatting.duration(seconds)).monospacedDigit()
                                }
                                if period.days.count == 1 {
                                    let segments = day.segments.filter { GoalongActivityProjection.usageID($0, grouping: grouping) == item.id }
                                    ForEach(segments.prefix(50)) { segment in
                                        HStack {
                                            Text("\(time(segment.start))–\(time(segment.end))")
                                            Spacer()
                                            Text(GoalongAnalyticsFormatting.duration(segment.seconds))
                                        }.foregroundStyle(.secondary).accessibilityElement(children: .combine)
                                    }
                                    if segments.count > 50 { Text("50 plages affichées. L’historique contient le détail complet.").foregroundStyle(.secondary) }
                                }
                                Button("Voir cette journée dans l’historique") { onHistoryDay(day.date) }
                                    .buttonStyle(.borderless).disabled(isPreview)
                            }
                            Divider()
                        }
                    }
                }.font(.system(size: 13))
            }.frame(maxHeight: 460)
            Text("Observations sur ce Mac uniquement. Les sites ne sont pas ajoutés une seconde fois au navigateur.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 540)
    }
    private func time(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute()) }
}
#endif
