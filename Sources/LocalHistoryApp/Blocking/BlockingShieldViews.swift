#if os(macOS)
import SwiftUI

/// Covers a browser window showing a blocked page. It is the block page: struck icon, what is
/// blocked, until when, and the one way out the member chose in advance (a break).
struct BlockedSiteVeil: View {
    let presentation: BlockingVeilPresentation
    /// Fixed for renders; live veils follow the clock.
    var now: Date?
    var onBreak: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 22) {
                BlockingStruckIcon(item: icon, size: 64)
                VStack(spacing: 8) {
                    Text(title).font(LHTheme.pageTitleFont).tracking(LHTheme.pageTitleTracking)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Label(untilLine, systemImage: presentation.lock == .locked ? "lock.fill" : "lock")
                        .font(.system(size: 15, weight: .medium))
                }
                TimelineView(.periodic(from: Date(), by: 15)) { context in
                    BlockingSessionThread(start: presentation.start, end: presentation.end, now: now ?? context.date,
                                          locked: presentation.lock == .locked)
                }
                .frame(width: 320)
                Text(detail).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
                if let minutes = presentation.breakMinutes, presentation.breaksLeft > 0 {
                    VStack(spacing: 6) {
                        Button(action: onBreak) { Label("Pause de \(minutes) min", systemImage: "cup.and.saucer") }
                            .accessibilityIdentifier("blocking-veil-break")
                        Text(presentation.breaksLeft == 1 ? "Dernière pause du jour" : "\(presentation.breaksLeft) pauses restantes aujourd’hui")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText)
                    }
                }
            }
            .padding(32)
            Spacer(minLength: 24)
            HStack(spacing: 8) {
                GoalongMark().stroke(LHTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 14)
                Text("Goalong · Blocage").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.tertiaryText)
            }
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LHTheme.pageBackground)
        .foregroundStyle(LHTheme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blocking-site-veil")
    }

    private var icon: BlockingItem {
        switch presentation.reason {
        case .site(let host), .quotaUsed(let host, _): return .site(host)
        case .privateWindow: return .symbol("eyeglasses")
        case .unsupportedBrowser(let name): return .app(BlockAppRule(bundleIdentifier: "", name: name))
        }
    }

    private var title: String {
        switch presentation.reason {
        case .site(let host), .quotaUsed(let host, _): return host
        case .privateWindow: return "Navigation privée"
        case .unsupportedBrowser(let name): return "\(name) n’est pas pris en charge"
        }
    }

    private var untilLine: String {
        "\(presentation.lock == .locked ? "Verrouillé" : "Bloqué") jusqu’à \(BlockingFormat.time(presentation.end))"
    }

    private var detail: String {
        switch presentation.reason {
        case .site: return "Liste « \(presentation.listName) »."
        case .quotaUsed(_, let minutes): return "Vos \(BlockingFormat.duration(minutes: minutes)) du jour sont passées. Liste « \(presentation.listName) »."
        case .privateWindow: return "Pendant un blocage de sites, les fenêtres privées sont couvertes : Goalong ne lit jamais leur adresse."
        case .unsupportedBrowser: return "Goalong ne lit pas l’adresse dans ce navigateur. Pendant un blocage de sites, il reste couvert. Safari, Chrome, Edge, Brave et Arc sont pris en charge."
        }
    }
}

/// Shown for a few seconds when a blocked app was opened and closed again.
struct BlockedAppNotice: View {
    let app: BlockAppRule
    let end: Date
    let lock: BlockLock
    var listName: String

    var body: some View {
        HStack(spacing: 14) {
            BlockingStruckIcon(item: .app(app), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(app.name) est bloqué").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("Jusqu’à \(BlockingFormat.time(end)) · \(listName)").font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            if lock == .locked {
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                    .accessibilityLabel("Verrouillé")
            }
        }
        .padding(.horizontal, 16).frame(width: 380, height: 68)
        .background(GoalongSurface(corner: 14, fill: LHTheme.elevatedBackground, highlighted: true))
        .foregroundStyle(LHTheme.text)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("blocking-app-notice")
    }
}

/// The frozen Mac: the time left, the thread of the freeze, and the apps the member kept.
struct FrozenMacShield: View {
    let freeze: BlockFreeze
    var now: Date?
    var onOpen: (BlockAppRule) -> Void = { _ in }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let now = self.now ?? context.date
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 28) {
                    GoalongMark().stroke(LHTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 52, height: 36)
                    VStack(spacing: 10) {
                        Text(clock(freeze.end.timeIntervalSince(now)))
                            .font(.system(size: 96, weight: .bold).monospacedDigit()).tracking(-3)
                        Label("Mac gelé jusqu’à \(BlockingFormat.time(freeze.end))", systemImage: "snowflake")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    BlockingSessionThread(start: freeze.start, end: freeze.end, now: now, locked: true).frame(width: 440)
                    if !freeze.allowedApps.isEmpty {
                        HStack(spacing: 18) {
                            ForEach(freeze.allowedApps) { app in
                                Button { onOpen(app) } label: {
                                    VStack(spacing: 6) {
                                        AppIconView(bundleIdentifier: app.bundleIdentifier, appName: app.name, size: 48)
                                        Text(app.name).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                                    }
                                    .frame(width: 84).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Ouvrir \(app.name)")
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                Spacer()
                Text("Éteindre le Mac reste possible. Au redémarrage, le gel reprend.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText).padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LHTheme.pageBackground)
        .foregroundStyle(LHTheme.text)
        .accessibilityIdentifier("blocking-freeze-shield")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
    }
}

/// An app or site icon crossed out by one stroke of ink, ringed by the page so it reads on the icon.
struct BlockingStruckIcon: View {
    let item: BlockingItem
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            BlockingIconStack(items: [item], size: size)
            Path { path in
                path.move(to: CGPoint(x: size * 0.08, y: size * 0.92))
                path.addLine(to: CGPoint(x: size * 0.92, y: size * 0.08))
            }
            .stroke(LHTheme.pageBackground, style: StrokeStyle(lineWidth: max(4, size * 0.13), lineCap: .round))
            Path { path in
                path.move(to: CGPoint(x: size * 0.08, y: size * 0.92))
                path.addLine(to: CGPoint(x: size * 0.92, y: size * 0.08))
            }
            .stroke(LHTheme.text, style: StrokeStyle(lineWidth: max(2, size * 0.06), lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
