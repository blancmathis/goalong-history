#if os(macOS)
import AppKit
import SwiftUI
import LocalHistoryCore

/// Puts « Ralentir » on screen: a veil over the browser window for a site, a small panel centred
/// on the screen for an app. Non-activating, so the member's app keeps the keyboard.
@MainActor final class SlowDownPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: Panel?
    private var key: String?

    func show(_ target: BlockingObservation, presentation: BlockingFrictionPresentation,
              onRenounce: @escaping () -> Void, onContinue: @escaping () -> Void) {
        let screen = target.windowFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(StandardBlockingBackend.appKitFrame(frame)) }
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let frame = target.isBrowser
            ? target.windowFrame.map(StandardBlockingBackend.appKitFrame) ?? visible
            : CGRect(x: visible.midX - 210, y: visible.midY - 84, width: 420, height: 168)
        let value = panel ?? {
            let made = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            made.isReleasedWhenClosed = false; made.hidesOnDeactivate = false; made.isFloatingPanel = true
            made.level = .floating; made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            made.isOpaque = false; made.backgroundColor = .clear
            return made
        }()
        value.hasShadow = !target.isBrowser
        if key != presentation.key {
            let item: BlockingItem = target.isBrowser ? .site(presentation.name)
                : .app(BlockAppRule(bundleIdentifier: target.bundleIdentifier, name: presentation.name))
            let root: AnyView = target.isBrowser
                ? AnyView(SlowDownVeil(presentation: presentation, item: item, onRenounce: onRenounce, onContinue: onContinue))
                : AnyView(SlowDownAppCard(presentation: presentation, item: item, onRenounce: onRenounce, onContinue: onContinue))
            let host = NSHostingView(rootView: root.goalongControls())
            host.sizingOptions = []
            value.contentView = host
            key = presentation.key
        }
        value.setFrame(frame, display: true)
        value.orderFrontRegardless()
        panel = value
    }

    func close() { panel?.orderOut(nil); panel?.close(); panel = nil; key = nil }
}

/// The wait drawn as a bar: it fills in ink from left to right, without a handle (it is not a slider),
/// with the seconds left written under it, and is full when « Continuer » becomes possible.
struct SlowDownCountdown: View {
    let presentation: BlockingFrictionPresentation
    /// Fixed for renders; live views follow the clock.
    var now: Date?
    @Binding var ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let now {
            labelled(at: now)
        } else {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 20, paused: ready)) { context in
                labelled(at: GoalongToday.timeline(context.date))
            }
            .task {
                let wait = presentation.readyAt.timeIntervalSinceNow // wall: display wait; the controller sends readyAt in the wall frame and decides with its own clock
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                ready = true
            }
        }
    }

    /// The bar and its legend: the wait in seconds, readable (the disabled « Continuer » is not).
    private func labelled(at date: Date) -> some View {
        let left = seconds(at: date)
        return VStack(alignment: .leading, spacing: 6) {
            thread(at: date)
            Text(left == 0 ? "Vous pouvez continuer." : "Attente : encore \(FrenchCount.count(left, "seconde", "secondes")).")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
        }
    }

    private func thread(at date: Date) -> some View {
        let total = presentation.readyAt.timeIntervalSince(presentation.shownAt)
        let progress = total > 0 ? min(1, max(0, date.timeIntervalSince(presentation.shownAt) / total)) : 1
        return GeometryReader { proxy in
            let width = proxy.size.width, x = width * progress
            ZStack(alignment: .leading) {
                Capsule().fill(LHTheme.text.opacity(0.16)).frame(height: 8)
                Capsule().fill(LHTheme.text).frame(width: max(8, x), height: 8)
            }
            .frame(height: 8)
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress >= 1 ? "Attente terminée" : "Attente : encore \(FrenchCount.count(seconds(at: date), "seconde", "secondes"))")
    }

    func seconds(at date: Date) -> Int { max(0, Int(ceil(presentation.readyAt.timeIntervalSince(date)))) }
}

/// The two ways out. Giving up is the main action; continuing waits for the end of the delay.
private struct SlowDownActions: View {
    let presentation: BlockingFrictionPresentation
    var now: Date?
    let ready: Bool
    var onRenounce: () -> Void
    var onContinue: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Renoncer", action: onRenounce)
                .buttonStyle(LHPrimaryButtonStyle())
                .accessibilityIdentifier("slowdown-renounce")
            Group {
                if let now {
                    continueButton(at: now)
                } else {
                    TimelineView(.periodic(from: presentation.shownAt, by: 1)) { context in continueButton(at: GoalongToday.timeline(context.date)) }
                }
            }
        }
    }

    private func continueButton(at date: Date) -> some View {
        let left = max(0, Int(ceil(presentation.readyAt.timeIntervalSince(date))))
        let open = ready || left == 0
        return Button("Continuer", action: onContinue)
            .disabled(!open)
            .accessibilityIdentifier("slowdown-continue")
    }
}

/// Covers the browser window showing a slowed site: the site, the wait, the two ways out, and how
/// many times today. No advice.
struct SlowDownVeil: View {
    let presentation: BlockingFrictionPresentation
    let item: BlockingItem
    var now: Date?
    var onRenounce: () -> Void = {}
    var onContinue: () -> Void = {}
    @State private var ready = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 22) {
                BlockingIconStack(items: [item], size: 64)
                VStack(spacing: 8) {
                    Text(presentation.name).font(LHTheme.pageTitleFont).tracking(LHTheme.pageTitleTracking)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Label("Ralenti", systemImage: "hourglass").font(.system(size: 15, weight: .medium))
                }
                SlowDownCountdown(presentation: presentation, now: now, ready: $ready).frame(width: 320)
                SlowDownActions(presentation: presentation, now: now, ready: ready, onRenounce: onRenounce, onContinue: onContinue)
                Text("Ce site est ralenti : attendez la fin de la barre, ou renoncez. \(FocusUIFormat.ordinal(presentation.occurrence)) fois aujourd’hui.")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            }
            .padding(32)
            Spacer(minLength: 24)
            HStack(spacing: 8) {
                GoalongMark().stroke(LHTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 14)
                Text("Ralentir avec Goalong").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
            }
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LHTheme.pageBackground)
        .foregroundStyle(LHTheme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slowdown-site-veil")
    }
}

/// The same moment for an app, which Goalong hides instead of closing: the member may have work in it.
struct SlowDownAppCard: View {
    let presentation: BlockingFrictionPresentation
    let item: BlockingItem
    var now: Date?
    var onRenounce: () -> Void = {}
    var onContinue: () -> Void = {}
    @State private var ready = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BlockingIconStack(items: [item], size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("Ralenti pour la \(FocusUIFormat.ordinal(presentation.occurrence)) fois aujourd’hui")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            SlowDownCountdown(presentation: presentation, now: now, ready: $ready)
            HStack {
                Spacer()
                SlowDownActions(presentation: presentation, now: now, ready: ready, onRenounce: onRenounce, onContinue: onContinue)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GoalongSurface(corner: 16, fill: LHTheme.elevatedBackground, highlighted: true))
        .foregroundStyle(LHTheme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slowdown-app-card")
    }
}
#endif
