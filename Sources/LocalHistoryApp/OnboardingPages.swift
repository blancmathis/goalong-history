#if os(macOS)
    import SwiftUI

    extension LocalHistoryOnboardingView {
        @ViewBuilder var page: some View {
            switch step {
            case .welcome: welcomePage
            case .privacy: privacyPage
            case .sources: sourcesPage
            case .ready: readyPage
            }
        }

        var welcomePage: some View {
            VStack(alignment: .leading, spacing: 24) {
                Text("Retrouvez le fil de ce que vous faisiez.").goalongPageTitle()
                Text("Réunissez votre activité, votre temps d’écran et vos conversations IA locales. Choisissez vos sources ; vous pourrez ajouter les autres plus tard.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LHCard {
                    VStack(alignment: .leading, spacing: 16) {
                        introduction("Local d’abord. Le partage est un choix séparé", symbol: "internaldrive",
                            detail: "L’enregistrement reste sur votre Mac. L’analyse ChatGPT et l’envoi au site Goalong sont des choix séparés ; l’app fonctionne sans eux.")
                        Divider()
                        introduction("Seulement les accès nécessaires", symbol: "hand.raised",
                            detail: "Goalong vérifie d’abord les autorisations existantes. Si une source a besoin d’un accès, vous verrez pourquoi et comment l’accorder.")
                        Divider()
                        introduction("Ni captures d’écran, ni touches reconstituées", symbol: "lock",
                            detail: "L’historique utilise l’app au premier plan et des compteurs d’activité. La lecture du texte affiché, facultative, a son propre accord. Les fenêtres privées détectées sont exclues par défaut.")
                    }
                }
            }
        }

        var privacyPage: some View {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voyez où va votre temps").goalongPageTitle()
                    Text("Goalong observe l’app au premier plan et retrace, sur ce Mac, le fil de votre journée.")
                        .font(.system(size: 14)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GoalongOnboardingThread()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { benefits }
                    VStack(alignment: .leading, spacing: 10) { benefits }
                }
                LHCard {
                    VStack(spacing: 16) {
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enregistrer l’activité de ce Mac").font(.system(size: 15, weight: .semibold))
                                Text("Tout reste sur ce Mac. Aucun envoi, aucune capture d’écran, aucun texte tapé.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Toggle("Enregistrer l’activité de ce Mac", isOn: $localRecordingDraft)
                                .labelsHidden().toggleStyle(.goalongSwitchOnly)
                                .accessibilityIdentifier("onboarding-record-local")
                        }
                        Divider()
                        HStack {
                            Text("Détails enregistrés · tous proposés, modifiables à tout moment")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        GoalongVisibleTextChoice(enabled: $visibleTextDraft)
                        Divider()
                        RecordingChoicesView(draft: $model.settingsDraft)
                    }
                }
                Text(localRecordingDraft ? "Valider démarre le suivi local avec ces choix, après les accès macOS nécessaires. Aucun envoi." : "Le suivi ne démarrera pas. Vos choix restent modifiables.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                GoalongDisclosureGroup("Choisir des exclusions avant de commencer") {
                    GoalongOnboardingExclusions(model: model).padding(.top, 12)
                }.font(.system(size: 13))
                if let note { GoalongNote(note, tone: .warning) }
            }
        }

        @ViewBuilder private var benefits: some View {
            benefit("Temps actif", detail: "Heure par heure, jour après jour")
            benefit("Travail et concentration", detail: "Selon votre propre définition du travail")
            benefit("Apps et sites", detail: "Ce qui prend réellement votre temps")
        }

        private func benefit(_ title: String, detail: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }

        var sourcesPage: some View {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choisissez vos sources").goalongPageTitle()
                    Text("Activez seulement ce qui vous intéresse. Les accès macOS nécessaires sont guidés.")
                        .font(.system(size: 14)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.bottom, 6)
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        sourceChoice(.localComputerHistory, symbol: "macwindow",
                            detail: "Applications et durées, avec les détails que vous avez choisis.")
                        GoalongRowDivider()
                        sourceChoice(.appleScreenTime, symbol: "macbook.and.iphone",
                            detail: "Facultatif. Usage de vos appareils Apple.")
                        GoalongRowDivider()
                        sourceChoice(.aiConversations, symbol: "bubble.left.and.bubble.right",
                            detail: "Facultatif. Conversations enregistrées par vos outils IA.")
                    }
                }
            }
        }

        func sourceChoice(_ capability: GoalongCapability, symbol: String, detail: String,
                          prepare: @escaping () throws -> Void = {}) -> some View {
            Group {
                SourceActivationToggle(capability: capability, surface: .onboarding, prepare: prepare,
                    onCheckingChanged: { checking in
                        if checking { checkingSources.insert(capability) }
                        else { checkingSources.remove(capability) }
                    }) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LHTheme.secondaryText).frame(width: 22).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capability.title).font(.system(size: 13, weight: .semibold))
                            Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(minHeight: 40, alignment: .leading)
                }
            }
            .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 12)
        }

        var readyPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vous pouvez commencer").goalongPageTitle()
                    Text(consents.isEnabled(.localComputerHistory)
                         ? "Votre fil apparaîtra dans Activité dès les premières minutes d’utilisation de ce Mac."
                         : "L’enregistrement local est désactivé : Activité restera vide. Vous pourrez l’activer dans Réglages, Enregistrement local.")
                        .font(.system(size: 14)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LHCard {
                    VStack(spacing: 14) {
                        ForEach([GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations]) { capability in
                            HStack {
                                Text(capability.title).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Label(consents.isEnabled(capability) ? "Activée" : "Plus tard", systemImage: consents.isEnabled(capability) ? "checkmark" : "minus")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(consents.isEnabled(capability) ? LHTheme.success : LHTheme.secondaryText)
                            }
                        }
                    }
                }
                LHCard {
                    Toggle(isOn: $launchAtLoginPreference) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ouvrir Goalong à la connexion").font(.system(size: 13, weight: .medium))
                            Text("Conseillé et sélectionné par défaut. Seules les sources que vous avez activées démarrent.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.goalongSwitch)
                }
                Text("Les envois à Goalong et les analyses ChatGPT se règlent séparément, dans Réglages.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                if let note { GoalongNote(note, tone: .warning) }
                if launchAtLoginPreference && launchAtLogin.requiresApproval {
                    Button("Ouvrir les éléments de connexion") { launchAtLogin.openLoginItemsSettings() }
                }
            }
        }

        func introduction(_ title: String, symbol: String, detail: String) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What the app will draw once it records: a sample day as a thread, traced once.
    struct GoalongOnboardingThread: View {
        @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
        @Environment(\.goalongReduceMotion) private var localReduceMotion
        @State private var traced: CGFloat = 0
        /// Start, end (as fractions of the day shown) and class of each stretch.
        private let stretches: [(CGFloat, CGFloat, Color)] = [
            (0.02, 0.19, LHTheme.workData), (0.22, 0.30, LHTheme.workData), (0.33, 0.41, LHTheme.otherData),
            (0.52, 0.71, LHTheme.workData), (0.73, 0.79, LHTheme.unclassifiedData), (0.81, 0.93, LHTheme.workData),
        ]

        var body: some View {
            let still = systemReduceMotion || localReduceMotion
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(LHTheme.tertiaryText.opacity(0.5)).frame(height: 1)
                        ZStack(alignment: .leading) {
                            ForEach(stretches.indices, id: \.self) { index in
                                let stretch = stretches[index]
                                RoundedRectangle(cornerRadius: LHTheme.markRadius, style: .continuous).fill(stretch.2)
                                    .frame(width: (stretch.1 - stretch.0) * geometry.size.width, height: 14)
                                    .offset(x: stretch.0 * geometry.size.width)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask(alignment: .leading) { Rectangle().scaleEffect(x: still ? 1 : traced, anchor: .leading) }
                    }
                    .frame(height: 14)
                }
                .frame(height: 14)
                GoalongActivityClassLegend()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Exemple : une journée dessinée comme un fil, en trois couleurs : travail, hors travail, à classer")
            .onAppear {
                guard traced == 0, !still else { traced = 1; return }
                withAnimation(LHTheme.draw.delay(0.2)) { traced = 1 }
            }
        }
    }
#endif
