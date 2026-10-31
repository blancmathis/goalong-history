#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct SharePage: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

        private var proof: ShareProofStatus {
            ShareProofStatus.make(observedMinutes: model.snapshot.activeMinutes,
                                  sealedMinutes: model.snapshot.sealedMinutes,
                                  recordingEnabled: consents.isEnabled(.localComputerHistory))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "Partager",
                    subtitle:
                        "Choisissez ce que le fichier montre de chaque app et site. Goalong vérifie les signatures de l’historique avant de créer le fichier."
                ) {
                    HStack(spacing: 10) {
                        DateSelectionControl(date: model.selectedDay, onChange: model.selectDay)
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
                ruleSummary

                UsageRulesList(model: model, showsDefaultRule: true,
                               recordingEnabled: consents.isEnabled(.localComputerHistory))
                    .frame(maxHeight: .infinity)

                exportBar
            }
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .background(LHTheme.pageBackground)
        }

        private var disclosureBanner: some View {
            GoalongBanner(symbol: "lock.shield", title: "Vos règles valent pour les prochains partages",
                          detail: "La règle d’un site prime sur celle du navigateur. « Afficher le nom » ne révèle que le nom du site, pas le titre de la page ni l’adresse complète.") {
                StatusPill(title: "Enregistré sur ce Mac", symbol: "internaldrive", tint: LHTheme.secondaryText)
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
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ShareProofStatus.proofSummary(observedMinutes: model.snapshot.activeMinutes,
                                                       sealedMinutes: model.snapshot.sealedMinutes))
                        .font(.system(size: 12, weight: .semibold))
                    Text("Les règles s’appliquent événement par événement")
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                }
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
                switch proof.action {
                case .openRecordingSettings?:
                    Button("Ouvrir les réglages") { model.openRecordingSettings() }
                        .buttonStyle(LHSecondaryButtonStyle())
                case .reportProblem?:
                    Button("Signaler le problème…") { model.openDiagnostics() }
                        .buttonStyle(LHSecondaryButtonStyle())
                case nil:
                    EmptyView()
                }
                Button {
                    model.exportSharePackage()
                } label: {
                    Label("Créer le fichier", systemImage: "square.and.arrow.up")
                        .frame(minWidth: 176)
                }
                .buttonStyle(LHPrimaryButtonStyle())
                .disabled(!proof.canExport || model.isExportingShare)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
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
                return ShareProofStatus(
                    title: "Prêt à créer un fichier selon vos règles",
                    detail: "Les vérifications se font sur ce Mac, sans connexion. Rien n’est envoyé.",
                    action: nil, canExport: true)
            }
            if observedMinutes == 0 {
                return recordingEnabled
                    ? ShareProofStatus(
                        title: "Aucune donnée avec preuve pour ce jour",
                        detail: "Aucune activité observée ce jour-là. Choisissez un autre jour.",
                        action: nil, canExport: false)
                    : ShareProofStatus(
                        title: "Aucune donnée avec preuve pour ce jour",
                        detail: "L’enregistrement est désactivé : Goalong n’observe ni ne signe aucune minute.",
                        action: .openRecordingSettings, canExport: false)
            }
            let observed = FrenchCount.count(observedMinutes, "minute observée", "minutes observées")
            return ShareProofStatus(
                title: "\(observed), aucune avec preuve",
                detail: recordingEnabled
                    ? "Seules les minutes signées par ce Mac pendant l’enregistrement entrent dans le fichier. Celles-ci n’ont pas de signature."
                    : "Seules les minutes signées par ce Mac pendant l’enregistrement entrent dans le fichier. L’enregistrement est désactivé.",
                action: recordingEnabled ? .reportProblem : .openRecordingSettings,
                canExport: false)
        }

        /// « 0 minute avec preuve sur 16 observées »: the proof count next to what the list shows.
        static func proofSummary(observedMinutes: Int, sealedMinutes: Int) -> String {
            let sealed = FrenchCount.count(sealedMinutes, "minute", "minutes") + " avec preuve"
            guard observedMinutes > 0 else { return sealed }
            return sealed + " sur \(observedMinutes) " + FrenchCount.word(observedMinutes, "observée", "observées")
        }
    }
#endif
