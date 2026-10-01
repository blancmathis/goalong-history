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
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(LHTheme.accent)
                Text("Retrouvez le fil de ce que vous faisiez.")
                    .font(.system(size: 28, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("Voyez où va votre temps").font(.system(size: 27, weight: .semibold))
                Text("Goalong observe l’app au premier plan et calcule, sur ce Mac, ce qui compte pour avancer.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { benefits }
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
                                .labelsHidden().toggleStyle(.switch)
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
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                GoalongDisclosureGroup("Choisir des exclusions avant de commencer") {
                    GoalongOnboardingExclusions(model: model).padding(.top, 12)
                }.font(.system(size: 13))
                if let note { Text(note).font(.system(size: 13)).foregroundStyle(LHTheme.warning) }
            }
        }

        @ViewBuilder private var benefits: some View {
            benefit("Temps actif", symbol: "clock", detail: "Heure par heure, jour après jour")
            benefit("Travail et concentration", symbol: "briefcase", detail: "Vos blocs de travail et vos interruptions")
            benefit("Apps et sites", symbol: "square.grid.2x2", detail: "Ce qui prend réellement votre temps")
        }

        private func benefit(_ title: String, symbol: String, detail: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LHTheme.accent).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }

        var sourcesPage: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choisissez vos sources")
                    .font(.system(size: 22, weight: .semibold))
                Text("Activez seulement ce qui vous intéresse. Les accès macOS nécessaires sont guidés.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                sourceChoice(.localComputerHistory, symbol: "macwindow",
                    detail: "Applications et durées, avec les détails que vous avez choisis.")
                sourceChoice(.appleScreenTime, symbol: "macbook.and.iphone",
                    detail: "Usage de vos appareils Apple · facultatif.")
                sourceChoice(.aiConversations, symbol: "bubble.left.and.bubble.right",
                    detail: "Conversations enregistrées par vos outils IA · facultatif.")
                Text("Tout peut être modifié plus tard dans les réglages.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        func sourceChoice(_ capability: GoalongCapability, symbol: String, detail: String,
                          prepare: @escaping () throws -> Void = {}) -> some View {
            LHCard {
                SourceActivationToggle(capability: capability, surface: .onboarding, prepare: prepare,
                    onCheckingChanged: { checking in
                        if checking { checkingSources.insert(capability) }
                        else { checkingSources.remove(capability) }
                    }) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: symbol).font(.system(size: 20))
                            .foregroundStyle(LHTheme.accent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(capability.title).font(.system(size: 14, weight: .semibold))
                            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(minHeight: 54, alignment: .leading)
                }
            }
        }

        var readyPage: some View {
            VStack(alignment: .leading, spacing: 24) {
                Text("Vous pouvez commencer").font(.system(size: 27, weight: .semibold))
                LHCard {
                    VStack(spacing: 16) {
                        ForEach([GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations]) { capability in
                            HStack {
                                Text(capability.title).font(.system(size: 14))
                                Spacer()
                                Label(consents.isEnabled(capability) ? "Activée" : "Plus tard", systemImage: consents.isEnabled(capability) ? "checkmark.circle" : "minus.circle")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Le nouvel historique apparaîtra avec votre activité.").font(.system(size: 13)).foregroundStyle(.secondary)
                Toggle("Ouvrir Goalong à la connexion", isOn: $launchAtLoginPreference).toggleStyle(.switch)
                Text("Conseillé et sélectionné par défaut. Vous pouvez le désactiver ici ou dans Réglages. Seules les sources que vous avez activées démarrent.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Les envois à Goalong et les analyses ChatGPT se règlent séparément.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let note { Text(note).font(.system(size: 13)).foregroundStyle(LHTheme.warning) }
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
#endif
