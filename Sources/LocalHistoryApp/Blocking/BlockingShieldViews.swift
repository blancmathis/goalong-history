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
                    Label(Self.stateLine(presentation), systemImage: presentation.lock == .locked ? "lock.fill" : "lock")
                        .font(.system(size: 15, weight: .medium))
                }
                if !BlockingFormat.isOpenEnded(presentation.end) {
                    TimelineView(.periodic(from: Date(), by: 15)) { context in // wall: display tick
                        BlockingSessionThread(start: presentation.start, end: presentation.end, now: now ?? GoalongToday.timeline(context.date),
                                              locked: presentation.lock == .locked)
                    }
                    .frame(width: 320)
                }
                if let reason = presentation.feedback?.reasonLine {
                    Text(reason).font(.system(size: 17, weight: .medium)).multilineTextAlignment(.center)
                        .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("blocking-veil-reason")
                }
                Text(detail).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
                if let counts = Self.countsLine(presentation.feedback) {
                    Text(counts).font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("blocking-veil-attempts")
                }
                if let minutes = presentation.breakMinutes, presentation.breaksLeft > 0 {
                    VStack(spacing: 6) {
                        Button(action: onBreak) { Label("Pause de \(minutes) min", systemImage: "cup.and.saucer") }
                            .accessibilityIdentifier("blocking-veil-break")
                        Text(presentation.breaksLeft == 1 ? "Dernière pause du jour" : "\(presentation.breaksLeft) pauses restantes aujourd’hui")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                } else if presentation.breakMinutes != nil, presentation.extraBreak {
                    VStack(spacing: 6) {
                        Button(action: onBreak) { Label("Pause supplémentaire…", systemImage: "key") }
                            .accessibilityIdentifier("blocking-veil-extra-break")
                        Text("Pauses du jour prises. Le mot de passe en accorde une de plus.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                } else if presentation.breakMinutes != nil {
                    // No break left and no extra one: say it. The end time is already on the state line (R-85).
                    Text("Pauses du jour prises.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .accessibilityIdentifier("blocking-veil-no-break")
                }
            }
            .padding(32)
            Spacer(minLength: 24)
            HStack(spacing: 8) {
                // A signature, not an action: lime stays for the one thing to do (DESIGN §3.2).
                GoalongMark().stroke(LHTheme.secondaryText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 14)
                Text("Blocage Goalong").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
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
        case .unsupportedBrowser: return .symbol("globe")
        }
    }

    private var title: String {
        switch presentation.reason {
        case .site(let host), .quotaUsed(let host, _): return host
        case .unsupportedBrowser(let name): return name
        }
    }

    /// The line under the title says the state. A used quota is a state of its own, not a lock (R-85);
    /// the end time is said here once.
    static func stateLine(_ presentation: BlockingVeilPresentation) -> String {
        // A used quota is the state; its end shows on the thread under it.
        if case .quotaUsed = presentation.reason { return "Quota du jour atteint" }
        // A timed block shows its end on the thread under the line, never twice (R-85).
        if BlockingFormat.isOpenEnded(presentation.end) { return "Bloqué pendant que vous travaillez" }
        return presentation.lock == .locked ? "Verrouillé" : "Bloqué"
    }

    /// The attempt count and the earned break, on one line (R-98).
    static func countsLine(_ feedback: BlockingListFeedback?) -> String? {
        let parts = [feedback?.attemptLine, feedback?.earnedLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ") + "."
    }

    var detail: String {
        switch presentation.reason {
        case .site: return "Bloqué par la liste « \(presentation.listName) »."
        case .quotaUsed(_, let minutes): return "Vous avez utilisé votre temps du jour : \(BlockingFormat.duration(minutes: minutes)) (liste « \(presentation.listName) »)."
        case .unsupportedBrowser(let name): return "\(name) n’est pas pris en charge : Goalong ne lit pas l’adresse dans ce navigateur. Pendant un blocage de sites, ses fenêtres restent masquées. Safari, Chrome, Edge, Brave, Arc et Aside sont pris en charge."
        }
    }
}

/// Shown for a few seconds when a blocked app was opened and closed again.
struct BlockedAppNotice: View {
    let app: BlockAppRule
    let end: Date
    let lock: BlockLock
    var listName: String
    var feedback: BlockingListFeedback? = nil
    /// The app did not quit (it may ask to save): it is hidden, never force-quit.
    var held = false

    static let heldLine = "Masquée, pas fermée : votre travail non enregistré est gardé."
    static func height(_ feedback: BlockingListFeedback?, held: Bool = false) -> CGFloat {
        68 + (feedback?.reasonLine == nil ? 0 : 18) + (held ? 18 : 0)
    }

    private var untilText: String {
        BlockingFormat.isOpenEnded(end) ? "Pendant votre travail" : "Jusqu’à \(BlockingFormat.endTime(end))"
    }

    private func detail(_ parts: [String?]) -> some View {
        Text(parts.compactMap { $0 }.joined(separator: ". ") + ".")
            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
    }

    var body: some View {
        HStack(spacing: 14) {
            BlockingStruckIcon(item: .app(app), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accès bloqué à \(app.name)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let reason = feedback?.reasonLine {
                    Text(reason).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                if held {
                    Text(Self.heldLine).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                // The attempt count matters more than the list name when both do not fit.
                ViewThatFits(in: .horizontal) {
                    detail([untilText, listName, feedback?.attemptLine])
                    detail([untilText, feedback?.attemptLine])
                }
            }
            Spacer(minLength: 8)
            if lock == .locked {
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                    .accessibilityLabel("Verrouillé")
            }
        }
        .padding(.horizontal, 16).frame(width: 380, height: Self.height(feedback, held: held))
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

    /// The end time shows once, on the thread under it (R-85).
    static let stateLine = "Mac gelé"

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in // wall: display tick
            let now = self.now ?? GoalongToday.timeline(context.date)
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 28) {
                    // The mark signs the shield; lime stays for actions and data (DESIGN §3.2).
                    GoalongMark().stroke(LHTheme.secondaryText, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 52, height: 36)
                    VStack(spacing: 10) {
                        VStack(spacing: 0) {
                            Text(clock(freeze.end.timeIntervalSince(now)))
                                .font(.system(size: 96, weight: .bold).monospacedDigit()).tracking(-3)
                            // The timer says its direction (déc. 15).
                            Text("restant").font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Temps restant : \(BlockingFormat.remaining(freeze.end.timeIntervalSince(now)))")
                        // The figure is the time left (said to VoiceOver); the line under it says when it ends (UI-16C, 47).
                        Label(Self.stateLine, systemImage: "snowflake")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    BlockingSessionThread(start: freeze.start, end: freeze.end, now: now, locked: true).frame(width: 440)
                    if !freeze.allowedApps.isEmpty {
                      VStack(spacing: 10) {
                        Text("Apps autorisées").font(.system(size: 12, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
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
                      }
                      .padding(.top, 8)
                    }
                }
                Spacer()
                Text("Éteindre le Mac reste possible. Au redémarrage, le gel reprend.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).padding(.bottom, 32)
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

/// An app or site icon with a "forbidden" mark in its corner, ringed by the page so it reads on the icon.
struct BlockingStruckIcon: View {
    let item: BlockingItem
    var size: CGFloat = 48

    /// The initial shown for an item without an icon of its own (an app Goalong cannot read the icon of).
    static func fallbackInitial(for item: BlockingItem) -> String? {
        switch item {
        case .app(let app): return AppIconView.icon(bundleIdentifier: app.bundleIdentifier) == nil ? AppIconView.initial(for: app.name) : nil
        // A site shows its monogram tile (BlockingSiteTile → WebsiteIconView), never a letter here.
        case .site, .symbol: return nil
        }
    }

    var body: some View {
        ZStack {
            if let initial = Self.fallbackInitial(for: item) {
                // The initial sits in the top corner, away from the badge, so both stay whole.
                let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                ZStack {
                    shape.fill(LHTheme.insetBackground)
                    shape.strokeBorder(LHTheme.separator)
                    Text(initial)
                        .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(LHTheme.secondaryText)
                        .offset(x: -size * 0.19, y: -size * 0.19)
                }
                .frame(width: size, height: size)
            } else {
                BlockingIconStack(items: [item], size: size)
            }
            // The "forbidden" mark sits in a corner, so the icon itself stays readable (R-84).
            let badge = max(14, size * 0.42)
            Image(systemName: "nosign")
                .font(.system(size: badge * 0.72, weight: .bold))
                .foregroundStyle(LHTheme.text)
                .frame(width: badge, height: badge)
                .background(Circle().fill(LHTheme.pageBackground))
                .offset(x: size / 2 - badge * 0.35, y: size / 2 - badge * 0.35)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
