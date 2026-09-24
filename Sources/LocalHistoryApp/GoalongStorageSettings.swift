#if os(macOS)
import SwiftUI
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
                    Text("Espace utilisé")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: model.snapshot.storageBytes, countStyle: .file))
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conservation")
                        Text(retentionSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choisir…") { retention = true }.buttonStyle(.bordered)
                }
            }
            GoalongSettingsGroup(title: "Gestion des données") {
                Button("Effacer de l’historique…") { deletion = true }.buttonStyle(.bordered)
                Text("Les originaux Apple, les conversations et les données déjà envoyées restent conservés.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            GoalongDisclosureGroup("Fichiers et diagnostics") {
                HStack {
                    Button("Ouvrir le dossier") { model.openDataFolder() }
                    Button("Diagnostics") { model.openDiagnostics() }
                }.buttonStyle(.bordered).padding(.top, 12)
            }.font(.system(size: 13))
        }
        .sheet(isPresented: $deletion) { GoalongDeletionSheet(model: model) }
        .onAppear(perform: refresh)
        .sheet(isPresented: $retention, onDismiss: refresh) { GoalongRetentionSheet() }
    }
    private func refresh() {
        let store = HistoryRetentionStore(legacyRetentionDays: model.appliedSettings.retentionDays)
        retentionSummary = store.isAutomaticCleanupEnabled ? "Nettoyage automatique activé" : "Jusqu’à suppression manuelle"
    }
}

@MainActor struct GoalongAdvancedTools: View {
    @ObservedObject var model: DashboardViewModel
    @State private var advancedShare = false
    @State private var siteAnalysis = false
    @State private var health = false
    @StateObject private var profileWindow = GoalongProfileWindow()
    @State private var prepared: Data?
    var body: some View {
        GoalongSettingsGroup(title: "Actions distinctes des envois quotidiens") {
            Button("Exporter un fichier signé…") { model.selectSection(.share) }.buttonStyle(.bordered)
            Button("Partager un récap relu…") { prepared = nil; advancedShare = true }.buttonStyle(.bordered)
            Button("Comprendre mon travail") { profileWindow.show { prepared = $0; advancedShare = true } }.buttonStyle(.bordered)
            Button("Analyser une demande du site…") { siteAnalysis = true }.buttonStyle(.bordered)
            Button("Importer Apple Santé…") { health = true }.buttonStyle(.bordered)
        }
        .sheet(isPresented: $advancedShare) { GoalongWebsiteConnectionSheet(preparedAnalysis: prepared) }
        .sheet(isPresented: $siteAnalysis) { GoalongSiteAnalysisSheet() }
        .sheet(isPresented: $health) { GoalongHealthImportSheet() }
    }
}
#endif
