#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Charts
import LocalHistoryCore

struct GoalongAnalyticsPage: View {
    @ObservedObject var model: DashboardViewModel
    @StateObject private var analytics = GoalongAnalyticsModel()
    @StateObject private var studio = GoalongProfileWindow()
    @State private var period = 7
    @State private var focusMinutes = 25
    @State private var revision = 0
    private var requestID: String { "\(model.selectedDay.timeIntervalSince1970)|\(period)|\(revision)|\(model.dashboardIsVisible)" }

    var body: some View {
        VStack(spacing: 0) {
            DayNavigationHeader(title: "Analyses", day: model.selectedDay,
                isRefreshing: analytics.busy, onSelectDay: model.selectDay,
                onShare: { model.showingWebsiteShare = true }, onRefresh: { revision += 1 })
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Votre temps, mis en perspective.").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                            Label("Sur ce Mac · privé · sans analyse IA nécessaire", systemImage: "lock.shield")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Picker("Période", selection: $period) {
                            Text("Jour").tag(1); Text("7 jours").tag(7); Text("28 jours").tag(28)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 218).accessibilityIdentifier("analytics-period")
                    }
                    if let payload = analytics.payload {
                        GoalongAnalyticsContent(payload: payload, focusMinutes: $focusMinutes,
                            onDay: { date in model.selectDay(date); period = 1 },
                            onHistory: { model.selectSection(.history) },
                            onProjects: { studio.show(localOnly: true, initialDay: model.selectedDay, onSend: { _ in }) })
                    } else if analytics.busy {
                        VStack(spacing: 14) {
                            ProgressView()
                            Text("Lecture des observations locales…").font(.headline)
                            Text("Les graphiques sont calculés jour par jour, sans envoyer votre historique.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 300).accessibilityElement(children: .combine)
                    } else if let error = analytics.error {
                        LHCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LHTheme.warning)
                                Button("Réessayer") { revision += 1 }.buttonStyle(.bordered)
                            }
                        }
                    }
                }.frame(maxWidth: 1100).padding(LHTheme.pageInset).frame(maxWidth: .infinity)
            }
        }.background(LHTheme.pageBackground)
        .task(id: requestID) {
            guard model.dashboardIsVisible else { return }
            await analytics.load(day: model.selectedDay, count: period, force: revision > 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongProfileAnalysisDidSave)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in revision += 1 }
    }
}

