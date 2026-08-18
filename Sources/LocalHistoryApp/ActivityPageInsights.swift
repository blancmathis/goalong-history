#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    extension ActivityPage {
        func sitesCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    SectionTitle(
                        title: "Sites and pages",
                        subtitle: "One row per host, with repeated pages merged"
                    )
                    if analysis.sites.isEmpty {
                        compactEmpty(symbol: "globe", title: "No website context")
                    } else {
                        VStack(spacing: 11) {
                            ForEach(analysis.sites.prefix(7)) { site in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(site.host)
                                            .font(.system(size: 11, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(duration(site.activeSeconds))
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let page = site.pages.first {
                                        Text(page.title)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .textSelection(.enabled)
                                    }
                                    Text(
                                        "\(site.visitCount) block\(site.visitCount == 1 ? "" : "s") · \(site.pageCount) page\(site.pageCount == 1 ? "" : "s")"
                                    )
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                if site.id != analysis.sites.prefix(7).last?.id { Divider() }
                            }
                        }
                    }
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
                                "Stable Markdown, ordered by time, already deduplicated and bounded by an explicit token budget."
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
                            "Adds selected and visible text exposed by macOS Accessibility, so the recap can understand pages, discussions and requests instead of seeing only titles and URLs."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Label("No keyboard character decoding", systemImage: "keyboard.badge.ellipsis")
                            Label("Private and excluded contexts stay hidden", systemImage: "eye.slash.fill")
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
