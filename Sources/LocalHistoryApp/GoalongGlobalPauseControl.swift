#if os(macOS)
import SwiftUI
import LocalHistoryCore

struct GoalongGlobalPauseControl: View {
    @ObservedObject var model: DashboardViewModel
    var compact = false
    @State private var pause = GoalongGlobalPause.load()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                do {
                    pause = try GoalongGlobalPause.setPaused(!pause.paused,
                        recordingWasPaused: model.runtime.state == .paused)
                } catch { self.error = error.localizedDescription }
            } label: {
                Label(pause.blocksActivity ? "Reprendre Goalong" : "Pause globale",
                      systemImage: pause.blocksActivity ? "play.circle" : "pause.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            }.buttonStyle(.bordered).disabled(pause.invalid)
                .accessibilityIdentifier("goalong-global-pause")
                .help("Suspendre le suivi, les lectures Apple et IA, les analyses et les envois. Les choix autorisés sont conservés.")
            if !compact {
                Text("Apple et les autres apps continuent leur propre historique, qui peut être relu après reprise. Un envoi déjà commencé peut aboutir.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
        .alert("Pause non modifiée", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Fermer", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

struct GoalongGlobalPauseBanner: View {
    @ObservedObject var model: DashboardViewModel
    @State private var pause = GoalongGlobalPause.load()
    var body: some View {
        Group {
            if pause.blocksActivity {
                HStack(spacing: 14) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(LHTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pause globale").font(.system(size: 13, weight: .semibold))
                        Text(pause.invalid ? "Réglage illisible : reprise bloquée par sécurité." : "Sources et envois suspendus. Vos choix sont conservés.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    GoalongGlobalPauseControl(model: model, compact: true).frame(width: 170)
                }.padding(14).background(LHTheme.cardBackground)
                Divider()
            }
        }.onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
    }
}
#endif
