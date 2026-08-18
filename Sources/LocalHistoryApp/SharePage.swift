#if os(macOS)
    import SwiftUI
    import LocalHistoryCore

    struct SharePage: View {
        @ObservedObject var model: DashboardViewModel

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    eyebrow: "Selective disclosure",
                    title: "Share a verified day",
                    subtitle: "Choose exactly what each period reveals. The original local history is never rewritten."
                ) {
                    HStack(spacing: 10) {
                        DateSelectionControl(date: model.selectedDay, onChange: model.selectDay)
                        Button {
                            model.reloadShareSegments()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoadingShare)
                    }
                }

                disclosureBanner

                if model.shareSegments.isEmpty, !model.isLoadingShare {
                    LHCard {
                        EmptyStateView(
                            symbol: "checkmark.seal",
                            title: "No sealed minutes for this day",
                            message:
                                "LocalHistory creates a sealed commitment every minute while it is running. Select another day or wait for the first minute to be sealed.",
                            buttonTitle: "Refresh",
                            action: model.reloadShareSegments
                        )
                        .frame(minHeight: 360)
                    }
                } else {
                    shareSummary

                    HStack(alignment: .top, spacing: 14) {
                        segmentList
                            .frame(minWidth: 400, maxWidth: .infinity)
                        disclosurePreview
                            .frame(width: 300)
                    }
                    .frame(maxHeight: .infinity)

                    exportBar
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .background(LHTheme.pageBackground)
            .onAppear {
                if model.shareSegments.isEmpty { model.reloadShareSegments() }
            }
        }

        private var disclosureBanner: some View {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(LHTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anonymization does not modify your evidence")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "LocalHistory creates a separate disclosure package. Revealed fields are proven against the minute commitments already created; hidden fields stay on this Mac."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StatusPill(title: "Nothing uploaded yet", symbol: "internaldrive", tint: LHTheme.teal)
            }
            .padding(14)
            .background(LHTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LHTheme.accent.opacity(0.12), lineWidth: 1)
            )
        }

        private var shareSummary: some View {
            HStack(spacing: 10) {
                shareStat(
                    title: "Full",
                    value: minuteCount(for: .everything),
                    symbol: "eye.fill",
                    tint: LHTheme.accent
                )
                shareStat(
                    title: "App only",
                    value: minuteCount(for: .applicationOnly),
                    symbol: "app.fill",
                    tint: LHTheme.teal
                )
                shareStat(
                    title: "Category only",
                    value: minuteCount(for: .categoryOnly),
                    symbol: "tag.fill",
                    tint: LHTheme.success
                )
                shareStat(
                    title: "Completely private",
                    value: minuteCount(for: .privateOnly),
                    symbol: "eye.slash.fill",
                    tint: LHTheme.privateTint
                )

                Spacer(minLength: 10)

                Menu {
                    ForEach(ShareLevel.allCases, id: \.self) { level in
                        Button {
                            model.applySharePreset(level)
                        } label: {
                            Label(level.dashboardTitle, systemImage: level.dashboardSymbol)
                        }
                    }
                } label: {
                    Label("Apply to all", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }

        private func shareStat(title: String, value: Int, symbol: String, tint: Color) -> some View {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text("\(value)m")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(tint.opacity(0.08), in: Capsule())
        }

        private var segmentList: some View {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Timeline")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Contiguous minutes with the same local context are grouped together")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(totalMinutes)m sealed")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(model.shareSegments) { segment in
                                ShareSegmentRow(
                                    segment: segment,
                                    selected: model.selectedShareSegment?.id == segment.id,
                                    onSelect: { model.selectedShareSegmentID = segment.id },
                                    onLevelChange: { model.setShareLevel($0, for: segment.id) }
                                )
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }

        private var disclosurePreview: some View {
            LHCard {
                if let segment = model.selectedShareSegment {
                    VStack(alignment: .leading, spacing: 17) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("SHARE PREVIEW")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            Text(
                                "\(DashboardFormatters.shortTime.string(from: segment.start))–\(DashboardFormatters.shortTime.string(from: segment.end))"
                            )
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            Text("\(segment.minuteCount) sealed minute\(segment.minuteCount == 1 ? "" : "s")")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: segment.level.dashboardSymbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(levelTint(segment.level))
                                .frame(width: 36, height: 36)
                                .background(
                                    levelTint(segment.level).opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(segment.level.dashboardTitle)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(segment.level.dashboardSubtitle)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()

                        previewSection(
                            title: "Your local view",
                            rows: [
                                ("Application", segment.appSummary),
                                ("Category", CategoryBadge.prettyCategory(segment.categorySummary)),
                            ]
                        )

                        previewChecklist(
                            title: "The package reveals",
                            items: revealedItems(for: segment.level),
                            symbol: "checkmark.circle.fill",
                            tint: LHTheme.success
                        )

                        previewChecklist(
                            title: "Stays hidden",
                            items: hiddenItems(for: segment.level),
                            symbol: "eye.slash.fill",
                            tint: LHTheme.privateTint
                        )

                        if !segment.canRevealDetails {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(LHTheme.privateTint)
                                Text(
                                    "Detailed events were deleted or unavailable. This period is safely forced to Completely private."
                                )
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(11)
                            .background(
                                LHTheme.privateTint.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        Spacer(minLength: 0)
                    }
                } else {
                    EmptyStateView(
                        symbol: "hand.point.up.left",
                        title: "Select a period",
                        message: "Choose a row to preview exactly what its disclosure level reveals."
                    )
                }
            }
        }

        private var exportBar: some View {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to create a verified disclosure package")
                        .font(.system(size: 11, weight: .semibold))
                    Text(
                        "Every sealed minute remains represented. Completely private periods are not counted as verified work."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoadingShare {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    model.exportSharePackage()
                } label: {
                    Label("Export verified package", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoadingShare || model.shareSegments.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }

        private var totalMinutes: Int {
            model.shareSegments.reduce(0) { $0 + $1.minuteCount }
        }

        private func minuteCount(for level: ShareLevel) -> Int {
            model.shareSegments
                .filter { $0.level == level }
                .reduce(0) { $0 + $1.minuteCount }
        }

        private func levelTint(_ level: ShareLevel) -> Color {
            switch level {
            case .everything: return LHTheme.accent
            case .applicationOnly: return LHTheme.teal
            case .categoryOnly: return LHTheme.success
            case .privateOnly: return LHTheme.privateTint
            }
        }

        private func previewSection(title: String, rows: [(String, String)]) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                    let row = entry.element
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }

        private func previewChecklist(title: String, items: [String], symbol: String, tint: Color) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: symbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
        }

        private func revealedItems(for level: ShareLevel) -> [String] {
            switch level {
            case .everything:
                return [
                    "Time and coverage", "Application", "Context and website host", "Local category", "Activity counts",
                ]
            case .applicationOnly:
                return ["Time and coverage", "Application identity", "Integrity and input-origin proofs"]
            case .categoryOnly:
                return ["Time and coverage", "Local category", "Classifier version and confidence"]
            case .privateOnly:
                return ["Time range", "Coverage state", "Existence of a valid sealed period"]
            }
        }

        private func hiddenItems(for level: ShareLevel) -> [String] {
            switch level {
            case .everything:
                return ["Raw typed characters (never stored)", "Commitment salts for unrelated fields"]
            case .applicationOnly:
                return ["Window title", "URL and website host", "Category", "Click and typing details"]
            case .categoryOnly:
                return ["Application", "Window title", "URL", "Click and typing details"]
            case .privateOnly:
                return ["Application", "Category", "Event count", "Context", "All detailed events"]
            }
        }
    }

    private struct ShareSegmentRow: View {
        let segment: ShareSegment
        let selected: Bool
        let onSelect: () -> Void
        let onLevelChange: (ShareLevel) -> Void

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(DashboardFormatters.shortTime.string(from: segment.start))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Text(DashboardFormatters.shortTime.string(from: segment.end))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 46, alignment: .leading)

                Rectangle()
                    .fill(levelTint(segment.level))
                    .frame(width: 3, height: 38)
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 3) {
                    Text(segment.appSummary == "—" ? "No application details" : segment.appSummary)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(
                            segment.categorySummary == "—"
                                ? "Unclassified" : CategoryBadge.prettyCategory(segment.categorySummary))
                        Text("·")
                        Text("\(segment.minuteCount)m")
                        if !segment.canRevealDetails {
                            Text("· Details unavailable")
                                .foregroundStyle(LHTheme.privateTint)
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Menu {
                    ForEach(ShareLevel.allCases, id: \.self) { level in
                        Button {
                            onLevelChange(level)
                        } label: {
                            Label(level.dashboardTitle, systemImage: level.dashboardSymbol)
                        }
                        .disabled(!segment.canRevealDetails && level != .privateOnly)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: segment.level.dashboardSymbol)
                        Text(segment.level.dashboardTitle)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(levelTint(segment.level))
                    .padding(.horizontal, 9)
                    .frame(height: 29)
                    .background(
                        levelTint(segment.level).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? LHTheme.accent.opacity(0.09) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(selected ? LHTheme.accent.opacity(0.22) : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        }

        private func levelTint(_ level: ShareLevel) -> Color {
            switch level {
            case .everything: return LHTheme.accent
            case .applicationOnly: return LHTheme.teal
            case .categoryOnly: return LHTheme.success
            case .privateOnly: return LHTheme.privateTint
            }
        }
    }
#endif
