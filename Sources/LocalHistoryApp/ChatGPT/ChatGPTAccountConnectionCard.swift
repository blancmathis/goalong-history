#if os(macOS)
import SwiftUI

struct ChatGPTAccountConnectionCard: View {
    @ObservedObject var runtime: ChatGPTRecapRuntime
    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ChatGPT").font(LHTheme.cardTitleFont)
                        Text(status).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        if case .failed(let reason) = runtime.connectionState, !reason.isEmpty {
                            Text(reason).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    actions
                }
                Text("La connexion seule ne lance aucune analyse.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
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
        case .failed: return "Connexion non vérifiée, réessayez"
        }
    }
    @ViewBuilder private var actions: some View {
        switch runtime.connectionState {
        case .connected:
            Button("Déconnecter") { runtime.disconnectChatGPT() }.buttonStyle(LHSecondaryButtonStyle())
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                if runtime.isConnecting {
                    Button("Annuler") { runtime.cancelChatGPTConnection() }.buttonStyle(LHSecondaryButtonStyle())
                }
            }
        case .codexUnavailable:
            // The only way forward, so it is the primary action (UI-49).
            Button("Mettre Goalong à jour") { SoftwareUpdateManager.shared.showAvailableUpdate() }.buttonStyle(LHPrimaryButtonStyle())
        default:
            HStack(spacing: 10) {
                if runtime.isConnecting {
                    Button("Annuler") { runtime.cancelChatGPTConnection() }.buttonStyle(LHSecondaryButtonStyle())
                }
                Button(runtime.isConnecting ? "Connexion…" : "Connecter ChatGPT") { runtime.connectChatGPT() }
                    .buttonStyle(LHPrimaryButtonStyle()).disabled(runtime.isConnecting)
            }
        }
    }
}
#endif
