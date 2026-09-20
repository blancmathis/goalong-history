#if os(macOS)
import Foundation
import SwiftUI
import AppleScreenTime

/// Supplemental source, never part of the Goalong foreground total or its ranking.
/// Instantiated only for a real daily view, never for a simulated payload.
struct GoalongActivityAppleCard: View {
    @ObservedObject var model: DashboardViewModel
    let day: Date
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @StateObject private var screenTime: AppleScreenTimeDashboardModel

    init(model: DashboardViewModel, day: Date) {
        self.model = model
        self.day = day
        _screenTime = StateObject(wrappedValue: AppleScreenTimeDashboardModel(
            rootDirectory: AppPaths.screenTimeDirectory,
            deviceID: model.deviceID,
            selectedDay: day,
            accessEnabled: GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime),
            includesUnfilteredSummary: true
        ))
    }

    private var summary: AppleScreenTimeDaySummary? {
        guard Calendar.current.isDate(screenTime.selectedDay, inSameDayAs: day) else { return nil }
        return OverviewUsageProjection.summary(filtered: screenTime.summary,
            allReported: screenTime.unfilteredSummary, includesInactiveSystemTime: false)
    }

    var body: some View {
        LHCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Temps d’écran Apple").font(.system(size: 14, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(day.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.wide).year()))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if screenTime.isBusy && consents.isEnabled(.appleScreenTime) {
                        ProgressView().controlSize(.small).accessibilityLabel("Lecture du Temps d’écran Apple")
                    } else if consents.isEnabled(.appleScreenTime), let value = summary {
                        Text(OverviewUsageProjection.durationLabel(seconds: value.totalScreenOnDuration))
                            .font(.system(size: 23, weight: .semibold)).monospacedDigit()
                    }
                    Button(consents.isEnabled(.appleScreenTime) ? "Ouvrir" : "Configurer") {
                        model.selectDay(day)
                        model.selectSection(.screenTime)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                if !consents.isEnabled(.appleScreenTime) {
                    Text("Source facultative désactivée. Les observations Goalong restent disponibles indépendamment.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if screenTime.needsFullDiskAccess {
                    Label("Accès Apple indisponible. Vérifiez les autorisations pour cette source.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                } else if !screenTime.isBusy, let value = summary {
                    Text("Source Apple · \(value.deviceSummaries.count) appareil(s) · \(value.provenance.usesScreenTimeAgentAggregateStore ? "agrégat Apple" : "sources Apple partielles")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Non additionné au temps actif Goalong. Des usages simultanés entre appareils peuvent se chevaucher. Le temps de connexion et d’écran verrouillé est exclu de cette synthèse.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !screenTime.isBusy {
                    Text("Pas de données Apple disponibles pour cette journée. Ce n’est pas un total à zéro.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("activity-apple-source")
        .onAppear { screenTime.setActive(model.dashboardIsVisible) }
        .onDisappear { screenTime.setActive(false) }
        .onChange(of: day) { screenTime.selectDay($0) }
        .onChange(of: model.dashboardIsVisible) { screenTime.setActive($0) }
        .onReceive(NotificationCenter.default.publisher(for: .goalongCapabilityConsentDidChange)) { _ in
            screenTime.setAccessEnabled(consents.isEnabled(.appleScreenTime))
        }
        .onChange(of: screenTime.needsFullDiskAccess) { denied in
            guard denied else { return }
            let saved = consents.set(.appleScreenTime, enabled: false, surface: .settings)
            screenTime.setAccessEnabled(false)
            if !saved {
                model.alert = DashboardAlert(kind: .error, title: "Accès Temps d’écran indisponible",
                    message: "La lecture a été arrêtée, mais le réglage n’a pas pu être enregistré. Vérifiez Temps d’écran dans les réglages.")
            }
        }
    }
}
#endif
