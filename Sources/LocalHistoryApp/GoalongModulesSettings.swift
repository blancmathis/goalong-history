#if os(macOS)
import SwiftUI

/// Réglages › Modules: one switch per optional part of Goalong.
@MainActor struct GoalongModulesSettings: View {
    var onOpen: (DashboardSection) -> Void
    /// Lets a module stop at once when it is turned off (Ambiance stops its music).
    var onChange: (GoalongModule, Bool) -> Void = { _, _ in }
    @ObservedObject var modules = GoalongModuleStore.shared
    /// M3 (R4d-19): injectable so a test can render the delete link's state; the app keeps the shared runtime.
    @ObservedObject var concentration: ConcentrationRuntime = .shared
    @ObservedObject private var blocking = BlockingRuntime.shared
    /// The gallery shows a running locked block without starting the Blocage runtime.
    var blockingController: BlockingController?
    @State private var confirmingDelete = false
    @State private var deleteMessage: String?
    /// Commitments live in the same folder: open ones go too, without a result (T-045 H5-01).
    /// VoiceOver names the module on each « Ouvrir » button; the label starts with the visible word (Voice Control).
    nonisolated static func openAccessibilityLabel(_ module: GoalongModule) -> String { "Ouvrir \(module.title)" }
    static let concentrationKeptData = "Ses séances, plans et engagements restent sur ce Mac, même si le module est désactivé."
    static let concentrationDeleteMessage = "Séances, plans, bilans, engagements (en cours compris) et réglages de ce module. Le reste de Goalong ne change pas."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(GoalongModule.listed) { module in
                        row(module)
                        if module != GoalongModule.listed.last { GoalongRowDivider() }
                    }
                }
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
        } message: { Text(Self.concentrationDeleteMessage) }
    }

    static func surveillanceStep(_ module: GoalongModule) -> JevStopGate.Step? {
        switch module {
        case .concentration: return JevStopGate.focusStep()
        case .blocking: return JevStopGate.blockStep()
        default: return nil
        }
    }

    private func row(_ module: GoalongModule) -> some View {
        let on = modules.isEnabled(module)
        let locked = (module == .blocking && (blockingController ?? blocking.controller)?.moduleOffRefusal != nil) || (module == .concentration && concentration.controller?.hasLockedBlock == true)
        return HStack(alignment: .center, spacing: 12) {
            // R-98 (R4d-13): the icon sits on the title's line in every row, also in the taller Concentration row.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: module.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.system(size: 13, weight: .medium))
                Text(locked ? "Un blocage verrouillé ou « Difficile » est en cours : impossible de désactiver avant sa fin." : module.summary)
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                // Concentration's data delete sits in its own row, not under every module.
                // Says which data stay on this Mac before offering to delete them (UI-46), then the link on its own line (UI-9 C).
                if module == .concentration {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.concentrationKeptData).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        // UI-13C (42): the link says what it deletes.
                        Button("Supprimer les données de Concentration…", role: .destructive) { confirmingDelete = true }
                            .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(LHTheme.danger)
                            // R-77 (R9C-54): held back, with the reason, when there is nothing to delete.
                            .disabled(concentration.controller?.hasLockedBlock == true || !concentration.hasStoredData)
                            .help(concentration.hasStoredData ? "" : "Aucune donnée de Concentration sur ce Mac.")
                            .onAppearWhenShown { concentration.refreshHasData() }
                    }.padding(.top, 2).padding(.bottom, 6) // The red link keeps clear of the row's divider (UI-11C).
                }
            }
            }
            Spacer(minLength: 12)
            if on {
                // R7 (42): a bordered secondary button, so « Ouvrir » reads as clickable (UI-17A).
                Button("Ouvrir") { onOpen(section(module)) }.buttonStyle(LHSecondaryButtonStyle())
                    // R-265: VoiceOver names the module, not five bare « Ouvrir ».
                    .accessibilityLabel(Self.openAccessibilityLabel(module))
                    .accessibilityIdentifier("settings-module-open-\(module.rawValue)")
            }
            Toggle(module.title, isOn: Binding(get: { on }, set: { value in
                // T-050 B1: turning off the module of a session that carries a protected « Surveillance » ends it: its stop first.
                if !value, let step = Self.surveillanceStep(module),
                   !JevStopGate.confirm(action: "Désactiver \(module.title)", step: step) { return }
                // The stop was passed (or nothing to ask): the runtime's own check lets this one off through.
                concentration.surveillanceOffConfirmed = !value && module == .concentration
                modules.setEnabled(module, value)
                concentration.surveillanceOffConfirmed = false
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
