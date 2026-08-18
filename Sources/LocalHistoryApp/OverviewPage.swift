#if os(macOS)
    import SwiftUI

    struct OverviewPage: View {
        @ObservedObject var model: DashboardViewModel

        private let metricColumns = [
            GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)
        ]

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: Calendar.current.isDateInToday(model.selectedDay) ? "Today" : "History",
                        title: DashboardFormatters.dayTitle.string(from: model.selectedDay),
                        subtitle: "A clear view of what was observed, sealed and kept private."
                    ) {
                        HStack(spacing: 10) {
                            DateSelectionControl(date: model.selectedDay, onChange: model.selectDay)
                            Button {
                                model.refreshEverything()
                            } label: {
                                Image(
                                    systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                                )
                                .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isRefreshing)
                            .help("Refresh")
                        }
                    }

                    runtimeHero

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                        MetricCard(
                            title: "ACTIVE INPUT",
                            value: DashboardFormatters.duration(minutes: model.snapshot.activeMinutes),
                            detail: "Minutes with meaningful local activity",
                            symbol: "cursorarrow.click.2",
                            tint: LHTheme.teal
                        )
                        MetricCard(
                            title: "WORK CLASSIFIED",
                            value: DashboardFormatters.duration(minutes: model.snapshot.workMinutes),
                            detail: "Conservative local classification",
                            symbol: "briefcase.fill",
                            tint: LHTheme.success
                        )
                        MetricCard(
                            title: "LIVE VERIFIED",
                            value: DashboardFormatters.percentage(
                                model.snapshot.liveAnchoredMinutes,
                                model.snapshot.sealedMinutes
                            ),
                            detail: model.runtime.verificationEnabled
                                ? "\(model.snapshot.liveAnchoredMinutes) of \(model.snapshot.sealedMinutes) sealed minutes"
                                : "Verification server is currently disabled",
                            symbol: "checkmark.seal.fill",
                            tint: LHTheme.accent
                        )
                        MetricCard(
                            title: "PRIVATE / UNAVAILABLE",
                            value: DashboardFormatters.duration(minutes: model.snapshot.privateMinutes),
                            detail: "Details intentionally hidden or unavailable",
                            symbol: "eye.slash.fill",
                            tint: LHTheme.privateTint
                        )
                    }

                    timelineCard

                    HStack(alignment: .top, spacing: 14) {
                        appBreakdownCard
                            .frame(maxWidth: .infinity)
                        recentActivityCard
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 30)
            }
            .background(LHTheme.pageBackground)
        }

        private var runtimeHero: some View {
            LHCard(padding: 20) {
                HStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(model.runtime.displayTint.opacity(0.12))
                        Circle()
                            .stroke(model.runtime.displayTint.opacity(0.22), lineWidth: 1)
                        Image(systemName: model.runtime.displaySymbol)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(model.runtime.displayTint)
                    }
                    .frame(width: 62, height: 62)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 9) {
                            Text(model.runtime.displayTitle)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            StatusPill(
                                title: model.runtime.verificationEnabled ? "Opaque proofs on" : "Local only",
                                symbol: model.runtime.verificationEnabled ? "checkmark.seal" : "internaldrive",
                                tint: model.runtime.verificationEnabled ? LHTheme.accent : Color.secondary
                            )
                        }
                        Text(model.runtime.displayDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 20)

                    if !model.runtime.accessibilityGranted || !model.runtime.inputMonitoringGranted {
                        Button("Finish setup") {
                            model.requestPermissions()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if model.runtime.state == .paused {
                        Button {
                            model.togglePause()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("p", modifiers: [.command])
                    } else {
                        Button {
                            model.togglePause()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("p", modifiers: [.command])
                    }
                }
            }
        }

        private var timelineCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Day coverage")
                                .font(.system(size: 15, weight: .semibold))
                            Text(
                                "Each block represents 15 minutes. Private periods remain visible without exposing content."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(model.snapshot.sealedMinutes) sealed min")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if model.snapshot.timeline.isEmpty {
                        EmptyStateView(
                            symbol: "clock",
                            title: "No timeline yet",
                            message:
                                "Sealed activity will appear here after LocalHistory has been running for a minute."
                        )
                        .frame(height: 90)
                    } else {
                        TimelineStrip(buckets: model.snapshot.timeline)
                    }

                    HStack(spacing: 16) {
                        timelineLegend(label: "Work", color: LHTheme.success)
                        timelineLegend(label: "Active", color: LHTheme.teal)
                        timelineLegend(label: "Private", color: LHTheme.privateTint)
                        timelineLegend(label: "Sealed / idle", color: Color.secondary.opacity(0.45))
                        Spacer()
                    }
                }
            }
        }

        private var appBreakdownCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Top applications",
                        subtitle: "Approximate active minutes from observed input"
                    )

                    if model.snapshot.appUsage.isEmpty {
                        EmptyStateView(
                            symbol: "app.dashed",
                            title: "No app activity",
                            message:
                                "Applications will appear after clicks, typing, scrolling or context changes are observed."
                        )
                        .frame(height: 250)
                    } else {
                        let maximum = max(1, model.snapshot.appUsage.first?.activeMinutes ?? 1)
                        VStack(spacing: 12) {
                            ForEach(Array(model.snapshot.appUsage.prefix(6))) { usage in
                                HStack(spacing: 11) {
                                    AppIconView(
                                        bundleIdentifier: usage.bundleIdentifier,
                                        appName: usage.appName,
                                        size: 31
                                    )
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(usage.appName)
                                                .font(.system(size: 11, weight: .semibold))
                                                .lineLimit(1)
                                            Spacer()
                                            Text(DashboardFormatters.duration(minutes: usage.activeMinutes))
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                                .foregroundStyle(.secondary)
                                        }
                                        ProgressBar(
                                            value: Double(usage.activeMinutes) / Double(maximum),
                                            tint: LHTheme.accent
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        private var recentActivityCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Recent activity")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Locally grouped into understandable sessions")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View all") {
                            model.selectSection(.activity)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .semibold))
                    }

                    if model.snapshot.sessions.isEmpty {
                        EmptyStateView(
                            symbol: "list.bullet.rectangle",
                            title: "No sessions yet",
                            message: "Recent sessions will appear here as LocalHistory observes activity."
                        )
                        .frame(height: 250)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(Array(model.snapshot.sessions.prefix(6))) { session in
                                Button {
                                    model.selectSession(session.id)
                                    model.selectSection(.activity)
                                } label: {
                                    HStack(spacing: 10) {
                                        AppIconView(
                                            bundleIdentifier: session.bundleIdentifier,
                                            appName: session.appName,
                                            size: 30
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(session.appName)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .lineLimit(1)
                                                if session.isFlagged {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(LHTheme.warning)
                                                }
                                            }
                                            Text(
                                                session.windowTitle ?? session.host ?? session.category.map(
                                                    CategoryBadge.prettyCategory) ?? "Activity"
                                            )
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(DashboardFormatters.shortTime.string(from: session.start))
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                            Text(DashboardFormatters.duration(seconds: session.duration))
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 7)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }

        private func timelineLegend(label: String, color: Color) -> some View {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct TimelineStrip: View {
        let buckets: [TimelineBucket]

        var body: some View {
            VStack(spacing: 7) {
                GeometryReader { proxy in
                    let spacing: CGFloat = 2
                    let totalSpacing = spacing * CGFloat(max(0, buckets.count - 1))
                    let width = max(2, (proxy.size.width - totalSpacing) / CGFloat(max(1, buckets.count)))
                    HStack(spacing: spacing) {
                        ForEach(buckets) { bucket in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(color(for: bucket.kind))
                                .frame(width: width)
                                .help(helpText(for: bucket))
                        }
                    }
                }
                .frame(height: 34)

                HStack {
                    Text("00:00")
                    Spacer()
                    Text("06:00")
                    Spacer()
                    Text("12:00")
                    Spacer()
                    Text("18:00")
                    Spacer()
                    Text("24:00")
                }
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.tertiary)
            }
        }

        private func color(for kind: TimelineBucketKind) -> Color {
            switch kind {
            case .work: return LHTheme.success
            case .active: return LHTheme.teal
            case .privateOrSuppressed: return LHTheme.privateTint
            case .sealed: return Color.secondary.opacity(0.38)
            case .future: return Color.primary.opacity(0.025)
            case .noData: return Color.primary.opacity(0.075)
            }
        }

        private func helpText(for bucket: TimelineBucket) -> String {
            let range =
                "\(DashboardFormatters.shortTime.string(from: bucket.start))–\(DashboardFormatters.shortTime.string(from: bucket.end))"
            return
                "\(range) · \(bucket.activeMinutes)m active · \(bucket.workMinutes)m work · \(bucket.privateMinutes)m private"
        }
    }
#endif
