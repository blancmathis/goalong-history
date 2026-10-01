// THESIS: Activity turns three evidence streams into one inspectable day, without hiding coverage or becoming a second history vault.
// OWN-WORLD: Goalong's restrained native macOS surfaces, green evidence accent, compact rounded controls, and horizontal data bars.
// STORY: Choose a day, inspect the measured shape of it, then read or regenerate the five-line assessment.
// FIRST VIEWPORT: Day controls lead into the score and five-line report; source-backed statistics follow immediately below.
// FORM: A precisely specified operational dashboard extension inside Goalong's existing visual system; no new identity.

#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct ChatGPTRecapPage: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var recapRuntime: ChatGPTRecapRuntime
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

        init(model: DashboardViewModel) {
            self.model = model
            _recapRuntime = ObservedObject(wrappedValue: ChatGPTRecapRuntime.shared)
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    analysisConsentCard

                    if consents.isEnabled(.chatGPTAnalysis), !isConnected {
                        ChatGPTAccountConnectionCard(runtime: recapRuntime)
                    }

                    reportCard

                    if let proof = recapRuntime.recap?.proof {
                        proofCard(proof, report: recapRuntime.proofReport)
                    }

                    if consents.isEnabled(.chatGPTAnalysis), let overview = recapRuntime.dayOverview {
                        metricsBand(overview)
                        HStack(alignment: .top, spacing: 14) {
                            usagePanel(
                                title: "Applications de l’ordinateur",
                                subtitle: "Activité représentée au premier plan",
                                symbol: "macbook",
                                values: overview.computerApplications,
                                emptyMessage: "Aucune activité d’application disponible."
                            )
                            usagePanel(
                                title: "Apple devices",
                                subtitle: "Les totaux Temps d’écran peuvent se chevaucher entre appareils",
                                symbol: "macbook.and.iphone",
                                values: overview.screenTimeDevices,
                                emptyMessage: "Aucun appareil Temps d’écran disponible."
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        agentCollaborationCard(overview)
                        coverageCard(overview)
                    } else if recapRuntime.isLoadingDayOverview {
                        loadingDataCard
                    } else {
                        emptyDataCard
                    }

                    if consents.isEnabled(.chatGPTAnalysis) {
                        automaticCard
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 60)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                recapRuntime.configure(deviceID: model.deviceID)
                recapRuntime.selectDay(model.selectedDay)
                if consents.isEnabled(.chatGPTAnalysis) {
                    recapRuntime.activate()
                }
            }
            .onChange(of: model.selectedDay) { next in
                recapRuntime.selectDay(next)
            }
            .onChange(of: consents.document) { _ in
                if consents.isEnabled(.chatGPTAnalysis) {
                    recapRuntime.activate()
                } else {
                    recapRuntime.stop()
                }
            }
            .alert(item: $recapRuntime.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        private var analysisConsentCard: some View {
            LHCard {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").foregroundStyle(LHTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Analyse avec ChatGPT").font(.system(size: 14, weight: .semibold))
                        Text("Les données autorisées sont envoyées à ChatGPT, pas au site Goalong.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choisir les données") { model.selectSection(.settings); model.settingsPane = .chatGPT }
                        .buttonStyle(.bordered)
                }
            }
        }

        private func proofCard(
            _ proof: AnalysisProofReference,
            report: AnalysisProofVerificationReport?
        ) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Preuve d’analyse", systemImage: "checkmark.shield")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button {
                            recapRuntime.exportProofPackage()
                        } label: {
                            Label("Exporter la preuve", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Text(String(proof.executionID.prefix(8)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "Chaque vérification est indépendante. Une signature locale ne signifie pas que ChatGPT, Apple ou un serveur de vérification ont signé l’analyse."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        proofPill(
                            "Run signature",
                            state: report?.runSignature ?? proof.localSignatureStatus,
                            positive: (report?.runSignature ?? proof.localSignatureStatus) == "valid"
                        )
                        proofPill(
                            "Engagements des sources",
                            state: report?.sourceCommitments ?? proof.contextStatus,
                            positive: (report?.sourceCommitments ?? proof.contextStatus).contains("valid")
                        )
                        proofPill(
                            "Provider observation",
                            state: report?.providerObservation ?? proof.providerObservationStatus,
                            positive: true
                        )
                        proofPill(
                            "External receipt",
                            state: report?.externalReceipt ?? proof.externalReceiptStatus,
                            positive: (report?.externalReceipt ?? proof.externalReceiptStatus) != "not_present"
                        )
                        proofPill(
                            "App Attest",
                            state: report?.appAttest ?? proof.appAttestStatus,
                            positive: (report?.appAttest ?? proof.appAttestStatus).contains("valid")
                        )
                    }

                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "lock.doc")
                            .foregroundStyle(LHTheme.success)
                        Text(
                            "Consigne : empreinte uniquement · conversations : stockage d’origine uniquement · réponse générée : chiffrée localement 30 jours"
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }

        private func proofPill(_ title: String, state: String, positive: Bool) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(state.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
                    .foregroundStyle(positive ? LHTheme.success : LHTheme.warning)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((positive ? LHTheme.success : LHTheme.warning).opacity(0.08))
            )
        }

        private var header: some View {
            PageHeader(
                eyebrow: "Analyse de la journée",
                title: "Activity",
                subtitle:
                    "Comprendre le déroulé et les résultats d’une journée à partir de l’historique, du Temps d’écran et des conversations IA."
            ) {
                HStack(spacing: 10) {
                    DateSelectionControl(date: recapRuntime.selectedDay, onChange: recapRuntime.selectDay)
                    Button {
                        recapRuntime.revealRecapFiles()
                    } label: {
                        Label("Fichiers de rapport", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .help(
                        recapRuntime.recap?.verifiesLocalAttestation == true
                            ? "Partagez le fichier JSON pour conserver sa signature. Le destinataire peut le vérifier hors ligne avec : goalong verify-recap CHEMIN"
                            : "Ouvrir les fichiers de rapport. Les anciens rapports n’ont pas de signature locale."
                    )
                    Button {
                        recapRuntime.generateRecap()
                    } label: {
                        Label(
                            recapRuntime.isGenerating ? "Analyzing…" : generationButtonTitle,
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .disabled(!canGenerate || recapRuntime.isGenerating)
                }
            }
        }

        private var reportCard: some View {
            LHCard {
                if recapRuntime.isGenerating {
                    HStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.regular)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GPT-5.6 Luna analyse cette journée")
                                .font(.system(size: 14, weight: .semibold))
                            Text(
                                "Raisonnement élevé · fil Codex temporaire et isolé · aucune copie des conversations"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                } else if let recap = recapRuntime.recap,
                    let score = recap.productivityScore,
                    let confidence = recap.confidenceScore,
                    let lines = recap.summaryLines,
                    lines.count == ChatGPTDailyAssessment.requiredSummaryLineCount
                {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("PRODUCTIVITY")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(score)")
                                    .font(.system(size: 46, weight: .bold, design: .rounded))
                                    .foregroundStyle(scoreTint(score))
                                Text("/ 100")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Label("\(confidence)% evidence confidence", systemImage: "checkmark.shield")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(isToday ? "La journée est encore en cours" : "Bilan de la journée terminée")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(isToday ? LHTheme.warning : LHTheme.success)
                        }
                        .frame(width: 168, alignment: .leading)

                        Divider()

                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Text("Five-line daily report")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                if recap.verifiesLocalAttestation {
                                    StatusPill(
                                        title: "Signé localement",
                                        symbol: "signature",
                                        tint: LHTheme.success
                                    )
                                    .help(
                                        "Le résultat, l’empreinte de la consigne, le décompte des sources, le modèle déclaré et le contexte correspondent à une signature de ce Mac. Ce n’est pas une preuve du fournisseur ni d’App Attest."
                                    )
                                } else {
                                    StatusPill(
                                        title: "Legacy unsigned",
                                        symbol: "clock.arrow.circlepath",
                                        tint: LHTheme.warning
                                    )
                                    .help("Ce rapport est antérieur aux analyses signées. Régénérez-le pour détecter toute modification.")
                                }
                                Text(recap.generatedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(GoalongUIFormat.locale)))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(LHTheme.accent)
                                        .frame(width: 16)
                                    Text(line)
                                        .font(.system(size: 11))
                                        .lineSpacing(2)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                } else if let recap = recapRuntime.recap {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Legacy daily recap")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "Ce rapport est antérieur au format en cinq lignes. Régénérez-le pour obtenir un score, un niveau de confiance et un résumé structuré."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        Text(.init(recap.markdown))
                            .font(.system(size: 11))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(LHTheme.accent.opacity(0.78))
                        Text("Aucun rapport pour ce jour")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            isConnected
                                ? "Générez-le maintenant, ou laissez l’analyse automatique des journées terminées."
                                : "Connectez ChatGPT dans les réglages pour générer le bilan en cinq lignes."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                }
            }
        }

        private func metricsBand(_ overview: ChatGPTRecapDayOverview) -> some View {
            LHCard {
                HStack(spacing: 0) {
                    metric(
                        title: "Activité de l’ordinateur",
                        value: duration(overview.activeSeconds),
                        detail: "\(overview.focusBlockCount) bloc\(overview.focusBlockCount > 1 ? "s" : "") de concentration"
                    )
                    bandDivider
                    metric(
                        title: "Classé travail",
                        value: duration(overview.workSeconds),
                        detail: "Classement observable"
                    )
                    bandDivider
                    metric(
                        title: "Temps d’écran",
                        value: duration(overview.screenTimeSeconds),
                        detail: "\(overview.screenTimeDevices.count) appareil\(overview.screenTimeDevices.count > 1 ? "s" : "") Apple"
                    )
                    bandDivider
                    metric(
                        title: "Conversations IA",
                        value: "\(overview.agentSessions)",
                        detail: "\(overview.agentMessages) messages"
                    )
                }
            }
        }

        private var bandDivider: some View {
            Divider().frame(height: 48)
        }

        private func metric(title: String, value: String, detail: String) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
        }

        private func usagePanel(
            title: String,
            subtitle: String,
            symbol: String,
            values: [ChatGPTRecapDayOverview.Usage],
            emptyMessage: String
        ) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    if values.isEmpty {
                        Text(emptyMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 138, alignment: .center)
                    } else {
                        let maximum = max(values.map(\.seconds).max() ?? 1, 1)
                        VStack(spacing: 11) {
                            ForEach(values.prefix(8)) { item in
                                usageBar(item, maximum: maximum)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }

        private func usageBar(_ item: ChatGPTRecapDayOverview.Usage, maximum: Int) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    if let detail = item.detail, detail != item.name {
                        Text(detail)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(duration(item.seconds))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(LHTheme.accent.opacity(0.72))
                            .frame(
                                width: max(
                                    3,
                                    proxy.size.width * CGFloat(item.seconds) / CGFloat(maximum)
                                )
                            )
                    }
                }
                .frame(height: 6)
                .accessibilityLabel("\(item.name), \(duration(item.seconds))")
            }
        }

        private func agentCollaborationCard(_ overview: ChatGPTRecapDayOverview) -> some View {
            LHCard {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("AI collaboration", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "Les conversations sont lues ponctuellement dans Codex, Claude, OpenCode et les sources configurées. Seul le rapport en cinq lignes est conservé."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 18)
                    collaborationMetric("Sessions", overview.agentSessions)
                    collaborationMetric("Messages", overview.agentMessages)
                    collaborationMetric("Tool calls", overview.agentToolCalls)
                    collaborationMetric("Erreurs", overview.agentErrors)
                }
            }
        }

        private func collaborationMetric(_ title: String, _ value: Int) -> some View {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(title)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 54)
        }

        private func coverageCard(_ overview: ChatGPTRecapDayOverview) -> some View {
            LHCard {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(LHTheme.success)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Evidence coverage")
                            .font(.system(size: 11, weight: .semibold))
                        Text(
                            "\(overview.sourceEventCount.formatted()) événements · \(overview.privateMinutes) min privées ou masquées · \(overview.analyzedAgentSessions)/\(overview.agentSessions) sessions IA analysées"
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Des données manquantes baissent la confiance, pas le score")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var automaticCard: some View {
            HStack {
                Text("Fréquence et données : Réglages → Analyse ChatGPT").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Configurer") { model.selectSection(.settings); model.settingsPane = .chatGPT }.buttonStyle(.borderless)
            }
        }

        private var loadingDataCard: some View {
            LHCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Lecture de la journée dans les sources locales…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            }
        }

        private var emptyDataCard: some View {
            LHCard {
                VStack(spacing: 9) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(recapRuntime.dayOverviewError ?? "Aucune activité source pour ce jour.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Relire les sources") {
                        recapRuntime.refreshDayOverview()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
        }

        private var canGenerate: Bool {
            isConnected && recapRuntime.dayOverview?.hasMeaningfulData != false
        }

        private var isConnected: Bool {
            if case .connected = recapRuntime.connectionState { return true }
            return false
        }

        private var generationButtonTitle: String {
            recapRuntime.recap == nil ? "Analyser la journée" : "Analyser à nouveau"
        }

        private var isToday: Bool {
            Calendar.current.isDateInToday(recapRuntime.selectedDay)
        }

        private func scoreTint(_ score: Int) -> Color {
            if score >= 75 { return LHTheme.success }
            if score >= 50 { return LHTheme.accent }
            return LHTheme.warning
        }

        private func duration(_ seconds: Int) -> String {
            let safe = max(0, seconds)
            let hours = safe / 3_600
            let minutes = (safe % 3_600) / 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m"
        }
    }
#endif
