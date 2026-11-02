#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct SharePage: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject var consents = GoalongCapabilityConsentStore.shared

        /// VoiceOver says which settings open; it starts with the visible « Ouvrir ».
        static let openRecordingSettingsAccessibilityLabel = "Ouvrir les réglages d’enregistrement"

        private var proof: ShareProofStatus {
            ShareProofStatus.make(observedMinutes: model.snapshot.activeMinutes,
                                  sealedMinutes: model.snapshot.sealedMinutes,
                                  recordingEnabled: consents.isEnabled(.localComputerHistory))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(
                    title: "Partager",
                    subtitle:
                        "Choisissez ce que le fichier montre de chaque app et site."
                ) {
                    HStack(spacing: 10) {
                        // R-87 (R9C-50): the pill never says « Enregistré » while recording is off.
                        if consents.isEnabled(.localComputerHistory) {
                            StatusPill(title: "Enregistré sur ce Mac", symbol: "internaldrive", tint: LHTheme.secondaryText)
                                .padding(.trailing, 6)
                        }
                        DateSelectionControl(date: model.selectedDay, onChange: model.selectDay,
                                             earliest: model.snapshot.availableDays.min())
                        Button {
                            model.refreshEverything()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .disabled(model.isRefreshing)
                        .help("Actualiser")
                        .accessibilityLabel("Actualiser")
                    }
                }

                disclosureBanner

                UsageRulesList(model: model, showsDefaultRule: true,
                               recordingEnabled: consents.isEnabled(.localComputerHistory))
                    .frame(maxHeight: .infinity)
                    // R8-2: a soft fade says the list goes on under the export bar.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [LHTheme.cardBackground.opacity(0), LHTheme.cardBackground],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 44)
                            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13, style: .continuous))
                            .allowsHitTesting(false)
                    }

                exportBar
            }
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.top, 28)
            .padding(.bottom, 16)
            // Pinned to the top: an empty list never pushes the header (and « Retour ») up (UI-13B).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(LHTheme.pageBackground)
        }

        private var disclosureBanner: some View {
            GoalongBanner(symbol: "lock.shield", title: "Vos règles valent pour les prochains partages",
                          detail: "La règle d’un site prime sur celle du navigateur. « Afficher le nom » ne révèle que le nom du site, pas le titre de la page ni l’adresse complète.") {
                ruleSummary
            }
        }

        private var ruleSummary: some View {
            HStack(spacing: 10) {
                summaryItem(
                    title: "Afficher le nom",
                    count: count(for: .identity),
                    symbol: "eye",
                    tint: LHTheme.success
                )
                summaryItem(
                    title: "Catégorie seulement",
                    count: count(for: .categoryOnly),
                    symbol: "tag",
                    tint: LHTheme.accent
                )
                summaryItem(
                    title: "Masqué",
                    count: count(for: .hidden),
                    symbol: "eye.slash",
                    tint: LHTheme.privateTint
                )
            }
        }

        /// A count, not a filter: plain text with a neutral glyph, no capsule.
        private func summaryItem(title: String, count: Int, symbol: String, tint: Color) -> some View {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(LHTheme.secondaryText)
                Text("\(title) : \(count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .frame(height: 32)
            .accessibilityElement(children: .combine)
        }

        private var exportBar: some View {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(proof.canExport ? LHTheme.success : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proof.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(proof.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("share-proof-status")
                Spacer()
                // « Créer le fichier » is always there and keeps the lime, held back until a minute is
                // verified; reporting the gap is a secondary step (UI-15B, 32/55). With recording off,
                // the settings are the only way forward and take the lime.
                switch proof.action {
                case .openRecordingSettings?:
                    Button(Self.openRecordingSettingsAccessibilityLabel) { model.openRecordingSettings() }
                        .buttonStyle(LHPrimaryButtonStyle())
                        // R-265: VoiceOver says which settings open.
                        .accessibilityLabel(Self.openRecordingSettingsAccessibilityLabel)
                case .reportProblem?:
                    Button("Signaler un problème…") { model.openDiagnostics() }
                        .buttonStyle(LHSecondaryButtonStyle())
                case nil:
                    EmptyView()
                }
                createButton
                    .modifier(GoalongMainActionStyle(primary: proof.action != .openRecordingSettings))
                    .disabled(!proof.canExport || model.isExportingShare)
                    // R-87 (R9C-48): the held-back button says why when hovered, as the line next to it does.
                    .help(proof.canExport ? "" : proof.detail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: UsageRulesList.exportBarHeight)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }

        private var createButton: some View {
            Button {
                model.exportSharePackage()
            } label: {
                Label("Créer le fichier", systemImage: "square.and.arrow.up")
                    .frame(minWidth: 176)
            }
        }

        private func count(for visibility: SharingVisibility) -> Int {
            model.snapshot.trackedUsage.filter {
                model.sharingVisibility(for: $0.id) == visibility
            }.count
        }
    }

    /// What the export bar says about the selected day. Only minutes signed on this Mac while recording
    /// go into the file, so « no proof » always says why and, when the user can change it, what to do.
    struct ShareProofStatus: Equatable {
        enum Action: Equatable {
            case openRecordingSettings
            case reportProblem
        }

        let title: String
        let detail: String
        let action: Action?
        let canExport: Bool

        static func make(observedMinutes: Int, sealedMinutes: Int, recordingEnabled: Bool) -> ShareProofStatus {
            if sealedMinutes > 0 {
                let checked = FrenchCount.count(sealedMinutes, "minute confirmée", "minutes confirmées")
                return ShareProofStatus(
                    title: "Prêt à créer un fichier selon vos règles",
                    detail: "\(checked) sur \(max(observedMinutes, sealedMinutes)). Ce Mac les confirme lui-même, sans connexion. Rien n’est envoyé.",
                    action: nil, canExport: true)
            }
            if observedMinutes == 0 {
                return recordingEnabled
                    ? ShareProofStatus(
                        title: "Aucune activité ce jour",
                        detail: "Rien à mettre dans le fichier. Choisissez un autre jour.",
                        action: nil, canExport: false)
                    : ShareProofStatus(
                        title: "Enregistrement désactivé",
                        detail: "Goalong n’observe aucune minute pour l’instant.",
                        action: .openRecordingSettings, canExport: false)
            }
            // R7 (32/55, UI-17A): plain words, no « signé » or « écart »; the line next to the held-back button says
            // what unblocks it.
            let observed = FrenchCount.count(observedMinutes, "minute", "minutes")
            let pending = FrenchCount.word(observedMinutes, "confirmée", "confirmées")
            return ShareProofStatus(
                title: "\(observed), pas encore \(pending) par ce Mac",
                detail: recordingEnabled
                    ? "Le fichier contiendra seulement les minutes confirmées. Vous pourrez le créer dès la première ; si rien ne change, signalez un problème."
                    : "Le fichier contiendra seulement les minutes confirmées. Activez l’enregistrement : ce Mac confirmera les minutes suivantes.",
                action: recordingEnabled ? .reportProblem : .openRecordingSettings,
                canExport: false)
        }
    }
#endif
