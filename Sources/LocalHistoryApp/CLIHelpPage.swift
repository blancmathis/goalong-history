#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryQueryCLI
    import SwiftUI

    struct CLIHelpPage: View {
        private enum CopyState {
            case idle
            case copied
            case failed
        }

        let onBack: () -> Void
        @State private var copyState: CopyState = .idle
        @State private var copiedCommandID: String?
        @State private var showsInstructionPreview = false
        @State private var installationReport: GoalongCLIInstallationReport

        init(onBack: @escaping () -> Void = {}) {
            self.onBack = onBack
            _installationReport = State(initialValue: GoalongCLIInstallation.inspect())
        }

        private static let quickCommands = GoalongCLIContract.quickStartCommands
        static let agentInstructions = GoalongCLIContract.agentInstructions

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: "Accès pour les agents",
                        title: "Goalong CLI",
                        subtitle:
                            "Interrogez votre historique depuis le Terminal, ou donnez à un agent une consigne sûre. Données et erreurs en JSON ; aide en texte."
                    ) {
                        StatusPill(
                            title: statusTitle,
                            symbol: cliIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            tint: cliIsReady ? LHTheme.success : LHTheme.warning
                        )
                    }

                    readinessBanner
                    agentCard
                    quickCommandsCard
                    evidenceCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LHTheme.pageInset)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsBackBar(onBack: onBack)
            }
            .background(LHTheme.pageBackground)
        }

        private var readinessBanner: some View {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        LHTheme.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(readinessTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(
                        cliIsReady
                            ? "Le lien pointe vers cette version installée de Goalong. Chaque requête se termine après sa réponse, sans processus supplémentaire."
                            : installationReport.detail
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    installationReport = GoalongCLIInstallation.inspect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Vérifier de nouveau le lien de la commande goalong")
                .accessibilityLabel("Vérifier le lien")
            }
            .padding(14)
            .background(LHTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LHTheme.accent.opacity(0.12), lineWidth: 1)
            )
        }

        private var agentCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Give Goalong to an agent")
                                .font(.title3.weight(.bold))
                            Text(
                                "Copiez une consigne complète (commandes, traitement sûr des données, pagination, provenance, données manquantes) et collez-la telle quelle dans votre agent."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(action: copyAgentInstructions) {
                            Label(copyButtonTitle, systemImage: copyButtonSymbol)
                                .frame(minWidth: 172, minHeight: 32)
                        }
                        .buttonStyle(LHPrimaryButtonStyle())
                        .controlSize(.large)
                        .accessibilityHint("Copie toutes les instructions de la commande goalong pour un agent local")
                    }

                    GoalongDisclosureGroup("Preview agent instructions", isExpanded: $showsInstructionPreview) {
                        Text(Self.agentInstructions)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
        }

        private var quickCommandsCard: some View {
            LHCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Commencer dans le Terminal")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Ces quatre commandes suffisent pour découvrir l’outil et poser une première question.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)

                    Divider()

                    ForEach(Array(Self.quickCommands.enumerated()), id: \.element.id) { index, item in
                        commandRow(item)
                        if index < Self.quickCommands.count - 1 {
                            Divider().padding(.leading, 18)
                        }
                    }
                }
            }
        }

        private func commandRow(_ item: GoalongCLIQuickStartCommand) -> some View {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(item.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Text(item.command)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        LHTheme.elevatedBackground,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Button {
                    copyQuickCommand(item)
                } label: {
                    Image(systemName: copiedCommandID == item.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(item.title)")
                .accessibilityLabel("Copy command: \(item.title)")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }

        private var evidenceCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Ce que reçoit l’agent")
                        .font(.system(size: 15, weight: .semibold))
                    evidenceRow(
                        symbol: "curlybraces",
                        title: "JSON clair",
                        detail: "Données et erreurs sont en JSON structuré. L’aide est en texte ; `help --json` décrit le contrat machine."
                    )
                    evidenceRow(
                        symbol: "lock.shield",
                        title: "Les originaux restent en lecture seule",
                        detail:
                            "Les sources d’origine ne sont jamais modifiées. Le Temps d’écran du jour peut mettre à jour un enregistrement Goalong ; seul un export de preuve explicite crée un fichier."
                    )
                    evidenceRow(
                        symbol: "externaldrive",
                        title: "Limites des sources d’origine",
                        detail:
                            "Les conversations IA restent chez leur outil ; seuls les messages et réponses finales sont lus à la demande."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private func evidenceRow(symbol: String, title: String, detail: String) -> some View {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var cliIsReady: Bool {
            installationReport.state == .ready
        }

        private var statusTitle: String {
            switch installationReport.state {
            case .ready: return "CLI ready"
            case .missing: return "CLI missing"
            case .conflict: return "CLI conflict"
            }
        }

        private var readinessTitle: String {
            switch installationReport.state {
            case .ready: return "Verified for Terminal"
            case .missing: return "The command link is missing"
            case .conflict: return "The command link is not trusted"
            }
        }

        private var copyButtonTitle: String {
            switch copyState {
            case .idle: return "Copy agent instructions"
            case .copied: return "Instructions copied"
            case .failed: return "Copy failed"
            }
        }

        private var copyButtonSymbol: String {
            switch copyState {
            case .idle: return "doc.on.doc"
            case .copied: return "checkmark"
            case .failed: return "exclamationmark.triangle"
            }
        }

        private func copyAgentInstructions() {
            if GoalongClipboardWriter.copy(Self.agentInstructions) {
                copyState = .copied
                announce("Goalong agent instructions copied")
            } else {
                copyState = .failed
                announce("Les instructions pour l’agent n’ont pas pu être copiées")
            }
        }

        private func copyQuickCommand(_ item: GoalongCLIQuickStartCommand) {
            if GoalongClipboardWriter.copy(item.command) {
                copiedCommandID = item.id
                announce("Command copied: \(item.title)")
            } else {
                copiedCommandID = nil
                announce("La commande n’a pas pu être copiée")
            }
        }

        private func announce(_ message: String) {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: message]
            )
        }
    }
#endif
