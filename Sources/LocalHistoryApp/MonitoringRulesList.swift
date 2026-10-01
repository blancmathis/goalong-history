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
                            title: model.snapshot.trackedUsage.isEmpty ? "Aucune app ni aucun site pour l’instant" : "Aucun résultat",
                            message: model.snapshot.trackedUsage.isEmpty
                                ? "Laissez Goalong actif : chaque app et site observé apparaîtra ici avec son propre réglage."
                                : "Essayez une autre recherche ou un autre filtre."
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
                            subjectSection(title: "Sites web", symbol: "globe", items: websites)
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
                        Text("Choisir ce que Goalong suit")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "Désactiver le suivi ne concerne que les détails futurs. L’historique existant n’est pas modifié, Goalong reste toujours exclu et les règles de partage sont distinctes."
                        )
                        .font(.system(size: 11))
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
                GoalongSearchField("Rechercher une app, un site ou une catégorie", text: $query)

                GoalongSegmentedControl("Type", selection: $filter,
                                        options: MonitoringSubjectFilter.allCases) { $0.title }

                Text("\(filteredItems.count) source\(filteredItems.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
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
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                            Spacer()
                            Text("Observé")
                                .frame(width: 92, alignment: .trailing)
                            Text("Surveiller l’activité future")
                                .frame(width: 176, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold))
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
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(DashboardFormatters.duration(seconds: item.foregroundSeconds))
                    .font(.system(size: 11, weight: .semibold))
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
                .toggleStyle(.goalongSwitchOnly)
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
                        help: "Goalong n’enregistre jamais sa propre fenêtre."
                    )
                }
                return MonitoringState(
                    enabled: !model.isApplicationExcludedFromCapture(bundleIdentifier),
                    editable: true,
                    help: "Détermine si les détails futurs de cette app peuvent être enregistrés."
                )
            case .website:
                guard let host = item.host, !host.isEmpty else {
                    return MonitoringState(
                        enabled: true,
                        editable: false,
                        help: "Ce site n’a pas d’adresse stable : Goalong ne peut pas lui associer une règle permanente."
                    )
                }
                return MonitoringState(
                    enabled: !model.isDomainExcludedFromCapture(host),
                    editable: true,
                    help: "Détermine si les détails futurs de ce site peuvent être enregistrés."
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
            case .websites: return "Sites web"
            }
        }
    }

    private struct MonitoringState {
        let enabled: Bool
        let editable: Bool
        let help: String
    }
#endif
