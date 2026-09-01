#if os(macOS)
    import SwiftUI

    struct SharePage: View {
        @ObservedObject var model: DashboardViewModel

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    eyebrow: "Selective disclosure",
                    title: "Share a locally signed day",
                    subtitle:
                        "Set one clear rule for each app and website. Goalong verifies its local device signatures and integrity chain before creating the package."
                ) {
                    HStack(spacing: 10) {
                        DateSelectionControl(date: model.selectedDay, onChange: model.selectDay)
                        Button {
                            model.refreshEverything()
                            model.reloadShareSegments()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isRefreshing)
                    }
                }

                disclosureBanner
                ruleSummary

                UsageRulesList(model: model, showsDefaultRule: true)
                    .frame(maxHeight: .infinity)

                exportBar
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
                    Text("Your rules persist for future shares")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "A website rule takes priority over its browser rule. Show name reveals only the website host in new proofs—not the page title or full URL."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StatusPill(title: "Stored on this Mac", symbol: "internaldrive", tint: LHTheme.teal)
            }
            .padding(14)
            .background(LHTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LHTheme.accent.opacity(0.12), lineWidth: 1)
            )
        }

        private var ruleSummary: some View {
            HStack(spacing: 10) {
                summaryItem(
                    title: "Show name",
                    count: count(for: .identity),
                    symbol: "eye",
                    tint: LHTheme.success
                )
                summaryItem(
                    title: "Category only",
                    count: count(for: .categoryOnly),
                    symbol: "tag",
                    tint: LHTheme.accent
                )
                summaryItem(
                    title: "Hidden",
                    count: count(for: .hidden),
                    symbol: "eye.slash",
                    tint: LHTheme.privateTint
                )
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(model.snapshot.sealedMinutes) sealed minute\(model.snapshot.sealedMinutes == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("Rules are evaluated event by event")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }

        private func summaryItem(title: String, count: Int, symbol: String, tint: Color) -> some View {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(tint.opacity(0.08), in: Capsule())
        }

        private var exportBar: some View {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(model.snapshot.sealedMinutes > 0 ? LHTheme.success : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        model.snapshot.sealedMinutes > 0
                            ? "Ready to create a rule-based package"
                            : "No sealed minutes are available for this day"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    Text(
                        "Offline checks include commitments, chains, device identities and P-256 signatures. Receipt IDs remain references; nothing is uploaded by this action."
                    )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.exportSharePackage()
                } label: {
                    Label("Export signed package", systemImage: "square.and.arrow.up")
                        .frame(minWidth: 176)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.snapshot.sealedMinutes == 0 || model.isExportingShare)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }

        private func count(for visibility: SharingVisibility) -> Int {
            model.snapshot.trackedUsage.filter {
                model.sharingVisibility(for: $0.id) == visibility
            }.count
        }
    }
#endif
