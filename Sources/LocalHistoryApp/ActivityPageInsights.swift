#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    extension ActivityPage {
        func sitesCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionTitle(
                            title: "Sites, pages et actions",
                            subtitle: "L’activité web est attribuée au site, quel que soit le navigateur"
                        )
                        Spacer()
                        Button("Voir tous les sites") {
                            mode = .appsAndSites
                        }
                        .buttonStyle(LHQuietButtonStyle())
                        .font(.system(size: 11, weight: .semibold))
                    }

                    if analysis.sites.isEmpty {
                        compactEmpty(
                            symbol: "globe",
                            title: "Aucune adresse de site n’a été fournie par la page active"
                        )
                    } else {
                        VStack(spacing: 11) {
                            ForEach(Array(analysis.sites.prefix(10))) { site in
                                recapSiteRow(site)
                                if site.id != analysis.sites.prefix(10).last?.id { Divider() }
                            }
                        }

                        if analysis.sites.count > 10 {
                            Button {
                                mode = .appsAndSites
                            } label: {
                                Label(
                                    "Voir les \(analysis.sites.count) sites et leurs pages",
                                    systemImage: "arrow.right.circle"
                                )
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LHTheme.accent)
                        }
                    }
                }
            }
        }

        func recapSiteRow(_ site: ActivitySiteSummary) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(site.host)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(duration(site.activeSeconds))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    Label("\(site.pageCount) page\(site.pageCount == 1 ? "" : "s")", systemImage: "doc.on.doc")
                    Label("\(site.clickCount) click\(site.clickCount == 1 ? "" : "s")", systemImage: "cursorarrow.click")
                    if site.typingBurstCount > 0 {
                        Label("\(site.typingBurstCount) typing", systemImage: "keyboard")
                    }
                    if site.semanticSnapshotCount > 0 {
                        Label("\(site.semanticSnapshotCount) memories", systemImage: "brain.head.profile")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

                if let page = site.pages.first {
                    Text(page.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                let clicks = site.interactions.filter { $0.kind == .click }
                if !clicks.isEmpty {
                    HStack(spacing: 5) {
                        Text("Clicked:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(
                            clicks.prefix(2).map {
                                $0.count > 1 ? "\($0.label) ×\($0.count)" : $0.label
                            }.joined(separator: " · ")
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                }

                if let remembered = site.rememberedContext.first {
                    Text(remembered)
                        .font(.system(size: 11))
                        .foregroundStyle(LHTheme.privateTint)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }

        func requestsCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    SectionTitle(
                        title: "Demandes et intentions",
                        subtitle: "Demandes probables repérées dans le texte affiché (si activé)"
                    )
                    if analysis.requests.isEmpty {
                        compactEmpty(
                            symbol: "text.bubble",
                            title: richContextEnabled
                                ? "Aucune demande claire repérée"
                                : "Texte affiché désactivé"
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(analysis.requests.prefix(6)) { request in
                                HStack(alignment: .top, spacing: 9) {
                                    Text(DashboardFormatters.shortTime.string(from: request.firstSeen))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 34, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(request.text)
                                            .font(.system(size: 11, weight: .medium))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                        Text(request.host ?? request.application ?? "Contexte accessible")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func agentBriefCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LHTheme.success)
                            .frame(width: 40, height: 40)
                            .background(
                                LHTheme.success.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Agent-ready daily brief")
                                .font(.system(size: 15, weight: .semibold))
                            Text(
                                "Markdown stable avec les sites, pages et actions significatives, dédoublonnés dans une taille limitée."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("~\(analysis.estimatedAgentTokens.formatted()) tokens")
                                .font(.system(size: 12, weight: .bold))
                            Text("budget \(agentTokenBudget.formatted())")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        Picker("Budget de jetons", selection: $agentTokenBudget) {
                            Text("Compact · 800").tag(800)
                            Text("Balanced · 1,600").tag(1_600)
                            Text("Detailed · 3,000").tag(3_000)
                            Text("Maximum · 6,000").tag(6_000)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 190)

                        Button("Ouvrir le Markdown") {
                            analysisModel.openAgentBrief(for: model.selectedDay)
                        }
                        .buttonStyle(LHPrimaryButtonStyle())

                        Button("Afficher les fichiers") {
                            analysisModel.revealAnalysisFiles(for: model.selectedDay)
                        }
                        .buttonStyle(LHSecondaryButtonStyle())

                        Spacer()
                        Text("analysis/*.agent.md + *.analysis.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    ScrollView(.vertical) {
                        Text(analysis.agentMarkdown)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(13)
                    }
                    .frame(minHeight: 150, maxHeight: 250)
                    .background(
                        Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                }
            }
        }

        func richContextCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(richContextEnabled ? LHTheme.privateTint : Color.secondary)
                        .frame(width: 42, height: 42)
                        .background(
                            (richContextEnabled ? LHTheme.privateTint : Color.secondary).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text("Rich Context")
                                .font(.system(size: 14, weight: .semibold))
                            StatusPill(
                                title: richContextEnabled ? "Activé" : "Désactivé par défaut",
                                symbol: richContextEnabled ? "checkmark.circle.fill" : "circle",
                                tint: richContextEnabled ? LHTheme.privateTint : Color.secondary
                            )
                        }
                        Text(
                            "Mémorise le texte sélectionné et visible fourni par l’accessibilité macOS, y compris les discussions web, pour que le récapitulatif comprenne plus qu’une adresse ou un titre."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Label("Aucun caractère tapé n’est décodé", systemImage: "keyboard.badge.ellipsis")
                            Label("Sites privés et exclus masqués", systemImage: "eye.slash.fill")
                            Label("Identifiants courants masqués", systemImage: "key.slash.fill")
                            Label("Stocké sur ce Mac et scellé", systemImage: "checkmark.seal.fill")
                            if analysis.coverage.semanticSnapshotCount > 0 {
                                Label(
                                    "\(analysis.coverage.semanticSnapshotCount) instantanés aujourd’hui",
                                    systemImage: "text.badge.checkmark"
                                )
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 18)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { richContextEnabled },
                            set: { enabled in
                                if enabled {
                                    showRichContextConfirmation = true
                                } else {
                                    richContextEnabled = false
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.goalongSwitchOnly)
                    .help("Activer le contexte facultatif du texte affiché")
                }
            }
        }
    }
#endif
