#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct ActivityTimelineExplorer: View {
        @ObservedObject var model: DashboardViewModel

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                filterBar

                HStack(alignment: .top, spacing: 14) {
                    sessionList
                        .frame(minWidth: 330, idealWidth: 400, maxWidth: 450)
                    sessionDetail
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }

        private var filterBar: some View {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search app, window, website or category", text: $model.activitySearch)
                        .textFieldStyle(.plain)
                    if !model.activitySearch.isEmpty {
                        Button {
                            model.activitySearch = ""
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

                Picker("Filter", selection: $model.activityFilter) {
                    ForEach(ActivityFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 310)

                Text("\(model.filteredSessions.count) session\(model.filteredSessions.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }

        private var sessionList: some View {
            LHCard(padding: 0) {
                if model.filteredSessions.isEmpty {
                    EmptyStateView(
                        symbol: "line.3.horizontal.decrease.circle",
                        title: model.snapshot.sessions.isEmpty ? "No activity found" : "No matching sessions",
                        message: model.snapshot.sessions.isEmpty
                            ? "Keep LocalHistory running and activity will appear here."
                            : "Try another search or filter."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.filteredSessions) { session in
                                ActivityTimelineSessionRow(
                                    session: session,
                                    selected: model.selectedSession?.id == session.id
                                ) {
                                    model.selectSession(session.id)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }

        private var sessionDetail: some View {
            LHCard(padding: 0) {
                if let session = model.selectedSession {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            detailHeader(session)
                            Divider()
                            detailsGrid(session)
                            if session.suppressionReason != nil {
                                privacyNotice(session)
                            }
                            if session.isFlagged {
                                automationNotice(session)
                            }
                            eventBreakdown(session)
                            ActivityEventInspector(session: session)
                        }
                        .padding(22)
                    }
                } else {
                    EmptyStateView(
                        symbol: "rectangle.and.hand.point.up.left",
                        title: "Select a session",
                        message: "Choose a session to inspect its local context, category and integrity signals."
                    )
                }
            }
        }

        private func detailHeader(_ session: ActivitySession) -> some View {
            HStack(alignment: .top, spacing: 15) {
                AppIconView(
                    bundleIdentifier: session.bundleIdentifier,
                    appName: session.appName,
                    size: 48
                )
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(session.appName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        if let reason = session.suppressionReason {
                            StatusPill(
                                title: privacyLabel(reason),
                                symbol: "eye.slash",
                                tint: LHTheme.privateTint
                            )
                        } else {
                            StatusPill(
                                title: "Stored locally",
                                symbol: "internaldrive",
                                tint: LHTheme.teal
                            )
                        }
                    }
                    Text(session.windowTitle ?? session.host ?? "No detailed context available")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        CategoryBadge(category: session.category, isWork: session.isWork)
                        Text(
                            "\(DashboardFormatters.shortTime.string(from: session.start))–\(DashboardFormatters.shortTime.string(from: session.end))"
                        )
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        Text(DashboardFormatters.duration(seconds: session.duration))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }

        private func detailsGrid(_ session: ActivitySession) -> some View {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                detailValue(
                    title: "Application",
                    value: session.bundleIdentifier ?? session.appName,
                    symbol: "app"
                )
                detailValue(
                    title: "Local category",
                    value: session.category.map(CategoryBadge.prettyCategory) ?? "Unclassified",
                    symbol: "tag"
                )
                detailValue(
                    title: "Observed events",
                    value: "\(session.eventCount)",
                    symbol: "list.number"
                )
                detailValue(
                    title: "Input events",
                    value: "\(session.inputEventCount)",
                    symbol: "keyboard"
                )
                detailValue(
                    title: "Classification confidence",
                    value: session.confidence.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not available",
                    symbol: "gauge.with.dots.needle.50percent"
                )
                detailValue(
                    title: "Software-attributed input",
                    value: "\(session.softwareAttributedEventCount)",
                    symbol: "exclamationmark.triangle"
                )
            }
        }

        private func detailValue(title: String, value: String, symbol: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(LHTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }

        private func privacyNotice(_ session: ActivitySession) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LHTheme.privateTint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Details intentionally unavailable")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "LocalHistory preserved only the coverage state for this period. It cannot later reveal the hidden URL, title or input details."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(LHTheme.privateTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private func automationNotice(_ session: ActivitySession) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LHTheme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Software-attributed input detected")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "macOS attributed \(session.softwareAttributedEventCount) input event(s) to a userspace process. This is an integrity signal, not automatic proof of cheating."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(LHTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private func eventBreakdown(_ session: ActivitySession) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    title: "Event breakdown",
                    subtitle: "Counts only — raw typed characters are never stored"
                )
                let sorted = session.kindCounts.sorted { left, right in
                    if left.value == right.value { return left.key < right.key }
                    return left.value > right.value
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(sorted, id: \.key) { entry in
                        HStack {
                            Text(prettyEventKind(entry.key))
                                .font(.system(size: 10, weight: .medium))
                            Spacer()
                            Text("\(entry.value)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }

        private func privacyLabel(_ reason: SuppressionReason) -> String {
            switch reason {
            case .privateBrowserWindow: return "Private browsing"
            case .excludedApplication: return "Excluded app"
            case .excludedDomain: return "Excluded site"
            case .secureInput: return "Secure input"
            case .sessionUnavailable: return "Session unavailable"
            case .manualPause: return "Paused"
            case .accessibilityUnavailable: return "Context unavailable"
            }
        }

        private func prettyEventKind(_ raw: String) -> String {
            var result = ""
            for character in raw {
                if character.isUppercase, !result.isEmpty { result.append(" ") }
                result.append(character)
            }
            return result.prefix(1).uppercased() + result.dropFirst()
        }
    }

    private struct ActivityTimelineSessionRow: View {
        let session: ActivitySession
        let selected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 11) {
                    AppIconView(
                        bundleIdentifier: session.bundleIdentifier,
                        appName: session.appName,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(session.appName)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            if session.suppressionReason != nil {
                                Image(systemName: "eye.slash.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(LHTheme.privateTint)
                            }
                            if session.isFlagged {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(LHTheme.warning)
                            }
                        }
                        Text(
                            session.windowTitle ?? session.host ?? session.category.map(CategoryBadge.prettyCategory)
                                ?? "Activity"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(DashboardFormatters.shortTime.string(from: session.start))
                            Text("·")
                            Text(DashboardFormatters.duration(seconds: session.duration))
                            if session.isWork == true {
                                Text("· Work")
                                    .foregroundStyle(LHTheme.success)
                            }
                        }
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? LHTheme.accent : Color.secondary.opacity(0.45))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(selected ? LHTheme.accent.opacity(0.11) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
#endif
