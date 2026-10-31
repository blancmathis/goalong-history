#if os(macOS)
import AppKit
import LocalHistoryCore
import SwiftUI

/// « Choisir les projets… »: the repositories whose Git history and file counts Goalong reads.
@MainActor struct GoalongDeveloperProjectsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var developer: GoalongDeveloperModel
    @State private var problem: String?
    @State private var revision = 0
    /// A model given by a test or the gallery is shown as is: it never reads the real data nor the agents.
    private let readsAgents: Bool

    init(developer: GoalongDeveloperModel? = nil) {
        _developer = StateObject(wrappedValue: developer ?? GoalongDeveloperModel())
        readsAgents = developer == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Projets suivis").font(LHTheme.sheetTitleFont)
                    Text("Goalong lit l’heure et le type des actions Git et compte les fichiers modifiés, jamais le code, les messages ni les noms de fichiers.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            // UI-15A (48): the sheet opens at its content's height, at most 520 pt, instead of a fixed 480.
            GoalongSheetScroll(cap: 520) {
                VStack(alignment: .leading, spacing: 22) {
                    // UI-13C (48): no project yet is an empty state with its one next step, in lime.
                    if developer.selectedProjects.isEmpty {
                        GoalongEmptyState(title: "Aucun projet suivi",
                                          message: "Ajoutez le dossier d’un projet Git pour voir ses commits et ses fichiers modifiés.") {
                            Button("Ajouter un dossier…", action: choose).buttonStyle(LHPrimaryButtonStyle())
                        }
                    } else {
                        GoalongSettingsGroup(title: "Suivis") {
                            ForEach(Array(developer.selectedProjects.enumerated()), id: \.element.id) { index, project in
                                if index > 0 { Divider() }
                                row(project, action: "Retirer") { remove(project) }
                            }
                        }
                    }
                    if !developer.suggestions.isEmpty {
                        GoalongSettingsGroup(title: "Projets vus par vos agents") {
                            ForEach(Array(developer.suggestions.enumerated()), id: \.element.id) { index, project in
                                if index > 0 { Divider() }
                                row(project, action: "Suivre") { add(project) }
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        if !developer.selectedProjects.isEmpty {
                            Button("Ajouter un dossier…", action: choose).buttonStyle(LHSecondaryButtonStyle())
                        }
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, idealWidth: 620)
        .background(Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
        .task(id: revision) { if readsAgents { await developer.refresh(day: GoalongToday.now) } }
        .accessibilityIdentifier("developer-projects-sheet")
    }

    private func row(_ project: GoalongDeveloperProject, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text((project.rootPath as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1).truncationMode(.middle)
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
        let developer = developer
        problem = Self.outcome(panel.urls.map { url in { try developer.addProject(url) } }); revision += 1
    }

    private func add(_ project: GoalongDeveloperProject) { attempt { try developer.addProject(project) } }
    private func remove(_ project: GoalongDeveloperProject) { attempt { try developer.removeProject(id: project.id) } }

    private func attempt(_ change: @escaping () throws -> Void) { problem = Self.outcome([change]); revision += 1 }

    /// Runs every change. The first failure stays shown, even when a later folder of the same choice is added.
    static func outcome(_ changes: [() throws -> Void]) -> String? {
        var problem: String?
        for change in changes {
            do { try change() }
            catch GoalongDeveloperFileIO.Failure.tooLarge { problem = problem ?? "Limite atteinte : 64 projets au plus." }
            catch GoalongDeveloperFileIO.Failure.invalid { problem = problem ?? "Ce dossier n’est pas un dépôt Git." }
            catch { problem = problem ?? "Ce choix n’a pas pu être enregistré." }
        }
        return problem
    }
}
#endif
