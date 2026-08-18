#if os(macOS)
    import SwiftUI

    struct UsageRulesList: View {
        @ObservedObject var model: DashboardViewModel
        var showsDefaultRule = false

        private var applications: [TrackedUsageItem] {
            model.filteredTrackedUsage.filter { $0.kind == .application }
        }

        private var websites: [TrackedUsageItem] {
            model.filteredTrackedUsage.filter { $0.kind == .website }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                controls
                if model.filteredTrackedUsage.isEmpty {
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
                            subjectSection(title: "Applications", symbol: "square.grid.2x2", items: applications)
                            subjectSection(title: "Websites", symbol: "globe", items: websites)
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
                    TextField("Search apps, websites or categories", text: $model.usageSearch)
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

                Text("\(model.filteredTrackedUsage.count) item\(model.filteredTrackedUsage.count == 1 ? "" : "s")")
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
                            Text("WHEN SHARING")
                                .frame(width: 142, alignment: .trailing)
                        }
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.35)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 40)

                        Divider()

                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            UsageSubjectRow(model: model, item: item)
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

        var body: some View {
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
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .help(identityHelp)
        }

        private var secondaryLabel: String {
            if item.kind == .website {
                let source = item.appName.map { "Seen in \($0)" } ?? "Browser observed"
                return item.identityProofAvailable ? source : "\(source) · older entries share category only"
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
#endif
