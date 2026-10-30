#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// One wording for the global pause, shared by the window and the menu bar.
enum GoalongGlobalPauseText {
    static let resume = "Reprendre tout le suivi"
    static let failureTitle = "Pause non modifiée"
    static let repair = "Réparer et reprendre"
    static let repairTitle = "Réparer le réglage de pause ?"
    static let repairMessage = "Le fichier de pause est abîmé. Goalong le met de côté dans son dossier de données, puis reprend le suivi, les analyses et les envois."
    static let damagedNotice = "Le réglage de pause est abîmé. Le suivi reste arrêté par sécurité."
    static let repairFailureTitle = "Réparation impossible"
}

struct GoalongGlobalPauseControl: View {
    @ObservedObject var model: DashboardViewModel
    var compact = false
    @State private var pause = GoalongGlobalPause.load()
    @State private var error: String?
    @State private var confirming = false
    @State private var confirmingRepair = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if pause.invalid { confirmingRepair = true }
                else if pause.blocksActivity { changePause(false) }
                else { confirming = true }
            } label: {
                Label(pause.invalid ? GoalongGlobalPauseText.repair + "…" : pause.blocksActivity ? GoalongGlobalPauseText.resume : "Tout suspendre…",
                      systemImage: pause.blocksActivity ? "play.circle" : "pause.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            }.goalongPauseButtonStyle(primary: pause.blocksActivity)
                .accessibilityIdentifier("goalong-global-pause")
                .help("Suspendre le suivi, les lectures Apple et IA, les analyses et les envois. Les choix autorisés sont conservés.")
            if !compact {
                Text("Apple et les autres apps continuent leur propre historique, qui peut être relu après reprise. Un envoi déjà commencé peut aboutir.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
        .alert("Suspendre aussi l’historique ?", isPresented: $confirming) {
            Button("Annuler", role: .cancel) {}
            Button("Tout suspendre", role: .destructive) { changePause(true) }
        } message: {
            Text("L’historique, les analyses et les envois seront suspendus jusqu’à votre reprise. Pour une pause détente sans trou dans l’historique, utilisez la pause de surveillance.")
        }
        .alert(GoalongGlobalPauseText.repairTitle, isPresented: $confirmingRepair) {
            Button("Annuler", role: .cancel) {}
            Button(GoalongGlobalPauseText.repair) { repair() }
        } message: { Text(GoalongGlobalPauseText.repairMessage) }
        .alert(GoalongGlobalPauseText.failureTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Fermer", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
    private func repair() {
        do { pause = try GoalongGlobalPause.repairAndResume() }
        catch { self.error = GoalongUserFacingError.message(error) }
    }
    private func changePause(_ paused: Bool) {
        do { pause = try GoalongGlobalPause.setPaused(paused, recordingWasPaused: model.runtime.state == .paused) }
        catch { self.error = GoalongUserFacingError.message(error) }
    }
}

private extension View {
    /// While everything is paused, resuming is the one main action of the window (DESIGN §9).
    @ViewBuilder func goalongPauseButtonStyle(primary: Bool) -> some View {
        if primary { buttonStyle(LHPrimaryButtonStyle()) } else { buttonStyle(LHSecondaryButtonStyle()) }
    }
}

struct GoalongGlobalPauseBanner: View {
    @ObservedObject var model: DashboardViewModel
    @State private var pause = GoalongGlobalPause.load()
    var body: some View {
        Group {
            if pause.blocksActivity {
                HStack(spacing: 14) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(LHTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Suivi en pause").font(.system(size: 13, weight: .semibold))
                        Text(pause.invalid ? GoalongGlobalPauseText.damagedNotice : "Tout le suivi est arrêté, pas seulement la surveillance. Reprenez-le pour enregistrer à nouveau.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // The action keeps its whole name: the text beside it wraps instead.
                    GoalongGlobalPauseControl(model: model, compact: true).fixedSize()
                }
                // Same inset as the other top banners: the action stays inside the page edge.
                .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 12).background(LHTheme.cardBackground)
                Divider()
            }
        }.onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
    }
}
#endif
