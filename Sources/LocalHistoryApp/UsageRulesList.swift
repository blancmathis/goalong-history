#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct UsageRulesList: View {
        @ObservedObject var model: DashboardViewModel
        var showsDefaultRule = false
        var websiteSummaries: [ActivitySiteSummary] = []
        var richContextEnabled = false
        var onEnableRichContext: (() -> Void)?

        @State private var expandedWebsiteIDs = Set<String>()

        private var filteredItems: [TrackedUsageItem] {
            let query = model.usageSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return model.snapshot.trackedUsage }
            return model.snapshot.trackedUsage.filter { item in
                if item.searchableText.contains(query) { return true }
                guard item.kind == .website,
                    let summary = websiteSummariesBySubjectID[item.id]
                else { return false }
                let detailText = [
                    summary.host,
                    summary.sourceApplications.joined(separator: " "),
                    summary.pages.map { [$0.title, $0.URL ?? ""].joined(separator: " ") }.joined(separator: " "),
                    summary.interactions.map(\.label).joined(separator: " "),
                    summary.rememberedContext.joined(separator: " "),
                ].joined(separator: " ").lowercased()
                return detailText.contains(query)
            }
        }

        private var applications: [TrackedUsageItem] {
            filteredItems.filter { $0.kind == .application }
        }

        private var websites: [TrackedUsageItem] {
            filteredItems.filter { $0.kind == .website }
        }

        private var websiteSummariesBySubjectID: [String: ActivitySiteSummary] {
            Dictionary(
                uniqueKeysWithValues: websiteSummaries.map {
                    (SharingSubjectKey.website(host: $0.host), $0)
                }
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                controls
                if filteredItems.isEmpty {
                    LHCard {
                        EmptyStateView(
                            symbol: "app.dashed",
                            title: model.snapshot.trackedUsage.isEmpty ? "No observed apps or sites" : "No matches",
                            message: model.snapshot.trackedUsage.isEmpty
                                ? "Keep LocalHistory running. Apps and websites will appear as context is observed."
                                : "Try a different app, website or category."
                        )
                        .frame(minHeight: 320)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            subjectSection(title: "Websites", symbol: "globe", items: websites)
                            subjectSection(title: "Applications", symbol: "square.grid.2x2", items: applications)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        }

        private var controls: some View {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps, websites, pages or categories", text: $model.usageSearch)
                        .textFieldStyle(.plain)
                    if !model.usageSearch.isEmpty {
                        Button {
                            model.usageSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

                if showsDefaultRule {
                    Text("Default")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker(
                        "Default sharing rule",
                        selection: Binding(
                            get: { model.defaultSharingVisibility },
                            set: model.setDefaultSharingVisibility
                        )
                    ) {
                        ForEach(SharingVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Text("\(filteredItems.count) item\(filteredItems.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .trailing)
            }
        }

        @ViewBuilder
        private func subjectSection(title: String, symbol: String, items: [TrackedUsageItem]) -> some View {
            if !items.isEmpty {
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Label(title, systemImage: symbol)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(items.count)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                            Spacer()
                            Text("TIME OBSERVED")
                                .help("Estimated foreground time from context snapshots. Unobserved gaps are never filled beyond 75 seconds.")
                                .frame(width: 96, alignment: .trailing)
                            Text("INPUT ACTIVE")
                                .help("Distinct minutes containing observed click, keyboard or scroll activity.")
                                .frame(width: 82, alignment: .trailing)
                            Text("ALWAYS WHEN SHARING")
                                .frame(width: 142, alignment: .trailing)
                            if title == "Websites" {
                                Text("DETAILS")
                                    .frame(width: 46, alignment: .trailing)
                            }
                        }
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.35)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 40)

                        Divider()

                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let isExpanded = expandedWebsiteIDs.contains(item.id)
                            UsageSubjectRow(
                                model: model,
                                item: item,
                                websiteSummary: websiteSummariesBySubjectID[item.id],
                                expanded: isExpanded,
                                richContextEnabled: richContextEnabled,
                                onEnableRichContext: onEnableRichContext,
                                onToggleExpanded: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        if isExpanded {
                                            expandedWebsiteIDs.remove(item.id)
                                        } else {
                                            expandedWebsiteIDs.insert(item.id)
                                        }
                                    }
                                }
                            )
                            if index < items.count - 1 { Divider().padding(.leading, 58) }
                        }
                    }
                }
            }
        }
    }

    private struct UsageSubjectRow: View {
        @ObservedObject var model: DashboardViewModel
        let item: TrackedUsageItem
        let websiteSummary: ActivitySiteSummary?
        let expanded: Bool
        let richContextEnabled: Bool
        let onEnableRichContext: (() -> Void)?
        let onToggleExpanded: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                summaryRow
                if item.kind == .website, expanded {
                    Divider().padding(.leading, 58)
                    websiteDetail
                        .padding(.leading, 58)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                }
            }
        }

        private var summaryRow: some View {
            HStack(spacing: 12) {
                if item.kind == .application {
                    AppIconView(bundleIdentifier: item.bundleIdentifier, appName: item.name, size: 32)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LHTheme.teal)
                        .frame(width: 32, height: 32)
                        .background(LHTheme.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(item.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        CategoryBadge(category: item.category, isWork: nil)
                        if let host = item.host, model.isDomainExcludedFromCapture(host) {
                            StatusPill(
                                title: "Future details excluded",
                                symbol: "eye.slash.fill",
                                tint: LHTheme.privateTint
                            )
                            .scaleEffect(0.82, anchor: .leading)
                        }
                    }
                    Text(secondaryLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(DashboardFormatters.duration(seconds: item.foregroundSeconds))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: 96, alignment: .trailing)

                Text(item.activeMinutes == 0 ? "—" : "\(item.activeMinutes)m")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .trailing)

                Picker(
                    "Visibility for \(item.name)",
                    selection: Binding(
                        get: { model.sharingVisibility(for: item.id) },
                        set: { model.setSharingVisibility($0, for: item.id) }
                    )
                ) {
                    ForEach(SharingVisibility.allCases) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
                .labelsHidden()
                .frame(width: 142)

                if item.kind == .website {
                    HStack(spacing: 5) {
                        siteActionsMenu
                        Button(action: onToggleExpanded) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide website details" : "Show every observed page and web interaction")
                    }
                    .frame(width: 46, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .help(identityHelp)
        }

        private var siteActionsMenu: some View {
            Menu {
                if let host = item.host {
                    Button("Hide in every share") {
                        model.hideWebsiteInEveryShare(host)
                    }
                    Button("Share category only") {
                        model.setSharingVisibility(.categoryOnly, for: item.id)
                    }
                    Button("Show site name in shares") {
                        model.setSharingVisibility(.identity, for: item.id)
                    }
                    Divider()
                    if model.isDomainExcludedFromCapture(host) {
                        Button("Allow future details again") {
                            model.setDomainCaptureEnabled(true, host: host)
                        }
                    } else {
                        Button("Exclude all future details", role: .destructive) {
                            model.setDomainCaptureEnabled(false, host: host)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 19, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Persistent website rules")
        }

        @ViewBuilder
        private var websiteDetail: some View {
            if let detail = websiteSummary {
                VStack(alignment: .leading, spacing: 14) {
                    websiteControls(detail)
                    metrics(detail)
                    pagesSection(detail)
                    clicksSection(detail)
                    otherActionsSection(detail)
                    rememberedContextSection(detail)
                }
                .padding(.top, 13)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Detailed pages and interactions are generated by the Day recap analysis.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 12)
            }
        }

        private func websiteControls(_ detail: ActivitySiteSummary) -> some View {
            HStack(spacing: 14) {
                if let host = item.host {
                    Toggle(
                        isOn: Binding(
                            get: { !model.isDomainExcludedFromCapture(host) },
                            set: { model.setDomainCaptureEnabled($0, host: host) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remember future site details")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Turn off to keep only a private coverage gap for this domain from now on.")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Spacer()

                if !richContextEnabled, let onEnableRichContext {
                    Button("Enable visible page memory") {
                        onEnableRichContext()
                    }
                    .buttonStyle(.bordered)
                    .help("Required to remember accessible ChatGPT-style discussions and visible page text")
                } else if richContextEnabled {
                    Label(
                        "\(detail.semanticSnapshotCount) visible-memory snapshot\(detail.semanticSnapshotCount == 1 ? "" : "s")",
                        systemImage: "text.badge.checkmark"
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(detail.semanticSnapshotCount > 0 ? LHTheme.success : Color.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }

        private func metrics(_ detail: ActivitySiteSummary) -> some View {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 125), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                websiteMetric("Pages", value: "\(detail.pageCount)", symbol: "doc.on.doc")
                websiteMetric("Clicks", value: "\(detail.clickCount)", symbol: "cursorarrow.click")
                websiteMetric("Typing bursts", value: "\(detail.typingBurstCount)", symbol: "keyboard")
                websiteMetric("Scroll bursts", value: "\(detail.scrollBurstCount)", symbol: "scroll")
                websiteMetric("Remembered", value: "\(detail.rememberedContext.count)", symbol: "brain.head.profile")
                websiteMetric(
                    "Observed through",
                    value: detail.sourceApplications.isEmpty
                        ? "Web container"
                        : detail.sourceApplications.joined(separator: ", "),
                    symbol: "macwindow"
                )
            }
        }

        private func websiteMetric(_ title: String, value: String, symbol: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 25, height: 25)
                    .background(LHTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased())
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(.tertiary)
                    Text(value)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(2)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.primary.opacity(0.027), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        private func pagesSection(_ detail: ActivitySiteSummary) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                detailHeading(
                    "Every observed page",
                    subtitle: detail.pagesTruncated
                        ? "The analysis cache is truncated; source events remain available."
                        : "Repeated visits to the same sanitized URL are merged."
                )
                if detail.pages.isEmpty {
                    compactDetailEmpty("No page URL was exposed by this web container.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(detail.pages) { page in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LHTheme.teal)
                                    .frame(width: 22, height: 22)
                                    .background(LHTheme.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(page.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let URL = page.URL {
                                        Text(URL)
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .textSelection(.enabled)
                                    }
                                    HStack(spacing: 8) {
                                        Text(DashboardFormatters.duration(seconds: TimeInterval(page.activeSeconds)))
                                        Text("\(page.clickCount) click\(page.clickCount == 1 ? "" : "s")")
                                        Text("\(page.semanticSnapshotCount) memory snapshot\(page.semanticSnapshotCount == 1 ? "" : "s")")
                                        Text(
                                            "\(DashboardFormatters.shortTime.string(from: page.firstSeen))–\(DashboardFormatters.shortTime.string(from: page.lastSeen))"
                                        )
                                    }
                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(9)
                            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }
            }
        }

        private func clicksSection(_ detail: ActivitySiteSummary) -> some View {
            let clicks = detail.interactions.filter { $0.kind == .click }
            return VStack(alignment: .leading, spacing: 8) {
                detailHeading(
                    "Everything clicked",
                    subtitle:
                        "Identical targets on the same page are grouped with a count; unlabelled clicks keep their position."
                )
                if clicks.isEmpty {
                    compactDetailEmpty("No click target was observed for this site on the selected day.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(clicks) { interaction in
                            WebsiteInteractionRow(interaction: interaction)
                        }
                    }
                    if detail.interactionsTruncated {
                        Label(
                            "The compact analysis reached its interaction limit. Raw sealed events still contain the remaining clicks.",
                            systemImage: "ellipsis.circle"
                        )
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }


        private func otherActionsSection(_ detail: ActivitySiteSummary) -> some View {
            let actions = detail.interactions.filter { $0.kind != .click }
            return VStack(alignment: .leading, spacing: 8) {
                detailHeading(
                    "Other observed web activity",
                    subtitle:
                        "Typing is represented only as counts and duration; characters are never reconstructed."
                )
                if actions.isEmpty {
                    compactDetailEmpty("No typing, scroll or shortcut activity was observed for this site.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(actions) { interaction in
                            WebsiteInteractionRow(interaction: interaction)
                        }
                    }
                }
            }
        }

        private func rememberedContextSection(_ detail: ActivitySiteSummary) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                detailHeading(
                    "Remembered visible page context",
                    subtitle:
                        "With Rich Context enabled, accessible page text and web discussions are stored locally, redacted, deduplicated and sealed."
                )
                if !richContextEnabled {
                    compactDetailEmpty("Rich Context is off. URLs, titles and click targets are still available, but visible discussions are not remembered.")
                } else if detail.rememberedContext.isEmpty {
                    compactDetailEmpty("No accessible visible text was exposed for this site yet.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(detail.rememberedContext.enumerated()), id: \.offset) { _, text in
                            Text(text)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(
                                    LHTheme.privateTint.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                        }
                    }
                    if detail.rememberedContextTruncated {
                        Label(
                            "More context exists in the sealed source events than is shown in this compact cache.",
                            systemImage: "ellipsis.circle"
                        )
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        private func detailHeading(_ title: String, subtitle: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func compactDetailEmpty(_ message: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(9)
            .background(Color.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        private var secondaryLabel: String {
            if item.kind == .website {
                var parts: [String] = []
                if let detail = websiteSummary {
                    parts.append("\(detail.pageCount) page\(detail.pageCount == 1 ? "" : "s")")
                    parts.append("\(detail.clickCount) click\(detail.clickCount == 1 ? "" : "s")")
                    if detail.semanticSnapshotCount > 0 {
                        parts.append("\(detail.semanticSnapshotCount) memory snapshot\(detail.semanticSnapshotCount == 1 ? "" : "s")")
                    }
                    if !detail.sourceApplications.isEmpty {
                        parts.append("via \(detail.sourceApplications.joined(separator: ", "))")
                    }
                } else if let appName = item.appName {
                    parts.append("Seen in \(appName)")
                } else {
                    parts.append("Web context observed")
                }
                if !item.identityProofAvailable {
                    parts.append("older entries share category only")
                }
                return parts.joined(separator: " · ")
            }
            return item.bundleIdentifier ?? "Application observed locally"
        }

        private var identityHelp: String {
            if item.kind == .website, !item.identityProofAvailable {
                return "Some entries predate website-only proofs. They fall back to Category only instead of revealing a full URL."
            }
            return model.sharingVisibility(for: item.id).subtitle
        }
    }

    private struct WebsiteInteractionRow: View {
        let interaction: ActivityWebInteractionSummary

        private var symbol: String {
            switch interaction.kind {
            case .click: return "cursorarrow.click"
            case .typing: return "keyboard"
            case .scroll: return "scroll"
            case .shortcut: return "command"
            }
        }

        private var tint: Color {
            switch interaction.kind {
            case .click: return LHTheme.warning
            case .typing: return LHTheme.accent
            case .scroll: return LHTheme.teal
            case .shortcut: return LHTheme.privateTint
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(interaction.label)
                            .font(.system(size: 10, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if interaction.count > 1 {
                            Text("×\(interaction.count)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(tint.opacity(0.1), in: Capsule())
                        }
                    }
                    if let pageTitle = interaction.pageTitle {
                        Text(pageTitle)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(DashboardFormatters.shortTime.string(from: interaction.firstSeen))
                        if interaction.lastSeen > interaction.firstSeen {
                            Text("last \(DashboardFormatters.shortTime.string(from: interaction.lastSeen))")
                        }
                        if let role = interaction.role { Text(role) }
                        if let detail = interaction.detail { Text(detail) }
                    }
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(9)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
#endif
