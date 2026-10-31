#if os(macOS)
import SwiftUI
import LocalHistoryCore
import Foundation

@MainActor struct GoalongStorageSettings: View {
    @ObservedObject var model: DashboardViewModel
    @State private var retention = false
    @State private var deletion = false
    @State private var retentionSummary = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GoalongSettingsGroup(title: "Sur ce Mac") {
                HStack {
                    Text("Espace utilisé par Goalong")
                    Spacer()
                    Text(GoalongUIFormat.bytes(model.snapshot.storageBytes))
                }
                if let free = model.freeDiskBytes {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Espace libre sur le disque")
                            if StorageHealth.isLow(free) {
                                Text("Sous \(StorageHealth.lowSpaceThresholdText) environ, macOS peut empêcher l’enregistrement. Goalong reprendra tout seul dès qu’il y aura de la place.")
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        Text(StorageHealth.formatted(free))
                            .foregroundStyle(StorageHealth.isLow(free) ? LHTheme.warning : LHTheme.text)
                    }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conservation")
                        Text(retentionSummary).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    Spacer()
                    Button("Choisir…") { retention = true }.buttonStyle(LHSecondaryButtonStyle())
                }
            }
            GoalongSettingsGroup(title: "Gestion des données") {
                Button("Effacer de l’historique…", role: .destructive) { deletion = true }.buttonStyle(LHSecondaryButtonStyle())
                Text("Les originaux Apple, les conversations et les données déjà envoyées au site Goalong restent conservés.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                // UI-13C (40): one button needs no group of its own; it sits under the note.
                Button("Ouvrir le dossier des données") { model.openDataFolder() }.buttonStyle(LHSecondaryButtonStyle())
            }
        }
        .sheet(isPresented: $deletion) { GoalongDeletionSheet(model: model).goalongControls() }
        .onAppear(perform: refresh)
        .sheet(isPresented: $retention, onDismiss: refresh) {
            HistoryRetentionSettingsSheet(legacyRetentionDays: model.appliedSettings.retentionDays).goalongControls()
        }
    }
    private func refresh() {
        let store = HistoryRetentionStore(legacyRetentionDays: model.appliedSettings.retentionDays)
        retentionSummary = HistoryRetentionPolicy.automaticCleanupSummary(enabled: store.isAutomaticCleanupEnabled)
    }
}

@MainActor struct GoalongAdvancedTools: View {
    @ObservedObject var model: DashboardViewModel
    @State private var advancedShare = false
    @State private var siteAnalysis = false
    @State private var health = false
    var body: some View {
        // One row per tool, grouped by role, each with its one-line purpose (UI-41).
        VStack(alignment: .leading, spacing: 20) {
            Text("Actions ponctuelles, à part des envois quotidiens. Rien ne part sans votre relecture.")
                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            GoalongSettingsList(title: "Partager") {
                GoalongSettingsLink(title: "Exporter un fichier signé…", value: "", symbol: "doc.badge.arrow.up",
                                    detail: "Un fichier vérifiable de vos journées, à transmettre vous-même.") { model.selectSection(.share) }
                GoalongRowDivider()
                GoalongSettingsLink(title: "Partager un bilan relu…", value: "", symbol: "square.and.arrow.up",
                                    detail: "Un bilan que vous relisez avant l’envoi.") { advancedShare = true }
            }
            GoalongSettingsList(title: "Analyser") {
                GoalongSettingsLink(title: "Comprendre mon travail", value: "", symbol: "chart.bar.doc.horizontal",
                                    detail: "Vos projets et vos tâches, sur une période choisie.") { model.profileStudio.show() }
                GoalongRowDivider()
                GoalongSettingsLink(title: "Analyser une demande du site…", value: "", symbol: "magnifyingglass",
                                    detail: "Une demande du site Goalong, traitée avec votre ChatGPT.") { siteAnalysis = true }
                GoalongRowDivider()
                GoalongSettingsLink(title: "Importer Apple Santé…", value: "", symbol: "heart",
                                    detail: "Sommeil, récupération et activité, lus sur ce Mac.") { health = true }
            }
        }
        .sheet(isPresented: $advancedShare) { GoalongWebsiteConnectionSheet().goalongControls() }
        .sheet(isPresented: $siteAnalysis) { GoalongSiteAnalysisSheet().goalongControls() }
        .sheet(isPresented: $health) { GoalongHealthImportSheet().goalongControls() }
    }
}
#endif
