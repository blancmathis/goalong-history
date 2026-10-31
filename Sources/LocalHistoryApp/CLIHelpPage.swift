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
        @State private var linkCommandCopied = false
        @State private var showsInstructionPreview = false
        @State private var installationReport: GoalongCLIInstallationReport
        @State private var installOutcome: GoalongCLIInstallOutcome?

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
                        title: "Commande goalong",
                        subtitle:
                            "Interrogez votre historique depuis le Terminal, ou donnez à un agent une consigne sûre."
                    ) {
                        StatusPill(
                            title: statusTitle,
                            symbol: statusSymbol,
                            tint: statusTint
                        )
                    }

                    readinessBanner
                    if installationReport.canInstall || installOutcome != nil { installRow }
                    if let command = installationReport.linkCommand { linkCommandRow(command) }
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
            GoalongBanner(symbol: "terminal", title: readinessTitle,
                          detail: readinessDetail) {
                Button {
                    installationReport = GoalongCLIInstallation.inspect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Vérifier de nouveau le lien de la commande goalong")
                .accessibilityLabel("Vérifier le lien")
            }
        }

        /// C14-01: one click creates ~/.local/bin/goalong (or repairs a link to an old Goalong). The line to copy stays as fallback.
        private var installRow: some View {
            VStack(alignment: .leading, spacing: 8) {
                if installationReport.canInstall {
                    Button(action: installCommand) {
                        Label("Installer la commande", systemImage: "arrow.down.app")
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .help("Crée le lien ~/.local/bin/goalong vers cette app, sans mot de passe administrateur")
                }
                if let installOutcome {
                    Label(installOutcome.message, systemImage: installOutcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(installOutcome.succeeded ? LHTheme.success : LHTheme.warning)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func installCommand() {
            let outcome = GoalongCLIInstallation.install()
            installOutcome = outcome
            installationReport = GoalongCLIInstallation.inspect()
            announce(outcome.message)
        }

        /// The DMG and Sparkle do not create the command: the exact line to paste, built from this app's path.
        private func linkCommandRow(_ command: String) -> some View {
            HStack(alignment: .center, spacing: 12) {
                // UI-55: a path is never cut in the middle; the line scrolls instead of wrapping. The copied value is unchanged.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    linkCommandCopied = GoalongClipboardWriter.copy(command)
                    announce(linkCommandCopied ? "Commande copiée" : "La commande n’a pas pu être copiée")
                } label: {
                    Image(systemName: linkCommandCopied ? "checkmark" : "doc.on.doc")
                }
                // UI-55: same form as the other copy buttons, a glyph in ink (lime is the screen's main action).
                .buttonStyle(LHQuietButtonStyle())
                .help("Copier la commande qui crée ~/.local/bin/goalong")
                .accessibilityLabel(linkCommandCopied ? "Commande copiée" : "Copier la commande")
            }
            .padding(12)
            .background(LHTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        private var agentCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Donner Goalong à un agent")
                                .font(.title3.weight(.bold))
                            Text(
                                "Copiez une consigne complète (commandes, traitement sûr des données, pagination, provenance, données manquantes) et collez-la telle quelle dans votre agent."
                            )
                            .font(.subheadline)
                            .foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        // UI-55: one lime action per screen, at the standard size. While the command is not
                        // installed, « Installer la commande » is that action.
                        Button(action: copyAgentInstructions) {
                            Label(copyButtonTitle, systemImage: copyButtonSymbol)
                        }
                        .modifier(GoalongMainActionStyle(primary: !installationReport.canInstall))
                        .accessibilityHint("Copie toutes les instructions de la commande goalong pour un agent local")
                    }

                    GoalongDisclosureGroup("Aperçu des instructions (en anglais, pour l’agent)", isExpanded: $showsInstructionPreview) {
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
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
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
                    Text(Self.frenchTitle(item))
                        .font(.system(size: 12, weight: .semibold))
                    Text(Self.frenchDetail(item))
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
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
                .buttonStyle(LHQuietButtonStyle())
                .help("Copier « \(item.command) »")
                .accessibilityLabel("Copier la commande : \(Self.frenchTitle(item))")
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
                        title: "Format lisible par les programmes",
                        detail: "Les données et les erreurs sont structurées.",
                        more: "L’aide est en texte ; « goalong help --json » décrit le format."
                    )
                    evidenceRow(
                        symbol: "lock.shield",
                        title: "Les originaux restent en lecture seule",
                        detail: "Les sources d’origine ne sont jamais modifiées.",
                        more: "Le Temps d’écran du jour peut mettre à jour un enregistrement Goalong ; seul un export de preuve explicite crée un fichier."
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

        private func evidenceRow(symbol: String, title: String, detail: String, more: String? = nil) -> some View {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    // UI-14: one sentence on the page, the rest in « En savoir plus » (DESIGN §12).
                    if let more { GoalongHelpText(lead: detail, more: more) } else {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        private var statusTitle: String {
            switch installationReport.state {
            case .ready: return "Commande prête"
            case .missing: return "Commande absente"
            case .conflict: return "Conflit de commande"
            case .development: return "Commande de Goalong installé"
            }
        }

        // Goalong Dev never owns the command: a normal state, shown neutral rather than as a warning.
        private var statusTint: Color {
            switch installationReport.state {
            case .ready: return LHTheme.success
            case .development: return LHTheme.secondaryText
            case .missing, .conflict: return LHTheme.warning
            }
        }

        private var statusSymbol: String {
            switch installationReport.state {
            case .ready: return "checkmark.circle.fill"
            case .development: return "info.circle.fill"
            case .missing, .conflict: return "exclamationmark.triangle.fill"
            }
        }

        private var readinessTitle: String {
            switch installationReport.state {
            case .ready: return "Vérifiée pour le Terminal"
            case .missing: return "Installez la commande goalong"
            case .conflict: return "Le lien de la commande n’est pas fiable"
            case .development: return "La commande goalong sert Goalong installé"
            }
        }

        private var readinessDetail: String {
            switch installationReport.state {
            case .ready:
                return "Le lien pointe vers cette version installée de Goalong. Chaque requête se termine après sa réponse, sans processus supplémentaire."
            case .development:
                guard let path = installationReport.developmentCLIPath else { return installationReport.detail }
                return installationReport.detail + " Exécutable de Goalong Dev : " + path
            case .missing, .conflict:
                return installationReport.detail
            }
        }

        private var copyButtonTitle: String {
            switch copyState {
            case .idle: return "Copier les instructions"
            case .copied: return "Instructions copiées"
            case .failed: return "Copie impossible"
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
                announce("Instructions pour l’agent copiées")
            } else {
                copyState = .failed
                announce("Les instructions pour l’agent n’ont pas pu être copiées")
            }
        }

        private func copyQuickCommand(_ item: GoalongCLIQuickStartCommand) {
            if GoalongClipboardWriter.copy(item.command) {
                copiedCommandID = item.id
                announce("Commande copiée : \(Self.frenchTitle(item))")
            } else {
                copiedCommandID = nil
                announce("La commande n’a pas pu être copiée")
            }
        }

        /// The CLI's own help stays in English for agents; the French page describes it.
        static func frenchTitle(_ item: GoalongCLIQuickStartCommand) -> String {
            switch item.command {
            case "goalong status": return "Vérifier chaque source"
            case "goalong days": return "Trouver les jours disponibles"
            case "goalong help": return "Consulter les commandes exactes"
            default: return item.command.hasPrefix("goalong ask") ? "Poser une question sur votre journée" : item.title
            }
        }

        static func frenchDetail(_ item: GoalongCLIQuickStartCommand) -> String {
            switch item.command {
            case "goalong status": return "Accord, fraîcheur, couverture et erreurs, sans ouvrir le contenu des conversations."
            case "goalong days": return "Liste les dates auxquelles Goalong peut répondre avec les données locales."
            case "goalong help": return "Aide lisible ; ajoutez --json quand un agent a besoin du contrat des commandes."
            default:
                return item.command.hasPrefix("goalong ask")
                    ? "Goalong choisit le plus petit ensemble de données locales utiles." : item.detail
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
