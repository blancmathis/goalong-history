#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct MonitoringRulesList: View {
        @ObservedObject var model: DashboardViewModel

        @State private var query = ""
        @State private var filter: MonitoringSubjectFilter = .all

        private var filteredItems: [TrackedUsageItem] {
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return model.snapshot.trackedUsage.filter { item in
                let matchesFilter: Bool
                switch filter {
                case .all:
                    matchesFilter = true
                case .applications:
                    matchesFilter = item.kind == .application
                case .websites:
                    matchesFilter = item.kind == .website
                }
                guard matchesFilter else { return false }
                return normalizedQuery.isEmpty || item.searchableText.contains(normalizedQuery)
            }
        }

        private var applications: [TrackedUsageItem] {
            filteredItems.filter { $0.kind == .application }
        }

        private var websites: [TrackedUsageItem] {
            filteredItems.filter { $0.kind == .website }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                explanationCard
                controls

                if filteredItems.isEmpty {
                    LHCard {
                        EmptyStateView(
                            symbol: "switch.2",
                            title: model.snapshot.trackedUsage.isEmpty ? "No apps or websites yet" : "No matches",
                            message: model.snapshot.trackedUsage.isEmpty
                                ? "Keep Goalong running. Every observed app and website will appear here with its own monitoring control."
                                : "Try another search or filter."
                        )
                        .frame(minHeight: 320)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            subjectSection(
                                title: "Applications",
                                symbol: "square.grid.2x2.fill",
                                items: applications
                            )
                            subjectSection(title: "Websites", symbol: "globe", items: websites)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .onAppear { model.refreshEverything() }
        }

        private var explanationCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LHTheme.teal)
                        .frame(width: 40, height: 40)
                        .background(LHTheme.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose what Goalong monitors")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "Turning monitoring off affects future details only. Existing history is not rewritten, Goalong itself always stays excluded, and sharing rules remain separate."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StatusPill(
                        title: "Stored locally",
                        symbol: "internaldrive.fill",
                        tint: LHTheme.success
                    )
                }
            }
        }

        private var controls: some View {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search an app, website or category", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

                Picker("Type", selection: $filter) {
                    ForEach(MonitoringSubjectFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 310)

                Text("\(filteredItems.count) source\(filteredItems.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 74, alignment: .trailing)
            }
        }

        @ViewBuilder
        private func subjectSection(title: String, symbol: String, items: [TrackedUsageItem]) -> some View {
            if !items.isEmpty {
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Label(title, systemImage: symbol)
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(items.count)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                            Spacer()
                            Text("OBSERVED")
                                .frame(width: 92, alignment: .trailing)
                            Text("MONITOR FUTURE ACTIVITY")
                                .frame(width: 176, alignment: .trailing)
                        }
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.35)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .frame(height: 42)

                        Divider()

                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            monitoringRow(item)
                            if index < items.count - 1 {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }
            }
        }

        private func monitoringRow(_ item: TrackedUsageItem) -> some View {
            let state = monitoringState(for: item)
            return HStack(spacing: 12) {
                if item.kind == .application {
                    AppIconView(bundleIdentifier: item.bundleIdentifier, appName: item.name, size: 34)
                } else {
                    WebsiteIconView(host: item.host ?? item.name, size: 34)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(item.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        StatusPill(
                            title: state.enabled ? "Monitored" : "Excluded",
                            symbol: state.enabled ? "checkmark.circle.fill" : "eye.slash.fill",
                            tint: state.enabled ? LHTheme.success : LHTheme.privateTint
                        )
                        .scaleEffect(0.82, anchor: .leading)
                    }
                    Text(secondaryLabel(for: item))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(DashboardFormatters.duration(seconds: item.foregroundSeconds))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)

                Toggle(
                    "Monitor future activity for \(item.name)",
                    isOn: Binding(
                        get: { monitoringState(for: item).enabled },
                        set: { setMonitoring($0, for: item) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!state.editable)
                .frame(width: 176, alignment: .trailing)
                .help(state.help)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 62)
        }

        private func monitoringState(for item: TrackedUsageItem) -> MonitoringState {
            switch item.kind {
            case .application:
                guard let bundleIdentifier = item.bundleIdentifier, !bundleIdentifier.isEmpty else {
                    return MonitoringState(
                        enabled: true,
                        editable: false,
                        help: "This app has no stable bundle identifier, so Goalong cannot save a persistent app rule."
                    )
                }
                if bundleIdentifier.caseInsensitiveCompare(ProductIdentity.bundleIdentifier) == .orderedSame {
                    return MonitoringState(
                        enabled: false,
                        editable: false,
                        help: "Goalong never records its own window."
                    )
                }
                return MonitoringState(
                    enabled: !model.isApplicationExcludedFromCapture(bundleIdentifier),
                    editable: true,
                    help: "Controls whether future details from this app may be recorded locally."
                )
            case .website:
                guard let host = item.host, !host.isEmpty else {
                    return MonitoringState(
                        enabled: true,
                        editable: false,
                        help: "This website has no stable host, so Goalong cannot save a persistent site rule."
                    )
                }
                return MonitoringState(
                    enabled: !model.isDomainExcludedFromCapture(host),
                    editable: true,
                    help: "Controls whether future details from this website may be recorded locally."
                )
            }
        }

        private func setMonitoring(_ enabled: Bool, for item: TrackedUsageItem) {
            switch item.kind {
            case .application:
                model.setApplicationCaptureEnabled(enabled, bundleIdentifier: item.bundleIdentifier)
            case .website:
                if let host = item.host {
                    model.setDomainCaptureEnabled(enabled, host: host)
                }
            }
        }

        private func secondaryLabel(for item: TrackedUsageItem) -> String {
            if item.kind == .website {
                return [item.host, item.appName].compactMap { $0 }.joined(separator: " · ")
            }
            return item.bundleIdentifier ?? item.category.map { CategoryBadge.prettyCategory($0) } ?? "Application"
        }
    }

    private enum MonitoringSubjectFilter: String, CaseIterable, Identifiable {
        case all
        case applications
        case websites

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .applications: return "Applications"
            case .websites: return "Websites"
            }
        }
    }

    private struct MonitoringState {
        let enabled: Bool
        let editable: Bool
        let help: String
    }
#endif
