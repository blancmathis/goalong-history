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

        /// `runtime` is the app's own; the gallery passes one with its sources replaced.
        init(model: DashboardViewModel, runtime: ChatGPTRecapRuntime = .shared) {
            self.model = model
            _recapRuntime = ObservedObject(wrappedValue: runtime)
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    // One ChatGPT card, one action: the connection card replaces the data card until connected.
                    if consents.isEnabled(.chatGPTAnalysis), !isConnected {
                        ChatGPTAccountConnectionCard(runtime: recapRuntime)
                    } else {
                        analysisConsentCard
                    }

                    if recapRuntime.isGenerating, !recapRuntime.isGeneratingSelectedDay,
                        let generatingDay = recapRuntime.generatingDay
                    {
                        Text("Analyse du \(GoalongUIFormat.day(generatingDay)) en cours")
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
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
                                title: "Appareils Apple",
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

                    if consents.isEnabled(.chatGPTAnalysis), isConnected {
                        automaticCard
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 60)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                recapRuntime.configure(deviceID: model.knownDeviceID ?? "")
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
            GoalongPlainBlock {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").foregroundStyle(LHTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Analyse avec ChatGPT").font(.system(size: 14, weight: .semibold))
                        Text("Les données autorisées sont envoyées à ChatGPT, pas au site Goalong.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    Spacer()
                    Button("Choisir les données") { model.selectSection(.settings); model.settingsPane = .chatGPT }
                        .buttonStyle(LHSecondaryButtonStyle())
                }
            }
        }

        private func proofCard(
            _ proof: AnalysisProofReference,
            report: AnalysisProofVerificationReport?
        ) -> some View {
            GoalongPlainBlock {
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
                        .buttonStyle(LHSecondaryButtonStyle())
                        .controlSize(.small)
                        Text(String(proof.executionID.prefix(8)))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(LHTheme.secondaryText)
                    }
                    Text(
                        "Chaque vérification est indépendante. Une signature locale ne signifie pas que ChatGPT, Apple ou un serveur de vérification ont signé l’analyse."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)

                    HStack(spacing: 8) {
                        proofPill(
                            "Signature du rapport",
                            state: report?.runSignature ?? proof.localSignatureStatus,
                            positive: (report?.runSignature ?? proof.localSignatureStatus) == "valid"
                        )
                        proofPill(
                            "Engagements des sources",
                            state: report?.sourceCommitments ?? proof.contextStatus,
                            positive: (report?.sourceCommitments ?? proof.contextStatus).contains("valid")
                        )
                        proofPill(
                            "Observation du fournisseur",
                            state: report?.providerObservation ?? proof.providerObservationStatus,
                            positive: true
                        )
                        proofPill(
                            "Reçu externe",
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
                            "Consigne : empreinte uniquement · conversations : stockage d’origine uniquement · bilan en cinq lignes : gardé sur ce Mac sans chiffrement, effacé avec l’historique détaillé du jour · réponse complète : copie chiffrée gardée 30 jours"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LHTheme.secondaryText)
                        Spacer()
                    }
                }
            }
        }

        private func proofPill(_ title: String, state: String, positive: Bool) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LHTheme.secondaryText)
                Text(state.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 12, weight: .bold))
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

        /// The page's date picker writes the dashboard day and the Bilan day together.
        @MainActor static func chooseDay(_ day: Date, model: DashboardViewModel, runtime: ChatGPTRecapRuntime) {
            model.selectDay(day)
            runtime.selectDay(day)
        }

        private var header: some View {
            PageHeader(
                title: "Bilan quotidien",
                subtitle:
                    "Comprendre le déroulé et les résultats d’une journée à partir de l’historique, du Temps d’écran et des conversations IA."
            ) {
                HStack(spacing: 10) {
                    // The dashboard day is the page's day (T-045 H1-01): Historique and a return here keep the choice.
                    DateSelectionControl(date: recapRuntime.selectedDay, onChange: { day in
                        Self.chooseDay(day, model: model, runtime: recapRuntime)
                    })
                    Button {
                        recapRuntime.revealRecapFiles()
                    } label: {
                        Label("Fichiers de rapport", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                    .help(
                        recapRuntime.recap?.verifiesLocalAttestation == true
                            ? "Partagez le fichier JSON pour conserver sa signature. Le destinataire peut le vérifier hors ligne avec : goalong verify-recap CHEMIN"
                            : "Ouvrir les fichiers de rapport. Les anciens rapports n’ont pas de signature locale."
                    )
                    Button {
                        recapRuntime.generateRecap()
                    } label: {
                        Label(
                            recapRuntime.isGeneratingSelectedDay ? "Analyse en cours…" : generationButtonTitle,
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .disabled(!canGenerate || recapRuntime.isGenerating)
                    .help(generationBlockedReason ?? "")
                    .accessibilityHint(generationBlockedReason ?? "")
                    .overlay(alignment: .bottomLeading) {
                        // The reason sits under the greyed button without moving the header row.
                        if let reason = generationBlockedReason, !recapRuntime.isGenerating {
                            Text(reason).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .fixedSize().offset(y: 18).accessibilityHidden(true)
                        }
                    }
                }
            }
        }

        private var reportCard: some View {
            GoalongPlainBlock {
                if recapRuntime.isGeneratingSelectedDay {
                    HStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.regular)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GPT-5.6 Luna analyse cette journée")
                                .font(.system(size: 14, weight: .semibold))
                            Text(
                                "Raisonnement élevé · fil Codex temporaire et isolé · aucune copie des conversations"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
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
                            Text("Productivité")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LHTheme.secondaryText)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(score)")
                                    .font(.system(size: 46, weight: .bold))
                                    .foregroundStyle(scoreTint(score))
                                Text("/ 100")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LHTheme.secondaryText)
                            }
                            Label("Confiance des preuves : \(GoalongUIFormat.percent(confidence))", systemImage: "checkmark.shield")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LHTheme.secondaryText)
                            Text(isToday ? "La journée est encore en cours" : "Bilan de la journée terminée")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isToday ? LHTheme.warning : LHTheme.success)
                        }
                        .frame(width: 168, alignment: .leading)

                        Divider()

                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Text("Rapport du jour en cinq lignes")
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
                                        title: "Ancien rapport non signé",
                                        symbol: "clock.arrow.circlepath",
                                        tint: LHTheme.warning
                                    )
                                    .help("Ce rapport est antérieur aux analyses signées. Régénérez-le pour détecter toute modification.")
                                }
                                Text(recap.generatedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(GoalongUIFormat.locale)))
                                    .font(.system(size: 12))
                                    .foregroundStyle(LHTheme.secondaryText)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(LHTheme.accent)
                                        .frame(width: 16)
                                    Text(line)
                                        .font(.system(size: 12))
                                        .lineSpacing(2)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                } else if let recap = recapRuntime.recap {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ancien bilan quotidien")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "Ce rapport est antérieur au format en cinq lignes. Régénérez-le pour obtenir un score, un niveau de confiance et un résumé structuré."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        Text(.init(recap.markdown))
                            .font(.system(size: 12))
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
                        Text(emptyReportMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                }
            }
        }

        private func metricsBand(_ overview: ChatGPTRecapDayOverview) -> some View {
            GoalongPlainBlock {
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
                        detail: GoalongUIFormat.count(overview.agentMessages, "message")
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LHTheme.secondaryText)
                Text(value)
                    .font(.system(size: 18, weight: .bold))
                Text(detail)
                    .font(.system(size: 12))
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
            GoalongPlainBlock {
                VStack(alignment: .leading, spacing: 14) {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                    if values.isEmpty {
                        Text(emptyMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
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
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let detail = item.detail, detail != item.name {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(duration(item.seconds))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LHTheme.secondaryText)
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
            GoalongPlainBlock {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Collaboration avec l’IA", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "Les conversations sont lues ponctuellement dans Codex, Claude, OpenCode et les sources configurées. Seul le rapport en cinq lignes est conservé."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 18)
                    collaborationMetric("Sessions", overview.agentSessions)
                    collaborationMetric("Messages", overview.agentMessages)
                    collaborationMetric("Appels d’outils", overview.agentToolCalls)
                    collaborationMetric("Erreurs", overview.agentErrors)
                }
            }
        }

        private func collaborationMetric(_ title: String, _ value: Int) -> some View {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LHTheme.secondaryText)
            }
            .frame(minWidth: 54)
        }

        private func coverageCard(_ overview: ChatGPTRecapDayOverview) -> some View {
            GoalongPlainBlock {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(LHTheme.success)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Couverture des preuves")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "\(GoalongUIFormat.count(overview.sourceEventCount, "événement")) · \(overview.privateMinutes) min privées ou masquées · \(overview.analyzedAgentSessions)/\(overview.agentSessions) session\(overview.agentSessions > 1 ? "s" : "") IA analysée\(overview.analyzedAgentSessions > 1 ? "s" : "")"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                    }
                    Spacer()
                    Text("Des données manquantes baissent la confiance, pas le score")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LHTheme.secondaryText)
                }
            }
        }

        private var automaticCard: some View {
            HStack {
                Text("Fréquence et données : Réglages → Analyse ChatGPT").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                Spacer()
                Button("Configurer") { model.selectSection(.settings); model.settingsPane = .chatGPT }.buttonStyle(LHQuietButtonStyle())
            }
        }

        private var loadingDataCard: some View {
            GoalongPlainBlock {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Lecture de la journée dans les sources locales…")
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            }
        }

        private var emptyDataCard: some View {
            GoalongPlainBlock {
                VStack(spacing: 9) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 25))
                        .foregroundStyle(LHTheme.secondaryText)
                    Text(recapRuntime.dayOverviewError ?? "Aucune activité source pour ce jour.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LHTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Relire les sources") {
                        recapRuntime.refreshDayOverview()
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
        }

        private var canGenerate: Bool { generationBlockedReason == nil }

        private var isConnected: Bool { recapRuntime.isAccountConnected }

        private var needsUpdate: Bool { recapRuntime.connectionState == .codexUnavailable }

        private var generationBlockedReason: String? {
            Self.generationBlockedReason(analysesEnabled: consents.isEnabled(.chatGPTAnalysis), connected: isConnected,
                                         needsUpdate: needsUpdate, hasMeaningfulData: recapRuntime.dayOverview?.hasMeaningfulData)
        }

        private var emptyReportMessage: String {
            Self.emptyReportMessage(analysesEnabled: consents.isEnabled(.chatGPTAnalysis), connected: isConnected, needsUpdate: needsUpdate)
        }

        /// The button is enabled only when this is nil, so it never contradicts the reason shown below it.
        static func generationBlockedReason(analysesEnabled: Bool, connected: Bool, needsUpdate: Bool, hasMeaningfulData: Bool?) -> String? {
            if !analysesEnabled { return "Activez d’abord l’analyse avec ChatGPT." }
            if !connected { return needsUpdate ? "Mettez d’abord Goalong à jour." : "Connectez d’abord ChatGPT." }
            if hasMeaningfulData == false { return "Aucune activité à analyser ce jour." }
            return nil
        }

        static func emptyReportMessage(analysesEnabled: Bool, connected: Bool, needsUpdate: Bool) -> String {
            if !analysesEnabled {
                return "Les analyses sont désactivées. Activez « Autoriser les analyses » dans Réglages › Analyse ChatGPT pour générer le bilan en cinq lignes."
            }
            if connected { return "Générez-le maintenant, ou laissez l’analyse automatique des journées terminées." }
            return needsUpdate
                ? "Mettez Goalong à jour pour générer le bilan en cinq lignes."
                : "Connectez ChatGPT ci-dessus pour générer le bilan en cinq lignes."
        }

        private var generationButtonTitle: String {
            recapRuntime.recap == nil ? "Analyser la journée" : "Analyser à nouveau"
        }

        private var isToday: Bool {
            GoalongToday.isToday(recapRuntime.selectedDay)
        }

        private func scoreTint(_ score: Int) -> Color {
            if score >= 75 { return LHTheme.success }
            if score >= 50 { return LHTheme.accent }
            return LHTheme.warning
        }

        private func duration(_ seconds: Int) -> String {
            DashboardFormatters.duration(seconds: TimeInterval(seconds))
        }
    }
#endif
