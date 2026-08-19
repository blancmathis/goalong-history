#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    extension ActivityPage {
        func sitesCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionTitle(
                            title: "Websites, pages and actions",
                            subtitle: "Web activity is attributed to the site, independently of the browser used"
                        )
                        Spacer()
                        Button("Open all sites") {
                            mode = .appsAndSites
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10, weight: .semibold))
                    }

                    if analysis.sites.isEmpty {
                        compactEmpty(
                            symbol: "globe",
                            title: "No website URL was exposed by the active web container"
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
                                    "View all \(analysis.sites.count) websites and their pages",
                                    systemImage: "arrow.right.circle"
                                )
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
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
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
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
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)

                if let page = site.pages.first {
                    Text(page.title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                let clicks = site.interactions.filter { $0.kind == .click }
                if !clicks.isEmpty {
                    HStack(spacing: 5) {
                        Text("Clicked:")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(
                            clicks.prefix(2).map {
                                $0.count > 1 ? "\($0.label) ×\($0.count)" : $0.label
                            }.joined(separator: " · ")
                        )
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                }

                if let remembered = site.rememberedContext.first {
                    Text(remembered)
                        .font(.system(size: 8))
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
                        title: "Requests and intentions",
                        subtitle: "Likely user prompts detected in opt-in visible context"
                    )
                    if analysis.requests.isEmpty {
                        compactEmpty(
                            symbol: "text.bubble",
                            title: richContextEnabled
                                ? "No clear request detected yet"
                                : "Rich Context is off"
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(analysis.requests.prefix(6)) { request in
                                HStack(alignment: .top, spacing: 9) {
                                    Text(DashboardFormatters.shortTime.string(from: request.firstSeen))
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 34, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(request.text)
                                            .font(.system(size: 10, weight: .medium))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                        Text(request.host ?? request.application ?? "Accessible context")
                                            .font(.system(size: 8))
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
                                "Stable Markdown with websites, pages and meaningful actions already deduplicated under a hard token budget."
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("~\(analysis.estimatedAgentTokens.formatted()) tokens")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Text("budget \(agentTokenBudget.formatted())")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        Picker("Token budget", selection: $agentTokenBudget) {
                            Text("Compact · 800").tag(800)
                            Text("Balanced · 1,600").tag(1_600)
                            Text("Detailed · 3,000").tag(3_000)
                            Text("Maximum · 6,000").tag(6_000)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 190)

                        Button("Open Markdown") {
                            analysisModel.openAgentBrief(for: model.selectedDay)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reveal files") {
                            analysisModel.revealAnalysisFiles(for: model.selectedDay)
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                        Text("analysis/*.agent.md + *.analysis.json")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    ScrollView(.vertical) {
                        Text(analysis.agentMarkdown)
                            .font(.system(size: 10, design: .monospaced))
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
                                title: richContextEnabled ? "Enabled" : "Off by default",
                                symbol: richContextEnabled ? "checkmark.circle.fill" : "circle",
                                tint: richContextEnabled ? LHTheme.privateTint : Color.secondary
                            )
                        }
                        Text(
                            "Remembers selected and visible text exposed by macOS Accessibility, including accessible web discussions, so the recap can understand more than a URL or page title."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Label("No keyboard character decoding", systemImage: "keyboard.badge.ellipsis")
                            Label("Private and excluded sites stay hidden", systemImage: "eye.slash.fill")
                            Label("Common credentials redacted", systemImage: "key.slash.fill")
                            Label("Stored locally and sealed", systemImage: "checkmark.seal.fill")
                            if analysis.coverage.semanticSnapshotCount > 0 {
                                Label(
                                    "\(analysis.coverage.semanticSnapshotCount) snapshots today",
                                    systemImage: "text.badge.checkmark"
                                )
                            }
                        }
                        .font(.system(size: 8, weight: .medium))
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
                    .toggleStyle(.switch)
                    .help("Enable optional accessible visible-text context")
                }
            }
        }
    }
#endif
