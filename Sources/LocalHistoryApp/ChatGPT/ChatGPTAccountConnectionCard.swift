#if os(macOS)
import SwiftUI

struct ChatGPTAccountConnectionCard: View {
    @ObservedObject var runtime: ChatGPTRecapRuntime
    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.system(size: 21)).foregroundStyle(LHTheme.accent)
                        .frame(width: 40, height: 40)
                        .background(LHTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ChatGPT").font(.system(size: 16, weight: .semibold))
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                        if case .failed(let reason) = runtime.connectionState, !reason.isEmpty {
                            Text(reason).font(.system(size: 11)).foregroundStyle(LHTheme.warning)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    actions
                }
                Text("La connexion seule ne lance aucune analyse.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .onAppear { runtime.refreshAccount(userInitiated: true) }
    }
    private var status: String {
        switch runtime.connectionState {
        case .connected(let email, _): return email ?? "Compte connecté"
        case .checking: return "Vérification de la connexion…"
        case .codexUnavailable: return "Composant de connexion indisponible"
        case .signedOut: return "Non connecté"
        case .unsupportedCredentialMode: return "Utilisez une connexion ChatGPT, pas une clé API"
        case .failed: return "Connexion non vérifiée · réessayez"
        }
    }
    @ViewBuilder private var actions: some View {
        switch runtime.connectionState {
        case .connected:
            Button("Déconnecter") { runtime.disconnectChatGPT() }.buttonStyle(LHSecondaryButtonStyle())
        case .checking:
            ProgressView().controlSize(.small)
        case .codexUnavailable:
            Button("Mettre Goalong à jour") { SoftwareUpdateManager.shared.showAvailableUpdate() }.buttonStyle(LHSecondaryButtonStyle())
        default:
            Button(runtime.isConnecting ? "Connexion…" : "Connecter ChatGPT") { runtime.connectChatGPT() }
                .buttonStyle(LHPrimaryButtonStyle()).disabled(runtime.isConnecting)
        }
    }
}
#endif
