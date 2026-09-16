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
                Text("Find your way back to what you were doing.")
                    .font(.system(size: 28, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Bring together your activity, screen time and local AI conversations. Choose the sources you want; you can add the rest later.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LHCard {
                    VStack(alignment: .leading, spacing: 16) {
                        introduction("Local first. Sharing is a separate choice", symbol: "internaldrive",
                            detail: "Recording stays on your Mac. ChatGPT analysis and sharing to the Goalong website require separate choices. You can use the app without either.")
                        Divider()
                        introduction("Only the access you need", symbol: "hand.raised",
                            detail: "Goalong checks existing permissions first. If a source needs access, you will see why and how to grant it.")
                        Divider()
                        introduction("No screenshots or keystroke decoding", symbol: "lock",
                            detail: "Computer History uses foreground context and activity counts. Optional visible-text capture has its own consent. Detected private windows are excluded by default.")
                    }
                }
            }
        }

        var privacyPage: some View {
            VStack(alignment: .leading, spacing: 22) {
                Text("Votre activité, sur votre Mac").font(.system(size: 27, weight: .semibold))
                Text("Tout est proposé. Désactivez ce que vous ne souhaitez pas conserver.").font(.system(size: 14)).foregroundStyle(.secondary)
                LHCard {
                    VStack(spacing: 16) {
                        Toggle("Enregistrer l’activité de ce Mac", isOn: $localRecordingDraft)
                            .toggleStyle(.switch).font(.system(size: 15, weight: .semibold))
                            .accessibilityIdentifier("onboarding-record-local")
                        Divider()
                        GoalongVisibleTextChoice(enabled: $visibleTextDraft)
                        Divider()
                        RecordingChoicesView(draft: $model.settingsDraft)
                    }
                }
                Text(localRecordingDraft ? "Valider démarre le suivi local avec ces choix, après les accès macOS nécessaires. Aucun envoi." : "Le suivi ne démarrera pas. Vos choix restent modifiables.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                DisclosureGroup("Choisir des exclusions avant de commencer") {
                    GoalongOnboardingExclusions(model: model).padding(.top, 12)
                }.font(.system(size: 13))
                if let note { Text(note).font(.system(size: 13)).foregroundStyle(LHTheme.warning) }
            }
        }

        private func scopeInput(_ title: String, text: Binding<String>, applications: Bool = false) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                    .frame(height: 80).padding(6).background(Color.primary.opacity(0.035))
                    .accessibilityLabel(title)
                if applications { ApplicationScopePickerButton(text: text) }
            }
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
