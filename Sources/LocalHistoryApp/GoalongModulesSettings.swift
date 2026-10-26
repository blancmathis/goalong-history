#if os(macOS)
import SwiftUI

/// Réglages › Modules: one switch per optional part of Goalong.
@MainActor struct GoalongModulesSettings: View {
    var onOpen: (DashboardSection) -> Void
    /// Lets a module stop at once when it is turned off (Ambiance stops its music).
    var onChange: (GoalongModule, Bool) -> Void = { _, _ in }
    @ObservedObject private var modules = GoalongModuleStore.shared
    @ObservedObject private var concentration = ConcentrationRuntime.shared
    @ObservedObject private var blocking = BlockingRuntime.shared
    @State private var confirmingDelete = false
    @State private var deleteMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(GoalongModule.allCases) { module in
                        row(module)
                        if module != GoalongModule.allCases.last { GoalongRowDivider() }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Supprimer les données Concentration", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(LHQuietButtonStyle())
                    .disabled(concentration.controller?.hasLockedBlock == true)
            }
            if let error = concentration.error {
                Text(FocusUIError.message(raw: error)).font(.callout)
            } else if let deleteMessage {
                GoalongNote(deleteMessage).accessibilityIdentifier("settings-concentration-delete-result")
            }
            GoalongNote("Un module désactivé ne tourne pas, n’installe rien et ne demande aucun accès.")
        }
        .onChange(of: concentration.error) { if $0 != nil { deleteMessage = nil } }
        .alert("Supprimer les données Concentration ?", isPresented: $confirmingDelete) {
            Button("Annuler", role: .cancel) {}
            // A failure and a success both show a message above.
            Button("Supprimer", role: .destructive) {
                deleteMessage = nil
                do {
                    try concentration.deleteData()
                    // A failed re-enable sets `concentration.error`; it must not hide behind a success note.
                    if concentration.error == nil { deleteMessage = "Données Concentration supprimées." }
                } catch {
                    deleteMessage = FocusUIError.message(error)
                }
            }
        } message: { Text("Séances, plans, bilans et réglages de ce module. Le reste de Goalong ne change pas.") }
    }

    private func row(_ module: GoalongModule) -> some View {
        let on = modules.isEnabled(module)
        let locked = (module == .blocking && blocking.controller?.moduleOffRefusal != nil) || (module == .concentration && concentration.controller?.hasLockedBlock == true)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: module.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.system(size: 13, weight: .medium))
                Text(locked ? "Un blocage verrouillé ou « Difficile » est en cours : impossible de désactiver avant sa fin." : module.summary)
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if on {
                Button("Ouvrir") { onOpen(section(module)) }.buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("settings-module-open-\(module.rawValue)")
            }
            Toggle(module.title, isOn: Binding(get: { on }, set: { value in
                modules.setEnabled(module, value)
                onChange(module, value)
            }))
                .toggleStyle(.goalongSwitchOnly).fixedSize()
                .disabled(locked)
                .accessibilityIdentifier("settings-module-\(module.rawValue)")
        }
        .padding(.horizontal, LHTheme.cardInset).frame(minHeight: 60)
    }

    private func section(_ module: GoalongModule) -> DashboardSection {
        switch module {
        case .blocking: return .blocking
        case .concentration: return .concentration
        case .ambiance: return .ambiance
        case .braise: return .braise
        }
    }
}
#endif