/// Pure presentation: also rendered in native tests without opening the recorder or user stores.
struct GoalongAnalyticsContent: View {
    let payload: GoalongAnalyticsPayload
    @Binding var focusMinutes: Int
    var onDay: (Date) -> Void = { _ in }
    var onHistory: () -> Void = {}
    var onProjects: () -> Void = {}
    @State private var websites = false
    @State private var allUsage = false
    @State private var module = "projects"
    private var current: GoalongLocalAnalytics.Period { payload.current }
    private var focus: [GoalongLocalAnalytics.Focus] { current.focus(minimumMinutes: focusMinutes) }
    private var focusSeconds: Double { current.focusSeconds(minimumMinutes: focusMinutes) }
    private var hasData: Bool { current.activeSeconds > 0 }
    private var isDay: Bool { current.days.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            periodCaption
            if hasData {
                metrics
                evolutionCard
                if isDay, let day = current.days.first { dayRibbon(day) }
                focusCard
                usageCard
            } else {
                LHCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 32)).foregroundStyle(LHTheme.accent)
                        Text("Pas encore d’activité mesurable sur cette période.").font(.system(size: 20, weight: .semibold))
                        Text("Un jour sans enregistrement n’est pas un jour à zéro. Choisissez une autre date ou consultez l’historique pour vérifier les sources disponibles.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Consulter l’historique", action: onHistory).buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
                }
            }
            projectsCard
            methodology
            HStack {
                Label("Calcul local · aucune transmission au site", systemImage: "internaldrive")
                Spacer()
                Text("Actualisé à \(payload.updatedAt.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute()))")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var periodCaption: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(periodLabel(current)).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(current.daysWithObservations)/\(current.days.count) jours avec activité observée")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if current.daysWithObservations < current.days.count || current.incompleteDays > 0 {
                Label(current.incompleteDays > 0
                    ? "\(current.incompleteDays) jour(s) incomplet(s) ou modifié(s) pendant la lecture : exclus des totaux. Actualisez pour réessayer."
                    : "Les jours sans données restent vides. Ils ne sont ni des pauses ni des échecs.",
                    systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if current.days.contains(where: { Calendar.current.isDateInToday($0.date) }) {
                Text("Journée en cours : seules les observations jusqu’à maintenant sont incluses.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 188), spacing: 12), count: 4), spacing: 12) {
                metricCards
            }.frame(minWidth: 800)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                metricCards
            }
        }
    }
    @ViewBuilder private var metricCards: some View {
            metric("Temps actif observé", value: duration(current.activeSeconds), detail: "Activité au premier plan", symbol: "clock", tint: LHTheme.text)
            metric("Focus observé", value: duration(focusSeconds), detail: "\(focus.count) séquences ≥ \(focusMinutes) min", symbol: "scope", tint: LHTheme.accent)
            metric("Plus longue séquence", value: duration(current.days.flatMap(\.sequences).map(\.seconds).max() ?? 0), detail: "Même application et domaine", symbol: "arrow.left.and.right", tint: LHTheme.teal)
            metric("Changements de contexte", value: "\(current.contextChanges)", detail: String(format: "%.1f par heure observée", Double(current.contextChanges) / max(1.0 / 60, current.activeSeconds / 3600)), symbol: "arrow.triangle.branch", tint: LHTheme.warning)
    }
    private func metric(_ title: String, value: String, detail: String, symbol: String, tint: Color) -> some View {
        LHCard(padding: 17) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(title).font(.system(size: 12, weight: .medium)); Spacer(minLength: 4); Image(systemName: symbol).foregroundStyle(tint) }
                Text(value).font(.system(size: 29, weight: .semibold)).tracking(-0.8).monospacedDigit().foregroundStyle(tint)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
    private var evolutionCard: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader("01 / L’évolution", title: isDay ? "Le rythme de votre journée" : "Vos jours ne se ressemblent pas.",
                    subtitle: isDay ? "Minutes d’activité et de focus observé, heure par heure." : "Durées observées, pas un score de performance. Cliquez sur un jour pour l’explorer.")
                if isDay, let day = current.days.first { hourlyChart(day) } else { dailyChart }
                HStack(spacing: 16) {
                    legend(isDay ? "Activité observée" : "Travail classé", color: LHTheme.accent)
                    if !isDay { legend("Autres usages", color: LHTheme.warning); legend("À préciser", color: LHTheme.secondaryText) }
                    legend("Focus observé", color: LHTheme.teal)
                }.font(.system(size: 11))
                Divider()
                comparison
                if !isDay {
                    DisclosureGroup("Explorer les jours et leurs valeurs") {
                        VStack(spacing: 0) {
                            ForEach(current.days) { day in
                                Button { onDay(day.date) } label: {
                                    HStack {
                                        Text(shortDate(day.date)).frame(width: 95, alignment: .leading)
                                        Text(day.activeSeconds > 0 ? duration(day.activeSeconds) + " actives" : "Sans données mesurables")
                                        Spacer()
                                        if day.activeSeconds > 0 { Text(duration(day.focusSeconds(minimumMinutes: focusMinutes)) + " de focus") }
                                        Image(systemName: "chevron.right").font(.caption)
                                    }.font(.system(size: 12)).padding(.vertical, 9).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Explorer le \(shortDate(day.date))")
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                }
            }
        }
    }
    private var dailyChart: some View {
        Chart {
            ForEach(current.days) { day in
                if day.activeSeconds > 0 {
                    ForEach([GoalongLocalAnalytics.Kind.work, .other, .unclassified], id: \.rawValue) { kind in
                        BarMark(x: .value("Jour", day.date, unit: .day), y: .value("Heures", day.seconds(kind) / 3600))
                            .foregroundStyle(kindColor(kind)).cornerRadius(2)
                            .accessibilityLabel("\(shortDate(day.date)), \(kindLabel(kind))")
                            .accessibilityValue(duration(day.seconds(kind)))
                    }
                    LineMark(x: .value("Jour", Calendar.current.date(byAdding: .hour, value: 12, to: day.date) ?? day.date),
                        y: .value("Focus", day.focusSeconds(minimumMinutes: focusMinutes) / 3600),
                        series: .value("Continuité", seriesID(day)))
                        .foregroundStyle(LHTheme.teal).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Jour", Calendar.current.date(byAdding: .hour, value: 12, to: day.date) ?? day.date),
                        y: .value("Focus", day.focusSeconds(minimumMinutes: focusMinutes) / 3600))
                        .foregroundStyle(LHTheme.teal).symbolSize(26)
                        .accessibilityLabel("\(shortDate(day.date)), focus observé")
                        .accessibilityValue(duration(day.focusSeconds(minimumMinutes: focusMinutes)))
                }
            }
        }.chartLegend(.hidden).chartYScale(domain: 0...max(1, (current.days.map { $0.activeSeconds / 3600 }.max() ?? 1) * 1.12))
            .chartXScale(domain: chartDateRange)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: current.days.count > 7 ? 4 : 1)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)); AxisTick() } }
            .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisValueLabel { if let h = value.as(Double.self) { Text("\(h, specifier: "%.0f") h") } } } }
            .frame(height: 230)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { value in
                        let x = value.location.x - geometry[proxy.plotAreaFrame].origin.x
                        guard x >= 0, x <= geometry[proxy.plotAreaFrame].width,
                              let date: Date = proxy.value(atX: x) else { return }
                        if let day = current.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) { onDay(day.date) }
                    })
                }
            }
    }
    private var chartDateRange: ClosedRange<Date> {
        let first = current.days.first?.date ?? payload.updatedAt
        let last = current.days.last?.date ?? first
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86400))
    }
    private func seriesID(_ day: GoalongLocalAnalytics.Day) -> Int {
        current.days.prefix { $0.date < day.date }.filter { $0.activeSeconds == 0 }.count
    }
    private func hourlyChart(_ day: GoalongLocalAnalytics.Day) -> some View {
        let hours = day.hours(minimumMinutes: focusMinutes)
        return Chart {
            ForEach(hours) { hour in
                if hour.seconds > 0 {
                    BarMark(x: .value("Heure", hour.start, unit: .hour), y: .value("Minutes actives", hour.seconds / 60))
                        .foregroundStyle(LHTheme.accent.opacity(0.75)).cornerRadius(3)
                        .accessibilityValue(duration(hour.seconds))
                    PointMark(x: .value("Heure", hour.start.addingTimeInterval(1800)), y: .value("Minutes de focus", hour.focusSeconds / 60))
                        .foregroundStyle(LHTheme.teal).symbolSize(38)
                        .accessibilityLabel("Focus à \(hour.start.formatted(.dateTime.hour()))")
                        .accessibilityValue(duration(hour.focusSeconds))
                }
            }
        }.chartXScale(domain: chartDateRange).chartYScale(domain: 0...60)
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisValueLabel(format: .dateTime.hour()); AxisTick() } }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 15, 30, 45, 60]) { value in AxisGridLine(); AxisValueLabel { if let minutes = value.as(Int.self) { Text("\(minutes) min") } } } }
            .frame(height: 220)
    }
    private var comparison: some View {
        let previous = payload.previous
        let comparable = !current.days.isEmpty && previous.days.count == current.days.count
            && current.daysWithObservations == current.days.count && previous.daysWithObservations == previous.days.count
            && current.incompleteDays == 0 && previous.incompleteDays == 0
            && !current.days.contains(where: { Calendar.current.isDateInToday($0.date) })
            && current.classifierVersions == previous.classifierVersions
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Période précédente").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(previous.daysWithObservations > 0 ? duration(previous.workSeconds) : "—").font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    Text("\(previous.daysWithObservations)/\(previous.days.count) jours observés · \(periodLabel(previous))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Période sélectionnée").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(duration(current.workSeconds)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    Text("Temps classé travail · inclus dans le total actif").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(comparable
                ? "Écart observé : \(current.workSeconds >= previous.workSeconds ? "+" : "−")\(duration(abs(current.workSeconds - previous.workSeconds))) de travail classé. Même durée de période et versions de classement ; la couverture peut varier. Ce n’est pas une mesure d’efficacité."
                : "Comparaison limitée : journée en cours, jours manquants ou classement différent. Les deux totaux restent descriptifs ; aucun gain de productivité n’en est déduit.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func dayRibbon(_ day: GoalongLocalAnalytics.Day) -> some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("02 / Les observations", title: "La journée, sans combler les blancs.", subtitle: "Les zones grises signifient que l’activité n’est pas connue.")
                Chart(day.segments) { segment in
                    RectangleMark(xStart: .value("Début", segment.start), xEnd: .value("Fin", segment.end), y: .value("Journée", ""))
                        .foregroundStyle(kindColor(segment.kind)).accessibilityLabel(kindLabel(segment.kind))
                        .accessibilityValue(duration(segment.seconds))
                }.chartXScale(domain: chartDateRange).chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 52)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading, spacing: 9) {
                    ForEach(GoalongLocalAnalytics.Kind.allCases, id: \.rawValue) { kind in
                        legend(kindLabel(kind) + " · " + duration(day.seconds(kind)), color: kindColor(kind))
                    }
                }.font(.system(size: 11))
                Button("Examiner les traces dans l’historique", action: onHistory).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
    private var focusCard: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("03 / Le focus", title: "Du temps sans changement de contexte.",
                    subtitle: "Même application et même domaine. Une mesure de continuité, pas de concentration mentale.")
                HStack {
                    Text("Séquence minimale").font(.system(size: 12))
                    Picker("Séquence minimale de focus", selection: $focusMinutes) {
                        Text("10 min").tag(10); Text("25 min").tag(25); Text("50 min").tag(50)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 225).accessibilityIdentifier("analytics-focus-threshold")
                    Spacer()
                    Text(hasData ? String(format: "%.0f %% du temps actif", focusSeconds / current.activeSeconds * 100) : "—")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.teal)
                }
                GeometryReader { geometry in
                    Capsule().fill(LHTheme.separator)
                    Capsule().fill(LHTheme.teal)
                        .frame(width: geometry.size.width * min(1, focusSeconds / max(1, current.activeSeconds)))
                }.frame(height: 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Part du temps actif en séquences continues")
                    .accessibilityValue(String(format: "%.0f pour cent", focusSeconds / max(1, current.activeSeconds) * 100))
                if focus.isEmpty {
                    Text("Aucune séquence d’au moins \(focusMinutes) minutes observée. Essayez un seuil plus court ; changer d’outil ne signifie pas se disperser.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(focus.sorted { $0.seconds > $1.seconds }.prefix(5)) { block in
                        HStack(spacing: 13) {
                            Image(systemName: "scope").foregroundStyle(LHTheme.teal)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.application + (block.host.map { " · " + $0 } ?? "")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(shortDate(block.start)) · \(time(block.start))–\(time(block.end))").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(duration(block.seconds)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        }.padding(.vertical, 5).accessibilityElement(children: .combine)
                    }
                    Text("Les 5 plus longues séquences au maximum. Les changements entre applications d’un même projet ne sont pas regroupés automatiquement.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private var usageCard: some View {
        let usage = current.usage(websites: websites)
        let visible = allUsage ? usage : Array(usage.prefix(6))
        return LHCard {
            VStack(alignment: .leading, spacing: 17) {
                sectionHeader("04 / Les usages", title: "Où passe votre temps ?", subtitle: "Une application peut servir plusieurs projets. Les sites sont inclus dans le temps des navigateurs, jamais ajoutés.")
                Picker("Répartition des usages", selection: $websites) { Text("Applications").tag(false); Text("Sites").tag(true) }
                    .pickerStyle(.segmented).frame(width: 220)
                if visible.isEmpty { Text("Aucun domaine disponible sur cette période. Les détails masqués restent privés.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(visible) { item in
                    VStack(spacing: 7) {
                        HStack {
                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(duration(item.seconds)).font(.system(size: 12)).monospacedDigit()
                            Text(String(format: "%.0f %%", item.seconds / max(1, current.activeSeconds) * 100)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                        }
                        GeometryReader { geometry in
                            Capsule().fill(LHTheme.separator)
                            Capsule().fill(LHTheme.accent.opacity(0.8)).frame(width: max(0, geometry.size.width * item.seconds / max(1, usage.first?.seconds ?? 1)))
                        }.frame(height: 4).accessibilityHidden(true)
                    }.padding(.vertical, 3).accessibilityElement(children: .combine)
                }
                if usage.count > 6 { Button(allUsage ? "Réduire" : "Voir les \(usage.count) usages") { allUsage.toggle() }.buttonStyle(.bordered).controlSize(.small) }
            }
        }
    }
    private var projectsCard: some View {
        let cards = payload.cards.filter { $0.module == module }
        return LHCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("05 / Les projets et les avancées", title: "Des heures à ce qui avance.",
                    subtitle: "Les interprétations enregistrées dans History, à côté des mesures. L’IA reste facultative et demande votre accord.")
                HStack {
                    Picker("Rubrique d’analyse", selection: $module) {
                        ForEach(GoalongProfileAnalysis.modules, id: \.self) { key in Text(GoalongProfileAnalysis.labels[key] ?? key).tag(key) }
                    }.labelsHidden().frame(maxWidth: 300)
                    Spacer()
                    Button("Comprendre mon travail", action: onProjects).buttonStyle(.bordered).accessibilityIdentifier("analytics-projects")
                }
                if cards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aucune analyse enregistrée pour cette rubrique et cette période.").font(.system(size: 13, weight: .medium))
                        Text("Choisissez les sources et les rubriques à analyser, relisez le résultat, puis conservez-le ici. Projets, méthodes, avancées, prochaines étapes et usage de l’IA resteront consultables sans passer par le site.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(LHTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ForEach(cards.prefix(24)) { card in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(card.summary).textSelection(.enabled)
                                if !card.caveat.isEmpty { Label(card.caveat, systemImage: "info.circle").foregroundStyle(.secondary) }
                            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 10)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.title).font(.system(size: 13, weight: .medium))
                                Text("\(card.day) · \(statusLabel(card.status))").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                    if cards.count > 24 { Text("24 cartes affichées sur \(cards.count). Réduisez la période pour voir les autres.").font(.caption).foregroundStyle(.secondary) }
                }
                if let notice = payload.archiveNotice { Text(notice).font(.caption).foregroundStyle(LHTheme.warning) }
                Text("Sport, sommeil, santé et travail hors Mac ne sont pas déduits de l’activité de l’ordinateur. Ils nécessitent des sources ou des déclarations distinctes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var methodology: some View {
        DisclosureGroup("Comment lire ces chiffres ?") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Observé ≠ classé ≠ déduit. Le temps actif vient des intervalles entre observations successives. Le classement Travail / Autres usages reprend les catégories locales avec une confiance d’au moins 50 %. Sans classement exploitable, le temps reste À préciser.")
                Text("Focus observé : durée totale des séquences d’au moins \(focusMinutes) minutes dans la même application et sur le même domaine. Un changement d’application ou de domaine interrompt la séquence. Cela ne mesure ni l’attention réelle, ni les projets transversaux, ni l’efficacité.")
                Text("Un écart supérieur à 2 minutes entre observations, un arrêt, une reprise ou une rupture de collecte coupe la continuité. Aucune durée n’est extrapolée avant la première observation ou après la dernière. Un signal d’inactivité d’au moins 90 secondes est affiché séparément ; ce n’est pas une pause déclarée.")
                Text("Temps actif = Travail classé + Autres usages + À préciser. Focus et sites sont des sous-ensembles, jamais des heures supplémentaires. Apple Screen Time, les conversations et le temps machine ne sont pas additionnés à ces mesures de premier plan sur ce Mac.")
                Text("Les projets et les avancées proviennent uniquement d’analyses locales déjà enregistrées : Observé, Déduit, Déclaré ou À préciser. Aucun agent n’est lancé et aucune donnée n’est transmise en ouvrant cette page.")
            }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        }.font(.system(size: 12, weight: .medium))
    }
    private func sectionHeader(_ kicker: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(kicker.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(LHTheme.accent)
            Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(text) }
    }
    private func duration(_ seconds: Double) -> String { DashboardFormatters.duration(seconds: seconds) }
    private func time(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute()) }
    private func shortDate(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)) }
    private func periodLabel(_ period: GoalongLocalAnalytics.Period) -> String {
        guard let first = period.days.first, let last = period.days.last else { return "Aucune période" }
        return first.date == last.date ? GoalongUIFormat.day(first.date) : shortDate(first.date) + " – " + GoalongUIFormat.day(last.date)
    }
    private func kindLabel(_ kind: GoalongLocalAnalytics.Kind) -> String {
        switch kind { case .work: return "Travail classé"; case .other: return "Autres usages"; case .unclassified: return "À préciser"; case .idle: return "Sans interaction"; case .concealed: return "Privé / suspendu"; case .unobserved: return "Non observé" }
    }
    private func kindColor(_ kind: GoalongLocalAnalytics.Kind) -> Color {
        switch kind { case .work: return LHTheme.accent; case .other: return LHTheme.warning; case .unclassified: return LHTheme.secondaryText; case .idle: return LHTheme.privateTint; case .concealed: return LHTheme.teal.opacity(0.45); case .unobserved: return LHTheme.separator }
    }
    private func statusLabel(_ value: String) -> String {
        switch value { case "observed": return "Observé"; case "inferred": return "Déduit"; case "declared": return "Déclaré"; default: return "À préciser" }
    }
}
#endif
