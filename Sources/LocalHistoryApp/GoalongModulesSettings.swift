#if os(macOS)
import SwiftUI

/// Réglages › Modules: one switch per optional part of Goalong.
@MainActor struct GoalongModulesSettings: View {
    var onOpen: (DashboardSection) -> Void
    @ObservedObject private var modules = GoalongModuleStore.shared
    @ObservedObject private var concentration = ConcentrationRuntime.shared
    @ObservedObject private var blocking = BlockingRuntime.shared

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
            if modules.isEnabled(.concentration) {
                Button("Supprimer les données Concentration") { do { try concentration.deleteData() } catch { concentration.controller?.error = String(describing: error) } }
                    .disabled(concentration.controller?.hasLockedBlock == true)
            } else {
                Button("Supprimer les données Concentration") { do { try concentration.deleteData() } catch { } }
            }
            if let error = concentration.error { Text(error).font(.callout) }
            GoalongNote("Un module désactivé ne tourne pas, n’installe rien et ne demande aucun accès.")
        }
    }

    private func row(_ module: GoalongModule) -> some View {
        let on = modules.isEnabled(module)
        let locked = (module == .blocking && blocking.controller?.hasLocks == true) || (module == .concentration && concentration.controller?.hasLockedBlock == true)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: module.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.system(size: 13, weight: .medium))
                Text(locked ? "Un blocage verrouillé est en cours : impossible de désactiver avant la fin." : module.summary)
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if on {
                Button("Ouvrir") { onOpen(section(module)) }.buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("settings-module-open-\(module.rawValue)")
            }
            Toggle(module.title, isOn: Binding(get: { on }, set: { modules.setEnabled(module, $0) }))
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
        }
    }
}
#endif
