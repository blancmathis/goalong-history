#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    extension ActivityPage {
        func focusBlocksCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "What you worked on",
                        subtitle: "Continuous activity is grouped by task, app, site and semantic similarity"
                    )

                    if analysis.focusBlocks.isEmpty {
                        EmptyStateView(
                            symbol: "rectangle.3.group",
                            title: "No focus blocks",
                            message: "Meaningful foreground activity will appear here after it is recorded."
                        )
                        .frame(height: 260)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(analysis.focusBlocks) { block in
                                focusBlockRow(block)
                            }
                        }
                    }
                }
            }
        }

        func focusBlockRow(_ block: ActivityFocusBlock) -> some View {
            let expanded = expandedBlockID == block.id
            return Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expandedBlockID = expanded ? nil : block.id
                }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DashboardFormatters.shortTime.string(from: block.start))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                            Text(duration(block.activeSeconds))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 52, alignment: .leading)

                        Rectangle()
                            .fill(block.isWork == true ? LHTheme.success : LHTheme.accent)
                            .frame(width: 3)
                            .clipShape(Capsule())

                        VStack(alignment: .leading, spacing: 6) {
                            Text(block.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 7) {
                                if let category = block.category {
                                    CategoryBadge(category: category, isWork: block.isWork)
                                }
                                if !block.applications.isEmpty {
                                    Text(block.applications.prefix(3).joined(separator: " · "))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if !block.hosts.isEmpty {
                                Label(block.hosts.prefix(3).joined(separator: " · "), systemImage: "globe")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }

                    if expanded {
                        Divider()
                        VStack(alignment: .leading, spacing: 9) {
                            if let request = block.requestSnippets.first {
                                detailLine(symbol: "text.bubble", title: "Request", value: request)
                            }
                            if let context = block.contextSnippets.first {
                                detailLine(symbol: "text.quote", title: "Visible context", value: context)
                            }
                            if !block.pageTitles.isEmpty {
                                detailLine(
                                    symbol: "doc.text.magnifyingglass",
                                    title: "Pages",
                                    value: block.pageTitles.prefix(4).joined(separator: "\n")
                                )
                            }
                            HStack(spacing: 14) {
                                Label("\(block.eventCount.formatted()) source events", systemImage: "list.number")
                                Label("\(block.inputEventCount.formatted()) input events", systemImage: "keyboard")
                            }
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 67)
                    }
                }
                .padding(12)
                .background(
                    Color.primary.opacity(expanded ? 0.055 : 0.032),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        func detailLine(symbol: String, title: String, value: String) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.35)
                        .foregroundStyle(.tertiary)
                    Text(value)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }

        var evidenceCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    SectionTitle(
                        title: "Underlying local evidence",
                        subtitle: "Recent raw sessions remain available for inspection; they are not sent to the agent brief"
                    )
                    if model.snapshot.sessions.isEmpty {
                        compactEmpty(symbol: "list.bullet.rectangle", title: "No session evidence")
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 260), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(model.snapshot.sessions.prefix(12)) { session in
                                HStack(spacing: 10) {
                                    AppIconView(
                                        bundleIdentifier: session.bundleIdentifier,
                                        appName: session.appName,
                                        size: 28
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.appName)
                                            .font(.system(size: 10, weight: .semibold))
                                            .lineLimit(1)
                                        Text(session.windowTitle ?? session.host ?? "Activity")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(DashboardFormatters.shortTime.string(from: session.start))
                                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        Text(DashboardFormatters.duration(seconds: session.duration))
                                            .font(.system(size: 8))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(9)
                                .background(
                                    Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                            }
                        }
                    }
                }
            }
        }

    }
#endif
