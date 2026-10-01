#if os(macOS)
    import SwiftUI

    struct PrivacyPage: View {
        @ObservedObject var model: DashboardViewModel
        @State private var deletionScope: DeletionScope?
        @State private var sessionPendingDeletion: ActivitySession?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: "Local par conception",
                        title: "Confidentialité et sécurité",
                        subtitle: "Voyez exactement ce qui est enregistré, ce qui est masqué et ce qui peut quitter votre Mac."
                    ) {
                        HStack(spacing: 10) {
                            Button("Ouvrir le dossier des données") {
                                model.openDataFolder()
                            }
                            .buttonStyle(LHSecondaryButtonStyle())
                            Button {
                                model.refreshEverything()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(LHSecondaryButtonStyle())
                        }
                    }

                    PrivacyChoicesOverview(model: model)
                    VisibleContextControl()
                    GoalongDisclosureGroup("Version et vérification") {
                        VStack(spacing: 14) { buildSecurityCard; dataFlowCard }.padding(.top, 12)
                    }
                    permissionsCard
                    protectionGrid

                    HStack(alignment: .top, spacing: 14) {
                        storageCard
                            .frame(maxWidth: .infinity)
                        identityCard
                            .frame(maxWidth: .infinity)
                    }

                    deletionCard
                }
                .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
                .padding(.horizontal, LHTheme.pageInset)
                .padding(.top, 28)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(LHTheme.pageBackground)
            .alert(item: $deletionScope) { scope in
                Alert(
                    title: Text(scope.title),
                    message: Text(scope.message),
                    primaryButton: .destructive(Text("Supprimer")) {
                        model.deleteDetails(since: scope.cutoff)
                    },
                    secondaryButton: .cancel()
                )
            }
        }

        private var buildSecurityCard: some View {
            let capabilities = GoalongBuildCapabilities.self
            return LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Cette version précise",
                        subtitle: "Les capacités sont fixées à la compilation, pas cachées derrière un réglage."
                    )

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(LHTheme.success)
                            .frame(width: 44, height: 44)
                            .background(
                                LHTheme.success.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Goalong History · une seule app publique")
                                .font(.system(size: 13, weight: .semibold))
                            Text(capabilities.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        StatusPill(
                            title: capabilities.edition.displayName,
                            symbol: "internaldrive.fill",
                            tint: LHTheme.success
                        )
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        capabilityRow(
                            "Envoi au site après vérification",
                            present: capabilities.permitsFirstPartyNetworking
                        )
                        capabilityRow(
                            "Module de mise à jour automatique",
                            present: capabilities.permitsAutomaticUpdates
                        )
                        capabilityRow(
                            "Passerelle d’analyse ChatGPT",
                            present: capabilities.permitsRemoteAnalysis
                        )
                        capabilityRow("Lecteurs directs des sources locales", present: true)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(LHTheme.warning)
                        Text(
                            "L’accès complet au disque reste une autorisation macOS large. Les lecteurs sont en lecture seule et audités, mais s’exécutent dans l’app principale ; un service de lecture isolé n’est pas encore livré."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .background(
                        LHTheme.warning.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }
        }

        private func capabilityRow(_ title: String, present: Bool) -> some View {
            HStack(spacing: 8) {
                Image(systemName: present ? "checkmark.circle.fill" : "minus.circle.fill")
                    .foregroundStyle(present ? LHTheme.accent : LHTheme.success)
                Text("\(title) : \(present ? "présent" : "absent")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }

        private var dataFlowCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 18) {
                    SectionTitle(
                        title: "Ce que deviennent vos données",
                        subtitle: GoalongBuildCapabilities.permitsRemoteVerification
                            ? "L’enregistrement détaillé et la preuve cryptographique suivent des chemins séparés"
                            : "Enregistrements détaillés et preuves d’intégrité restent séparés et locaux"
                    )

                    HStack(alignment: .center, spacing: 12) {
                        flowNode(
                            symbol: "macwindow",
                            title: "1. Observé",
                            message: "Apps, fenêtres, clics et activité de saisie sans contenu"
                        )
                        flowArrow
                        flowNode(
                            symbol: "internaldrive.fill",
                            title: "2. Conservé localement",
                            message: "Événements détaillés (JSONL) et sels d’engagement privés"
                        )
                        flowArrow
                        flowNode(
                            symbol: "number.square.fill",
                            title: "3. Ancré",
                            message: GoalongBuildCapabilities.permitsRemoteVerification
                                ? (model.runtime.verificationEnabled
                                    ? "Uniquement des engagements signés opaques"
                                    : "Conservés localement tant que la vérification n’est pas activée")
                                : "Les engagements locaux ne quittent jamais cette version"
                        )
                        flowArrow
                        flowNode(
                            symbol: "eye.slash.fill",
                            title: "4. Partage sélectif",
                            message: "Uniquement les champs que vous révélez, avec leurs preuves"
                        )
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(LHTheme.accent)
                        Text(
                            GoalongBuildCapabilities.permitsRemoteVerification
                                ? "Un engagement opaque ne contient ni l’application, ni l’adresse, ni le titre de fenêtre, ni les clics, ni la catégorie. Lorsque les engagements sont activés, votre serveur voit nécessairement des métadonnées de connexion comme l’heure d’arrivée et l’adresse IP."
                                : "Les engagements locaux vérifient l’intégrité sans exposer l’enregistrement détaillé ni contacter de serveur. Cette version ne transmet aucun engagement."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .background(
                        LHTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }

        private var permissionsCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    SectionTitle(
                        title: "Autorisations macOS",
                        subtitle: "Aucun accès n’est nécessaire pour les sources désactivées. L’autorisation macOS et votre choix d’activer une source sont distincts."
                    )

                    GoalongDisclosureGroup("Diagnostic de l’enregistrement") { captureHealthPanel.padding(.top, 12) }

                    VStack(spacing: 16) {
                        permissionRow(
                            title: "Accessibilité",
                            message: "Lit le contexte au premier plan pour l’historique. Goalong n’ouvre Réglages Système qu’à votre demande et ne modifie jamais les autorisations à votre place.",
                            granted: model.runtime.accessibilityGranted,
                            grantedLabel: "Accordé",
                            buttonTitle: "Configuration guidée",
                            action: model.openAccessibilitySettings
                        )
                        permissionRow(
                            title: "Surveillance de l’entrée",
                            message: "Indique l’état de la surveillance de l’entrée. Un vrai événement reste nécessaire avant de considérer l’enregistrement comme fonctionnel.",
                            granted: model.runtime.inputMonitoringGranted,
                            grantedLabel: "Disponible",
                            buttonTitle: "Configuration guidée",
                            action: model.openInputMonitoringSettings
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accès complet au disque").font(.system(size: 13, weight: .semibold))
                        Text("Le Temps d’écran est lu directement dans les fichiers d’Apple. L’accès complet au disque est une autorisation large, pas limitée à un dossier ; vous pouvez laisser cette source désactivée. Si Goalong manque dans la liste, ajoutez Goalong History depuis Applications avec +, puis revenez vérifier l’accès.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Ouvrir les réglages d’accès complet au disque") {
                            SourceAccessService.openAccess(.fullDiskAccess)
                        }.buttonStyle(LHSecondaryButtonStyle())
                    }

                    if let health = model.runtime.captureHealth,
                        [.permissionRequired, .permissionAppearsEnabledButStaleForBuild,
                         .accessibilityContextUnavailable].contains(health.state)
                    {
                        HStack {
                            Label(health.state.frenchDetail, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LHTheme.warning)
                            Spacer()
                            Button("Ouvrir la configuration guidée") { model.requestPermissions() }
                                .buttonStyle(LHPrimaryButtonStyle())
                        }
                    } else if model.runtime.captureHealth?.captureProven != true {
                        HStack {
                            Label(
                                "Les autorisations semblent présentes, mais aucun vrai événement de saisie n’a encore été reçu.",
                                systemImage: "waveform.path.ecg"
                            )
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LHTheme.warning)
                            Spacer()
                            Button("Vérifier la saisie") { model.beginCaptureValidation() }
                                .buttonStyle(LHPrimaryButtonStyle())
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LHTheme.success)
                            Text("Un vrai événement de saisie et le contexte d’accessibilité ont été observés.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        private var captureHealthPanel: some View {
            let assessment = model.runtime.captureHealth
            let snapshot = model.runtime.captureHealthSnapshot
            return VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: assessment?.captureProven == true ? "checkmark.shield.fill" : "waveform.path.ecg")
                        .foregroundStyle(assessment?.captureProven == true ? LHTheme.success : LHTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(assessment?.state.frenchTitle ?? "État de l’enregistrement indisponible")
                            .font(.system(size: 12, weight: .semibold))
                        Text(assessment?.state.frenchDetail ?? "Aucun indicateur d’état d’enregistrement n’est encore disponible.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Vérifier la saisie maintenant") { model.beginCaptureValidation() }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .controlSize(.small)
                }
                if let snapshot {
                    Text(
                        "Dernière saisie : \(snapshot.lastInputEventAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais") · clic : \(snapshot.lastClickAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais") · frappe : \(snapshot.lastTypingBurstAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais") · défilement : \(snapshot.lastScrollAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais") · raccourci : \(snapshot.lastShortcutAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais")"
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "AX : \(snapshot.lastAXContextSuccessAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais") · URL : \(snapshot.lastURLDetectedAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais") · masquage : \(snapshot.lastSuppressionReason?.rawValue ?? "aucun") à \(snapshot.lastSuppressionAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "jamais")"
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "Autorisations : interrupteur AX \(snapshot.permissions.accessibilityPreflight ? "activé" : "désactivé") · test AX \(snapshot.permissions.accessibilityFunctionalProbe ? "réussi" : "échoué") · Surveillance de l’entrée \(snapshot.permissions.inputMonitoringPreflight ? "activée" : "désactivée") · capture \(snapshot.eventTapLifecycle.rawValue)"
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "Version : \(snapshot.build.signatureKind.rawValue) · \(snapshot.build.codeDirectoryHash.map { String($0.prefix(14)) } ?? "sans CDHash") · saisies sur 5 min : \(snapshot.recentCounters.inputEventCount)"
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    if snapshot.build.signatureKind == .adHoc {
                        Text("Une mise à jour non signée par Apple peut changer l’identité reconnue par macOS et redemander une autorisation. L’historique existant reste lisible.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LHTheme.warning)
                    }
                }
            }
            .padding(13)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var protectionGrid: some View {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                protectionCard(
                    symbol: "person.fill.questionmark",
                    title: "Navigation privée",
                    message:
                        "Votre choix pour les fenêtres privées est indiqué ci-dessus. La détection dépend du navigateur ; utilisez la pause pour une activité sensible.",
                    tint: LHTheme.privateTint
                )
                protectionCard(
                    symbol: "key.fill",
                    title: "Mots de passe et champs sécurisés",
                    message: "La saisie sécurisée masque l’activité clavier. Vérifiez les exclusions des gestionnaires de mots de passe dans Enregistrement.",
                    tint: LHTheme.success
                )
                protectionCard(
                    symbol: "keyboard.badge.ellipsis",
                    title: "Aucun texte tapé",
                    message: "\(ProductIdentity.displayName) conserve le nombre de frappes, leur durée et l’usage générique des raccourcis, jamais les caractères ni les touches exactes.",
                    tint: LHTheme.teal
                )
                protectionCard(
                    symbol: "link.badge.plus",
                    title: "Adresses nettoyées",
                    message: model.appliedSettings.redactAllURLQueryValues
                        ? "Les paramètres et fragments d’adresse sont retirés avant l’enregistrement."
                        : "Les paramètres sensibles sont masqués ; le masquage complet est désactivé.",
                    tint: LHTheme.accent
                )
            }
        }

        private var storageCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Stockage local",
                        subtitle: "Fichiers lisibles, protégés par votre compte macOS"
                    )

                    infoRow(
                        symbol: "externaldrive.fill",
                        title: "Taille actuelle",
                        value: DashboardFormatters.byteCount.string(fromByteCount: model.snapshot.storageBytes)
                    )
                    infoRow(
                        symbol: "calendar",
                        title: "Conservation",
                        value: "Réglages › Stockage"
                    )
                    infoRow(
                        symbol: "doc.text",
                        title: "Jours disponibles",
                        value: "\(model.snapshot.availableDays.count)"
                    )
                    infoRow(
                        symbol: "lock.fill",
                        title: "Permissions des fichiers",
                        value: "Dossiers 0700 · fichiers 0600"
                    )

                    HStack {
                        Button("Ouvrir le dossier") { model.openDataFolder() }
                            .buttonStyle(LHSecondaryButtonStyle())
                        Button("Ouvrir le JSONL") { model.openTodayJSON() }
                            .buttonStyle(LHSecondaryButtonStyle())
                        Button("Diagnostics") { model.openDiagnostics() }
                            .buttonStyle(LHSecondaryButtonStyle())
                    }
                }
            }
        }

        private var identityCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Identité de vérification",
                        subtitle: "Sert à signer les engagements minute par minute sans exposer l’activité"
                    )

                    HStack(spacing: 13) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(LHTheme.success)
                            .frame(width: 48, height: 48)
                            .background(
                                LHTheme.success.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.deviceProtectionTitle)
                                .font(.system(size: 13, weight: .semibold))
                            Text(model.deviceAlgorithm)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("IDENTIFIANT DE L’APPAREIL")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text(model.deviceID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(11)
                    .background(
                        Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack {
                        StatusPill(
                            title: model.runtime.verificationEnabled ? "Vérification activée" : "Aucune vérification externe",
                            symbol: model.runtime.verificationEnabled ? "checkmark.seal.fill" : "internaldrive",
                            tint: model.runtime.verificationEnabled ? LHTheme.accent : Color.secondary
                        )
                        Spacer()
                    }
                }
            }
        }

        private var deletionCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Supprimer l’activité locale et les souvenirs dérivés")
                            .font(.system(size: 14, weight: .semibold))
                        Text(
                            "Supprimer l’activité retire aussi son contexte, ses analyses et ses vues dérivées. L’index des conversations IA, le Temps d’écran, les engagements et les reçus sont conservés."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 20)
                    Menu {
                        if let recent = model.mostRecentActivitySession {
                            Button("Dernière session d’application", role: .destructive) {
                                sessionPendingDeletion = recent
                            }
                            Divider()
                        }
                        Button("10 dernières minutes", role: .destructive) {
                            deletionScope = .lastTenMinutes
                        }
                        Button("Dernière heure", role: .destructive) {
                            deletionScope = .lastHour
                        }
                        Divider()
                        Button("Toute l’activité locale et les souvenirs", role: .destructive) {
                            deletionScope = .all
                        }
                    } label: {
                        Label("Supprimer les détails…", systemImage: "trash")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .alert(item: $sessionPendingDeletion) { session in
                Alert(
                    title: Text("Supprimer la dernière session d’application ?"),
                    message: Text(
                        "Goalong supprimera uniquement les événements locaux de \(session.appName) entre \(DashboardFormatters.shortTime.string(from: session.start)) et \(DashboardFormatters.shortTime.string(from: session.end)), ainsi que les instantanés liés. Sceaux, reçus, Temps d’écran et conversations IA sont conservés."
                    ),
                    primaryButton: .destructive(Text("Supprimer la session")) {
                        model.deleteActivitySession(session)
                    },
                    secondaryButton: .cancel()
                )
            }
        }

        private func flowNode(symbol: String, title: String, message: String) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var flowArrow: some View {
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
        }

        private func permissionRow(
            title: String,
            message: String,
            granted: Bool,
            grantedLabel: String,
            buttonTitle: String,
            action: @escaping () -> Void
        ) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(granted ? LHTheme.success : LHTheme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    Text(grantedLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LHTheme.success)
                } else {
                    Button(buttonTitle, action: action)
                        .buttonStyle(LHSecondaryButtonStyle())
                        .controlSize(.small)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private func protectionCard(symbol: String, title: String, message: String, tint: Color) -> some View {
            LHCard(padding: 15) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        private func infoRow(symbol: String, title: String, value: String) -> some View {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }

    private enum DeletionScope: Identifiable {
        case lastTenMinutes
        case lastHour
        case all

        var id: String {
            switch self {
            case .lastTenMinutes: return "ten"
            case .lastHour: return "hour"
            case .all: return "all"
            }
        }

        var cutoff: Date? {
            switch self {
            case .lastTenMinutes: return Date().addingTimeInterval(-10 * 60)
            case .lastHour: return Date().addingTimeInterval(-60 * 60)
            case .all: return nil
            }
        }

        var title: String {
            switch self {
            case .lastTenMinutes: return "Supprimer les 10 dernières minutes ?"
            case .lastHour: return "Supprimer la dernière heure ?"
            case .all: return "Supprimer toute l’activité locale et les souvenirs dérivés ?"
            }
        }

        var message: String {
            "Les événements détaillés de la période, leur contexte et toutes les analyses qui en dérivent seront définitivement supprimés de ce Mac. L’index des conversations IA, le Temps d’écran, les sceaux cryptographiques et les reçus sont conservés."
        }
    }
#endif
