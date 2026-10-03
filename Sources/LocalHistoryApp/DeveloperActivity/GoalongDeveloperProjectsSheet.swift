#if os(macOS)
import AppKit
import LocalHistoryCore
import SwiftUI

/// « Choisir les projets… »: the repositories whose Git history and file counts Goalong reads.
@MainActor struct GoalongDeveloperProjectsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var developer = GoalongDeveloperModel()
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Projets suivis").font(LHTheme.sheetTitleFont)
                    Text("Pour chaque projet, Goalong lit l’heure et le type des actions Git, et compte les fichiers modifiés. Le code, les messages de commit et les noms de fichiers ne sont ni lus ni enregistrés.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GoalongSettingsGroup(title: "Suivis") {
                        if developer.selectedProjects.isEmpty {
                            Text("Aucun projet suivi.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(developer.selectedProjects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 { Divider() }
                            row(project, action: "Retirer") { remove(project) }
                        }
                    }
                    if !developer.suggestions.isEmpty {
                        GoalongSettingsGroup(title: "Vus dans vos agents") {
                            ForEach(Array(developer.suggestions.enumerated()), id: \.element.id) { index, project in
                                if index > 0 { Divider() }
                                row(project, action: "Suivre") { add(project) }
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Ajouter un dossier…", action: choose).buttonStyle(LHSecondaryButtonStyle())
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 380, idealHeight: 480)
        .task { await developer.refresh(day: Date()) }
        .accessibilityIdentifier("developer-projects-sheet")
    }

    private func row(_ project: GoalongDeveloperProject, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text((project.rootPath as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action, action: perform).buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
        }
        .frame(minHeight: 36)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Suivre"; panel.message = "Choisissez le dossier d’un dépôt Git."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { attempt { try developer.addProject(url) } }
    }

    private func add(_ project: GoalongDeveloperProject) { attempt { try developer.addProject(project) } }
    private func remove(_ project: GoalongDeveloperProject) { attempt { try developer.removeProject(id: project.id) } }

    private func attempt(_ change: () throws -> Void) {
        do { try change(); problem = nil }
        catch GoalongDeveloperFileIO.Failure.tooLarge { problem = "Limite atteinte : 64 projets au plus." }
        catch GoalongDeveloperFileIO.Failure.invalid { problem = "Ce dossier n’est pas un dépôt Git." }
        catch { problem = "Ce choix n’a pas pu être enregistré." }
    }
}
#endif
